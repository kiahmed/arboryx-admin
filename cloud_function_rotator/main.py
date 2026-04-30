"""arboryx-key-rotator — scheduled rotator for the admin API key.

Triggered quarterly by Cloud Scheduler (HTTP POST). Each invocation:
  1. Generates a fresh token (43 chars, base64-url; secrets.token_urlsafe(32)).
  2. Adds it as a NEW ENABLED version of arboryx-admin-key.
  3. Disables any ENABLED version older than DISABLE_OLDER_THAN_DAYS (default 30).
     The old versions stay in version history and can be re-enabled if needed.

Why ONLY the admin key (not the public key)?
  The public key lives baked into frontend/scripts/config.js, which is
  generated at deploy time. Rotating it requires re-running frontend
  deploy.sh — that's a CI/CD pipeline (Phase 4) deferred. Until then,
  use dev-utils/rotate_key.sh public for manual public-key rotation.

Environment:
  PROJECT_ID                  required
  ADMIN_SECRET_NAME           default: arboryx-admin-key
  DISABLE_OLDER_THAN_DAYS     default: 30   (soak window before old gets disabled)

Auth model:
  Function deploys with the dedicated arboryx-rotator-sa service account,
  which has roles/secretmanager.admin scoped to the project. The function
  itself does NOT accept HTTP traffic from the internet — Cloud Scheduler
  invokes it via OIDC token, and IAM (run.invoker) gates that path.
"""

import os
import json
import logging
import secrets as _secrets
from datetime import datetime, timezone, timedelta

from google.cloud import secretmanager

PROJECT_ID = os.environ["PROJECT_ID"]
ADMIN_SECRET_NAME = os.environ.get("ADMIN_SECRET_NAME", "arboryx-admin-key")
DISABLE_OLDER_THAN_DAYS = int(os.environ.get("DISABLE_OLDER_THAN_DAYS", "30"))

_client = secretmanager.SecretManagerServiceClient()


def _add_new_version(secret_id: str) -> tuple[str, str]:
    """Generate a fresh key and add as a new ENABLED version. Returns (version_name, new_key_preview)."""
    new_key = _secrets.token_urlsafe(32)
    parent = f"projects/{PROJECT_ID}/secrets/{secret_id}"
    payload = {"data": new_key.encode("utf-8")}
    resp = _client.add_secret_version(request={"parent": parent, "payload": payload})
    preview = f"{new_key[:6]}…{new_key[-4:]}"
    logging.info("Added %s (preview=%s)", resp.name, preview)
    return resp.name, preview


def _disable_old_versions(secret_id: str, older_than_days: int) -> list[str]:
    """Disable every ENABLED version of `secret_id` older than the cutoff.
    Returns the list of disabled version resource names.
    """
    parent = f"projects/{PROJECT_ID}/secrets/{secret_id}"
    cutoff = datetime.now(timezone.utc) - timedelta(days=older_than_days)
    disabled: list[str] = []
    for ver in _client.list_secret_versions(request={"parent": parent, "filter": "state:ENABLED"}):
        # ver.create_time is a tz-aware DatetimeWithNanoseconds (datetime subclass) — use directly.
        created = ver.create_time
        if created.tzinfo is None:
            created = created.replace(tzinfo=timezone.utc)
        if created < cutoff:
            _client.disable_secret_version(request={"name": ver.name})
            disabled.append(ver.name)
            logging.info("Disabled %s (created=%s, age=%s)", ver.name, created.isoformat(), datetime.now(timezone.utc) - created)
    return disabled


def rotator_handler(request):
    """HTTP entry point. Cloud Scheduler invokes via POST."""
    started = datetime.now(timezone.utc)
    try:
        version_name, preview = _add_new_version(ADMIN_SECRET_NAME)
        disabled = _disable_old_versions(ADMIN_SECRET_NAME, DISABLE_OLDER_THAN_DAYS)
        result = {
            "status": "ok",
            "secret": ADMIN_SECRET_NAME,
            "new_version": version_name,
            "new_key_preview": preview,
            "disabled_old_versions": disabled,
            "disable_older_than_days": DISABLE_OLDER_THAN_DAYS,
            "elapsed_ms": int((datetime.now(timezone.utc) - started).total_seconds() * 1000),
            "started_at": started.isoformat(),
        }
        logging.info("rotator_complete %s", json.dumps(result))
        return (json.dumps(result), 200, {"Content-Type": "application/json"})
    except Exception as exc:
        logging.exception("rotator_failed")
        body = {"status": "error", "error": str(exc), "secret": ADMIN_SECRET_NAME}
        return (json.dumps(body), 500, {"Content-Type": "application/json"})
