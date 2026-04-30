#!/usr/bin/env bash
# ============================================================================
# cloud_function_rotator/deploy.sh — deploy arboryx-key-rotator + scheduler
#
# Idempotent. Safe to re-run.
#
# Prereqs (run ONCE, before this script):
#   1. APIs enabled: cloudfunctions, cloudscheduler, secretmanager, run, iam
#   2. SA + perms ready — bash cloud_function_rotator/make_rotator_pipeline_ready.sh
#   3. roles/run.invoker on the deployed function — this script grants it
#
# See cloud_function_rotator/IAM_SETUP.md for the manual / longer-form
# version of step 2 if you want to read what make_rotator_pipeline_ready.sh
# automates.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1090
source "$REPO_ROOT/arboryx_admin_backend.config"

# Tunables
ROTATOR_NAME="${ROTATOR_NAME:-arboryx-key-rotator}"
ROTATOR_SA="${ROTATOR_SA:-arboryx-rotator-sa@${PROJECT_ID}.iam.gserviceaccount.com}"
ROTATOR_DIR="$SCRIPT_DIR"
SCHEDULE_CRON="${SCHEDULE_CRON:-0 9 1 1,4,7,10 *}"   # 09:00 on the 1st of Jan/Apr/Jul/Oct (quarterly)
SCHEDULE_TZ="${SCHEDULE_TZ:-America/New_York}"
SCHEDULER_JOB="${SCHEDULER_JOB:-arboryx-key-rotator-quarterly}"

# Colour helpers
if [[ -t 1 ]]; then
  C_HDR=$'\033[1m'; C_OK=$'\033[0;32m'; C_INFO=$'\033[0;36m'; C_WARN=$'\033[0;33m'; C_OFF=$'\033[0m'
else
  C_HDR=''; C_OK=''; C_INFO=''; C_WARN=''; C_OFF=''
fi
header() { echo -e "${C_HDR}$*${C_OFF}"; }
ok()     { echo -e "${C_OK}[OK]${C_OFF}    $*"; }
info()   { echo -e "${C_INFO}[INFO]${C_OFF}  $*"; }
warn()   { echo -e "${C_WARN}[WARN]${C_OFF}  $*"; }

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

header "============================================"
header "  Arboryx — Rotator Deploy"
header "============================================"
info "Function   : $ROTATOR_NAME"
info "Service AC : $ROTATOR_SA"
info "Schedule   : $SCHEDULE_CRON ($SCHEDULE_TZ)"
info "Project    : $PROJECT_ID"
info "Region     : $LOCATION"
info "Dry-run    : $DRY_RUN"
echo

# ---------------------------------------------------------------------------
# 1) Sanity check: rotator SA must exist
# ---------------------------------------------------------------------------
if ! gcloud iam service-accounts describe "$ROTATOR_SA" --project="$PROJECT_ID" >/dev/null 2>&1; then
  warn "Service account $ROTATOR_SA does not exist."
  warn "Run 'bash cloud_function_rotator/make_rotator_pipeline_ready.sh' first, then re-run this script."
  exit 1
fi
ok "Rotator SA exists."

# ---------------------------------------------------------------------------
# 2) Deploy the rotator function (Gen 2, internal-only ingress)
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
  info "Would run: gcloud functions deploy $ROTATOR_NAME --gen2 --region=$LOCATION ..."
else
  header "--- Step 1: Deploy rotator function ---"
  gcloud functions deploy "$ROTATOR_NAME" \
    --gen2 \
    --region="$LOCATION" \
    --runtime=python312 \
    --source="$ROTATOR_DIR" \
    --entry-point=rotator_handler \
    --trigger-http \
    --no-allow-unauthenticated \
    --ingress-settings=internal-and-gclb \
    --timeout=60s \
    --memory=256Mi \
    --max-instances=1 \
    --set-env-vars="PROJECT_ID=$PROJECT_ID,ADMIN_SECRET_NAME=arboryx-admin-key,DISABLE_OLDER_THAN_DAYS=30" \
    --service-account="$ROTATOR_SA" \
    --project="$PROJECT_ID"
  ok "Rotator function deployed."
fi

# ---------------------------------------------------------------------------
# 3) Get the rotator's Cloud Run URL (Gen 2 functions are Cloud Run under the hood)
# ---------------------------------------------------------------------------
ROTATOR_URL=$(gcloud functions describe "$ROTATOR_NAME" \
  --gen2 --region="$LOCATION" --project="$PROJECT_ID" \
  --format='value(serviceConfig.uri)' 2>/dev/null || true)
if [[ -z "$ROTATOR_URL" ]]; then
  warn "Could not resolve rotator URL (deploy probably failed)."
  exit 1
fi
info "Rotator URL: $ROTATOR_URL"

# ---------------------------------------------------------------------------
# 4) Grant the rotator SA run.invoker on its OWN function so Cloud Scheduler
#    (using the same SA via OIDC) can call it.
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
  info "Would grant run.invoker on $ROTATOR_NAME to $ROTATOR_SA"
else
  gcloud run services add-iam-policy-binding "$ROTATOR_NAME" \
    --region="$LOCATION" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:$ROTATOR_SA" \
    --role="roles/run.invoker" >/dev/null
  ok "Granted run.invoker."
fi

# ---------------------------------------------------------------------------
# 5) Create or update Cloud Scheduler job
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
  info "Would create/update scheduler job '$SCHEDULER_JOB' with cron='$SCHEDULE_CRON'"
else
  header "--- Step 2: Cloud Scheduler job ---"
  if gcloud scheduler jobs describe "$SCHEDULER_JOB" \
        --location="$LOCATION" --project="$PROJECT_ID" >/dev/null 2>&1; then
    info "Updating existing job '$SCHEDULER_JOB'..."
    gcloud scheduler jobs update http "$SCHEDULER_JOB" \
      --location="$LOCATION" \
      --project="$PROJECT_ID" \
      --schedule="$SCHEDULE_CRON" \
      --time-zone="$SCHEDULE_TZ" \
      --uri="$ROTATOR_URL" \
      --http-method=POST \
      --oidc-service-account-email="$ROTATOR_SA" \
      --oidc-token-audience="$ROTATOR_URL"
  else
    info "Creating job '$SCHEDULER_JOB'..."
    gcloud scheduler jobs create http "$SCHEDULER_JOB" \
      --location="$LOCATION" \
      --project="$PROJECT_ID" \
      --schedule="$SCHEDULE_CRON" \
      --time-zone="$SCHEDULE_TZ" \
      --uri="$ROTATOR_URL" \
      --http-method=POST \
      --oidc-service-account-email="$ROTATOR_SA" \
      --oidc-token-audience="$ROTATOR_URL"
  fi
  ok "Scheduler job ready: $SCHEDULER_JOB"
fi

echo
header "============================================"
ok "Rotator deploy complete."
header "============================================"
info "Next firing : $SCHEDULE_CRON ($SCHEDULE_TZ)"
info ""
info "Trigger NOW for verification (will rotate the admin key — soak window applies):"
info "  gcloud scheduler jobs run $SCHEDULER_JOB --location=$LOCATION --project=$PROJECT_ID"
info ""
info "View past runs:"
info "  gcloud functions logs read $ROTATOR_NAME --gen2 --region=$LOCATION --project=$PROJECT_ID --limit=20"
info ""
info "Force the api function to re-read all enabled secret versions (cold-start kick):"
info "  gcloud run services update $FUNCTION_NAME --region=$LOCATION --project=$PROJECT_ID --update-env-vars=_KICK=\$(date +%s)"
info "  (Gen2 functions ARE Cloud Run services; --update-env-vars creates a new"
info "   revision without rebuilding the source. Optional — Cloud Run idles old"
info "   instances within ~15 min anyway, so new key versions get picked up naturally.)"
