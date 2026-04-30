# Rotator IAM Setup

One-time setup before deploying the scheduled admin-key rotator
(`bash cloud_function_rotator/deploy.sh`). Creates a dedicated service
account with the narrowest possible perms.

## TL;DR — automated path

```bash
bash cloud_function_rotator/make_rotator_pipeline_ready.sh
```

That script is idempotent and does everything below for you. The rest of
this doc is the manual / longer-form version, kept around so you can see
what the automation does (and fall back to it if anything goes wrong).

## Why a separate SA?

The main API function (`arboryx-admin-api`) runs as `market-agent-sa@…`
and only has `secretmanager.secretAccessor` (READ). Granting it `admin`
would mean: if the public-facing API is ever exploited (RCE, etc.),
the attacker also gets full Secret Manager mutation. Keeping the rotator
on its own SA isolates that blast radius.

## Manual commands (what the make_* script automates)

```bash
source arboryx_admin_backend.config

# 1) Create the rotator service account
gcloud iam service-accounts create arboryx-rotator-sa \
  --display-name="Arboryx scheduled key rotator" \
  --description="Rotates arboryx-admin-key on a quarterly schedule. Used by Cloud Scheduler + the rotator Cloud Function. NOT used by the public API." \
  --project="$PROJECT_ID"

ROTATOR_SA="arboryx-rotator-sa@${PROJECT_ID}.iam.gserviceaccount.com"

# 2) Grant Secret Manager admin (project-scoped)
#    Allows: list/get/add/disable/destroy secret versions.
#    Does NOT allow: GCS reads, function deploys, IAM changes.
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$ROTATOR_SA" \
  --role="roles/secretmanager.admin" \
  --condition=None

# 3) Allow this SA to ACT AS itself when minting OIDC tokens.
#    Required for Cloud Scheduler to call the rotator function with an
#    OIDC-signed identity = $ROTATOR_SA.
gcloud iam service-accounts add-iam-policy-binding "$ROTATOR_SA" \
  --member="serviceAccount:$ROTATOR_SA" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project="$PROJECT_ID"
```

**Note:** `roles/run.invoker` on the deployed rotator function is granted
automatically by `cloud_function_rotator/deploy.sh` after the function is
deployed (so it can target the actual resource).

## Verify

```bash
# SA exists?
gcloud iam service-accounts describe "$ROTATOR_SA" --project="$PROJECT_ID"

# Has secretmanager.admin?
gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --format='table(bindings.role,bindings.members)' \
  --filter="bindings.members:$ROTATOR_SA"
```

Expected output: shows `roles/secretmanager.admin` bound to
`arboryx-rotator-sa@…`.

## After this is done

```bash
bash cloud_function_rotator/deploy.sh
```

Will deploy the rotator function (`arboryx-key-rotator`), grant
`roles/run.invoker` on it to the rotator SA, and create the Cloud
Scheduler job (`arboryx-key-rotator-quarterly`, 09:00 on the 1st of
Jan/Apr/Jul/Oct).

## Trigger a one-off rotation immediately (optional, post-deploy)

```bash
gcloud scheduler jobs run arboryx-key-rotator-quarterly \
  --location="$LOCATION" --project="$PROJECT_ID"
```

Then check the rotator's logs:

```bash
gcloud functions logs read arboryx-key-rotator \
  --gen2 --region="$LOCATION" --project="$PROJECT_ID" --limit=20
```

Expect a `rotator_complete {...}` line with the new version name and any
disabled (>30-day-old) versions listed.
