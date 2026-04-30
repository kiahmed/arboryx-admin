#!/usr/bin/env bash
# ============================================================================
# cloud_function_reminder/deploy.sh — deploy arboryx-rotation-reminder + scheduler
#
# Idempotent. Safe to re-run.
#
# Prereqs (run ONCE, before this script):
#   1. APIs enabled: cloudfunctions, cloudscheduler, secretmanager, run, iam
#      (already done as part of Phase 1 rotator setup)
#   2. SA + perms ready — bash cloud_function_reminder/make_reminder_pipeline_ready.sh
#   3. SMTP password in Secret Manager — bash dev-utils/rotate_key.sh smtp
#   4. roles/run.invoker on the deployed function — this script grants it
#
# See cloud_function_reminder/IAM_SETUP.md for the manual / longer-form
# version of step 2 if you want to read what make_reminder_pipeline_ready.sh
# automates.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1090
source "$REPO_ROOT/arboryx_admin_backend.config"

# Tunables
REMINDER_NAME="${REMINDER_NAME:-arboryx-rotation-reminder}"
REMINDER_SA="${REMINDER_SA:-arboryx-reminder-sa@${PROJECT_ID}.iam.gserviceaccount.com}"
REMINDER_DIR="$SCRIPT_DIR"
SCHEDULE_CRON="${REMINDER_SCHEDULE_CRON:-0 13 1 1,4,7,10 *}"   # 13:00 UTC = 09:00 EDT (EST shifts to 08:00 in Jan)
SCHEDULE_TZ="${REMINDER_SCHEDULE_TZ:-UTC}"
SCHEDULER_JOB="${REMINDER_SCHEDULER_JOB:-arboryx-rotation-reminder-quarterly}"

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
header "  Arboryx — Reminder Deploy"
header "============================================"
info "Function   : $REMINDER_NAME"
info "Service AC : $REMINDER_SA"
info "Schedule   : $SCHEDULE_CRON ($SCHEDULE_TZ)"
info "Recipient  : ${REMINDER_RECIPIENT:-<unset>}"
info "Project    : $PROJECT_ID"
info "Region     : $LOCATION"
info "Dry-run    : $DRY_RUN"
echo

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
: "${SMTP_USER:?SMTP_USER not set in arboryx_admin_backend.config}"
: "${REMINDER_RECIPIENT:?REMINDER_RECIPIENT not set in arboryx_admin_backend.config}"

if ! gcloud iam service-accounts describe "$REMINDER_SA" --project="$PROJECT_ID" >/dev/null 2>&1; then
  warn "Service account $REMINDER_SA does not exist."
  warn "Run 'bash cloud_function_reminder/make_reminder_pipeline_ready.sh' first, then re-run this script."
  exit 1
fi
ok "Reminder SA exists."

# ---------------------------------------------------------------------------
# 1) Deploy the reminder function (Gen 2)
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
  info "Would run: gcloud functions deploy $REMINDER_NAME --gen2 --region=$LOCATION ..."
else
  header "--- Step 1: Deploy reminder function ---"
  gcloud functions deploy "$REMINDER_NAME" \
    --gen2 \
    --region="$LOCATION" \
    --runtime=python312 \
    --source="$REMINDER_DIR" \
    --entry-point=reminder_handler \
    --trigger-http \
    --no-allow-unauthenticated \
    --ingress-settings=internal-and-gclb \
    --timeout=60s \
    --memory=256Mi \
    --max-instances=1 \
    --set-env-vars="PROJECT_ID=$PROJECT_ID,SMTP_HOST=$SMTP_HOST,SMTP_PORT=$SMTP_PORT,SMTP_USER=$SMTP_USER,SMTP_FROM=${SMTP_FROM:-$SMTP_USER},REMINDER_RECIPIENT=$REMINDER_RECIPIENT,SMTP_PASSWORD_SECRET=arboryx-smtp-pass" \
    --service-account="$REMINDER_SA" \
    --project="$PROJECT_ID"
  ok "Reminder function deployed."
fi

# ---------------------------------------------------------------------------
# 2) Get the function URL + grant invoker
# ---------------------------------------------------------------------------
REMINDER_URL=$(gcloud functions describe "$REMINDER_NAME" \
  --gen2 --region="$LOCATION" --project="$PROJECT_ID" \
  --format='value(serviceConfig.uri)' 2>/dev/null || true)
if [[ -z "$REMINDER_URL" ]]; then
  warn "Could not resolve reminder URL (deploy probably failed)."
  exit 1
fi
info "Reminder URL: $REMINDER_URL"

if [[ "$DRY_RUN" == true ]]; then
  info "Would grant run.invoker on $REMINDER_NAME to $REMINDER_SA"
else
  gcloud run services add-iam-policy-binding "$REMINDER_NAME" \
    --region="$LOCATION" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:$REMINDER_SA" \
    --role="roles/run.invoker" >/dev/null
  ok "Granted run.invoker."
fi

# ---------------------------------------------------------------------------
# 3) Cloud Scheduler job (create or update)
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
  info "Would create/update scheduler job '$SCHEDULER_JOB' with cron='$SCHEDULE_CRON' tz=$SCHEDULE_TZ"
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
      --uri="$REMINDER_URL" \
      --http-method=POST \
      --oidc-service-account-email="$REMINDER_SA" \
      --oidc-token-audience="$REMINDER_URL"
  else
    info "Creating job '$SCHEDULER_JOB'..."
    gcloud scheduler jobs create http "$SCHEDULER_JOB" \
      --location="$LOCATION" \
      --project="$PROJECT_ID" \
      --schedule="$SCHEDULE_CRON" \
      --time-zone="$SCHEDULE_TZ" \
      --uri="$REMINDER_URL" \
      --http-method=POST \
      --oidc-service-account-email="$REMINDER_SA" \
      --oidc-token-audience="$REMINDER_URL"
  fi
  ok "Scheduler job ready: $SCHEDULER_JOB"
fi

echo
header "============================================"
ok "Reminder deploy complete."
header "============================================"
info "Next firing : $SCHEDULE_CRON ($SCHEDULE_TZ)"
info ""
info "Send a TEST EMAIL right now (verifies SMTP + recipient):"
info "  gcloud scheduler jobs run $SCHEDULER_JOB --location=$LOCATION --project=$PROJECT_ID"
info ""
info "View past runs:"
info "  gcloud functions logs read $REMINDER_NAME --gen2 --region=$LOCATION --project=$PROJECT_ID --limit=20"
