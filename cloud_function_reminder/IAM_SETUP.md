# Reminder IAM Setup

One-time setup before deploying the quarterly rotation-reminder Cloud
Function (`bash cloud_function_reminder/deploy.sh`). Creates a dedicated
service account with the minimum perms needed: read SMTP password from
Secret Manager, nothing else.

## TL;DR — automated path

```bash
bash cloud_function_reminder/make_reminder_pipeline_ready.sh
```

That script is idempotent and does everything below for you. The rest of
this doc is the manual / longer-form version, kept around so you can see
what the automation does.

## Why a separate SA?

The reminder function only needs to:
- Read one specific Secret Manager secret (`arboryx-smtp-pass`)
- Be invoked by Cloud Scheduler

Granting the rotator SA (which has `secretmanager.admin`) the additional
power to send email is unnecessary blast-radius. The reminder SA gets
`secretmanager.secretAccessor` and that's it — it cannot mutate any
secret, deploy code, or call any other API.

## Manual commands (what the make_* script automates)

```bash
source arboryx_admin_backend.config

# 1) Create the reminder service account
gcloud iam service-accounts create arboryx-reminder-sa \
  --display-name="Arboryx rotation-reminder notifier" \
  --description="Sends quarterly rotation-reminder emails via Gmail SMTP. Reads only arboryx-smtp-pass from Secret Manager." \
  --project="$PROJECT_ID"

REMINDER_SA="arboryx-reminder-sa@${PROJECT_ID}.iam.gserviceaccount.com"

# 2) Grant Secret Manager READ access (project-scoped — narrowest broad role)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$REMINDER_SA" \
  --role="roles/secretmanager.secretAccessor" \
  --condition=None

# 3) Allow this SA to ACT AS itself when minting OIDC tokens
#    (Cloud Scheduler invokes the reminder via OIDC = $REMINDER_SA)
gcloud iam service-accounts add-iam-policy-binding "$REMINDER_SA" \
  --member="serviceAccount:$REMINDER_SA" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project="$PROJECT_ID"
```

**Note:** `roles/run.invoker` on the deployed reminder function is granted
automatically by `cloud_function_reminder/deploy.sh` after the function is
deployed (so it can target the actual resource).

## Optional: tighter Secret Manager scope

The grant above is project-wide `secretmanager.secretAccessor`. If you
want to restrict the reminder SA to just the SMTP secret (cannot read
admin/public API keys), replace step 2 with a per-secret binding:

```bash
gcloud secrets add-iam-policy-binding arboryx-smtp-pass \
  --member="serviceAccount:$REMINDER_SA" \
  --role="roles/secretmanager.secretAccessor" \
  --project="$PROJECT_ID"
```

…and remove the project-wide grant. Tighter blast radius, slightly more
gcloud incantation. Pick this if you're being thorough.

## Verify

```bash
gcloud iam service-accounts describe "$REMINDER_SA" --project="$PROJECT_ID"

gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --format='table(bindings.role,bindings.members)' \
  --filter="bindings.members:$REMINDER_SA"
```

## After this is done

```bash
bash cloud_function_reminder/deploy.sh
```

Will deploy the reminder function (`arboryx-rotation-reminder`), grant
`roles/run.invoker` on it to the reminder SA, and create the Cloud
Scheduler job (`arboryx-rotation-reminder-quarterly`).

## Send a test email immediately (optional, post-deploy)

```bash
gcloud scheduler jobs run arboryx-rotation-reminder-quarterly \
  --location="$LOCATION" --project="$PROJECT_ID"
```

The recipient (`REMINDER_RECIPIENT` in `arboryx_admin_backend.config`)
should receive an email within ~30 seconds with the rotation reminder.
