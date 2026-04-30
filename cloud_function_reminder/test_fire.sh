#!/usr/bin/env bash
# ============================================================================
# cloud_function_reminder/test_fire.sh — manually trigger the reminder + verify
#
# Side-effects:
#   - Sends ONE email to REMINDER_RECIPIENT (set in arboryx_admin_backend.config)
#     using the SMTP credentials from Secret Manager.
#   - Reads arboryx-smtp-pass from Secret Manager (one access; logged in
#     audit logs as expected).
#
# Use this to:
#   - Smoke-test the deploy + IAM + Secret Manager + SMTP path end-to-end.
#   - Re-trigger the reminder text outside the quarterly schedule.
#
# Usage:
#   bash cloud_function_reminder/test_fire.sh
#   bash cloud_function_reminder/test_fire.sh --yes        # skip the confirmation
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1090
source "$REPO_ROOT/arboryx_admin_backend.config"

REMINDER_NAME="${REMINDER_NAME:-arboryx-rotation-reminder}"
SCHEDULER_JOB="${REMINDER_SCHEDULER_JOB:-arboryx-rotation-reminder-quarterly}"

if [[ -t 1 ]]; then
  C_HDR=$'\033[1m'; C_OK=$'\033[0;32m'; C_INFO=$'\033[0;36m'; C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'; C_OFF=$'\033[0m'
else
  C_HDR=''; C_OK=''; C_INFO=''; C_WARN=''; C_ERR=''; C_OFF=''
fi
header() { echo -e "${C_HDR}$*${C_OFF}"; }
ok()     { echo -e "${C_OK}[OK]${C_OFF}    $*"; }
info()   { echo -e "${C_INFO}[INFO]${C_OFF}  $*"; }
warn()   { echo -e "${C_WARN}[WARN]${C_OFF}  $*"; }
err()    { echo -e "${C_ERR}[ERR]${C_OFF}   $*" >&2; }

YES=false
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && YES=true

: "${REMINDER_RECIPIENT:?REMINDER_RECIPIENT not set in arboryx_admin_backend.config}"

header "============================================"
header "  Arboryx Reminder — Test Fire"
header "============================================"
info "Function   : $REMINDER_NAME"
info "Scheduler  : $SCHEDULER_JOB"
info "Recipient  : $REMINDER_RECIPIENT"
info "From       : ${SMTP_FROM:-${SMTP_USER:-<unset>}}"
info "SMTP host  : ${SMTP_HOST:-smtp.gmail.com}:${SMTP_PORT:-587}"
info "Project    : $PROJECT_ID"
info "Region     : $LOCATION"
echo

if [[ "$YES" != true ]]; then
  warn "This will send ONE real email to $REMINDER_RECIPIENT."
  read -r -p "Continue? (y/N) " confirm
  [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { info "Aborted."; exit 0; }
  echo
fi

header "--- Firing scheduler job ---"
gcloud scheduler jobs run "$SCHEDULER_JOB" \
  --location="$LOCATION" --project="$PROJECT_ID"
ok "Scheduler kicked. Cloud Scheduler will POST to the reminder function within ~5s."
echo

info "Waiting 12s for invocation + SMTP handshake to complete..."
sleep 12

header "--- Last 20 reminder log lines ---"
gcloud functions logs read "$REMINDER_NAME" \
  --gen2 --region="$LOCATION" --project="$PROJECT_ID" --limit=20 2>&1 | head -40
echo

info "Look for a 'reminder_sent {...}' line above with status=ok."
info "If you see 'reminder_failed' instead, common causes are:"
info "  - SMTP_PASSWORD not synced to Secret Manager  (run dev-utils/rotate_key.sh smtp)"
info "  - SMTP_USER mismatch between config and Gmail account"
info "  - reminder SA missing secretmanager.secretAccessor role"
echo
header "============================================"
ok "Test fire dispatched."
header "============================================"
info "Check inbox: $REMINDER_RECIPIENT (typical delivery <30s after this script ends)."
