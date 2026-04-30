"""arboryx-rotation-reminder — quarterly nudge to rotate the public API key.

Triggered by Cloud Scheduler. Sends a short email to REMINDER_RECIPIENT
with a templated rotation reminder. The agent / human reading the email
runs `bash dev-utils/rotate_key.sh public` from the arboryx-admin repo.

Why static text and not "live" Secret Manager status?
  Reading + summarizing live secret state would either need this function
  to have secretmanager.viewer (broader perms) or have us run two extra
  API calls per invocation. The reminder is the same text either way; we
  optimise for least-privilege + smallest blast radius.

Environment:
  PROJECT_ID                  required
  SMTP_HOST                   default: smtp.gmail.com
  SMTP_PORT                   default: 587
  SMTP_USER                   required (also used as From: by default)
  SMTP_FROM                   default: SMTP_USER
  REMINDER_RECIPIENT          required (To: address)
  SMTP_PASSWORD_SECRET        default: arboryx-smtp-pass

Auth model:
  Function deploys with arboryx-reminder-sa, which has only
  roles/secretmanager.secretAccessor (read SMTP password). It cannot
  list, modify, or destroy any secret. Cannot fetch other secrets without
  an explicit name. Cannot read GCS, deploy code, or invoke other
  functions. Smallest blast radius for what is essentially a notifier.
"""

import os
import json
import logging
import smtplib
from datetime import datetime, timezone
from email.message import EmailMessage

from google.cloud import secretmanager

PROJECT_ID = os.environ["PROJECT_ID"]
SMTP_HOST = os.environ.get("SMTP_HOST", "smtp.gmail.com")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER = os.environ["SMTP_USER"]
SMTP_FROM = os.environ.get("SMTP_FROM", SMTP_USER)
RECIPIENT = os.environ["REMINDER_RECIPIENT"]
SMTP_PASSWORD_SECRET = os.environ.get("SMTP_PASSWORD_SECRET", "arboryx-smtp-pass")

_secret_client = secretmanager.SecretManagerServiceClient()


def _smtp_password() -> str:
    """Fetch the latest version of the SMTP password from Secret Manager."""
    name = f"projects/{PROJECT_ID}/secrets/{SMTP_PASSWORD_SECRET}/versions/latest"
    resp = _secret_client.access_secret_version(request={"name": name})
    return resp.payload.data.decode("utf-8")


_BODY_TEMPLATE = """Quarterly key-rotation reminder for Arboryx.

It's been ~90 days. Recommended actions:

1. PUBLIC API KEY (manual rotation — auto rotator does NOT touch this)
   The key embedded in frontend/scripts/config.js is due for rotation.
   From the arboryx-admin repo:

       bash dev-utils/rotate_key.sh public

   This generates a new key, adds it as a new ENABLED version of
   the 'arboryx-public-key' secret, updates frontend/arboryx_frontend.config,
   and prompts to re-deploy the frontend so config.js carries the new key.

   After 7-day soak window, finalize:
       bash dev-utils/rotate_key.sh public --finalize <OLD_VER>

2. ADMIN API KEY (auto-rotated this quarter — verify it ran)
   Cloud Scheduler 'arboryx-key-rotator-quarterly' should have just
   rotated the admin key. Verify:

       gcloud secrets versions list arboryx-admin-key --project=marketresearch-agents

   You should see a fresh ENABLED version dated today. If not, run the
   rotator manually:

       gcloud scheduler jobs run arboryx-key-rotator-quarterly \\
         --location=us-central1 --project=marketresearch-agents

3. SMTP PASSWORD (optional, lower urgency)
   The Gmail app password used to send THIS email is also rotatable.
   If you generate a fresh app password in Google Account settings:

       # Update arboryx_admin_backend.config: SMTP_PASSWORD="<new>"
       bash dev-utils/rotate_key.sh smtp

Sent: {sent_at}
Source: cloud_function_reminder (project={project})
"""


def reminder_handler(request):
    """HTTP entry point. Cloud Scheduler invokes via POST."""
    started = datetime.now(timezone.utc)
    try:
        body_text = _BODY_TEMPLATE.format(
            sent_at=started.isoformat(),
            project=PROJECT_ID,
        )

        msg = EmailMessage()
        msg["Subject"] = "Arboryx — Key rotation reminder (quarterly)"
        msg["From"] = SMTP_FROM
        msg["To"] = RECIPIENT
        msg.set_content(body_text)

        password = _smtp_password()

        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=20) as smtp:
            smtp.ehlo()
            smtp.starttls()
            smtp.ehlo()
            smtp.login(SMTP_USER, password)
            smtp.send_message(msg)

        result = {
            "status": "ok",
            "to": RECIPIENT,
            "from": SMTP_FROM,
            "host": SMTP_HOST,
            "elapsed_ms": int((datetime.now(timezone.utc) - started).total_seconds() * 1000),
            "started_at": started.isoformat(),
        }
        logging.info("reminder_sent %s", json.dumps(result))
        return (json.dumps(result), 200, {"Content-Type": "application/json"})
    except Exception as exc:
        logging.exception("reminder_failed")
        body = {"status": "error", "error": str(exc), "to": RECIPIENT}
        return (json.dumps(body), 500, {"Content-Type": "application/json"})
