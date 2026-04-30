#!/usr/bin/env bash
# ============================================================================
# cloud_function_rotator/test_fire.sh — manually trigger the rotator + verify
#
# Side-effects:
#   - Adds a NEW ENABLED version to arboryx-admin-key (cannot be undone).
#   - Disables any version >30 days old (per DISABLE_OLDER_THAN_DAYS in deploy
#     env). On freshly-deployed projects this is a no-op (everything is young).
#
# Use this to:
#   - Smoke-test the deploy after rotator code changes.
#   - Force a key cycle outside the quarterly schedule.
#
# Will NOT touch: arboryx-public-key (manual rotation only — see
# dev-utils/rotate_key.sh public).
#
# Usage:
#   bash cloud_function_rotator/test_fire.sh
#   bash cloud_function_rotator/test_fire.sh --yes        # skip the confirmation
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1090
source "$REPO_ROOT/arboryx_admin_backend.config"

ROTATOR_NAME="${ROTATOR_NAME:-arboryx-key-rotator}"
SCHEDULER_JOB="${SCHEDULER_JOB:-arboryx-key-rotator-quarterly}"
ADMIN_SECRET_NAME="${ADMIN_SECRET_NAME:-arboryx-admin-key}"

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

header "============================================"
header "  Arboryx Rotator — Test Fire"
header "============================================"
info "Function   : $ROTATOR_NAME"
info "Scheduler  : $SCHEDULER_JOB"
info "Secret     : $ADMIN_SECRET_NAME"
info "Project    : $PROJECT_ID"
info "Region     : $LOCATION"
echo

header "--- Before: $ADMIN_SECRET_NAME versions ---"
gcloud secrets versions list "$ADMIN_SECRET_NAME" --project="$PROJECT_ID" 2>&1 | head -10
echo

if [[ "$YES" != true ]]; then
  warn "This will rotate $ADMIN_SECRET_NAME — a new ENABLED version will be added."
  warn "Any existing version >30 days old will be DISABLED (none on a fresh project)."
  read -r -p "Continue? (y/N) " confirm
  [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { info "Aborted."; exit 0; }
  echo
fi

header "--- Firing scheduler job ---"
gcloud scheduler jobs run "$SCHEDULER_JOB" \
  --location="$LOCATION" --project="$PROJECT_ID"
ok "Scheduler kicked. Cloud Scheduler will POST to the rotator function within ~5s."
echo

info "Waiting 8s for invocation to complete..."
sleep 8

header "--- After: $ADMIN_SECRET_NAME versions ---"
gcloud secrets versions list "$ADMIN_SECRET_NAME" --project="$PROJECT_ID" 2>&1 | head -10
echo

header "--- Last 20 rotator log lines ---"
gcloud functions logs read "$ROTATOR_NAME" \
  --gen2 --region="$LOCATION" --project="$PROJECT_ID" --limit=20 2>&1 | head -40
echo

info "Look for a 'rotator_complete {...}' line above with status=ok."
info "If you see 'rotator_failed' instead, the new version DID land but the"
info "disable path crashed — fix the function code and redeploy."
echo
header "============================================"
ok "Test fire dispatched."
header "============================================"
info "Old + new admin-key versions are both ENABLED — soak window starts now."
info "After ~30 days the next scheduler firing will auto-disable v1."
info ""
info "Verify the API still authenticates with both keys:"
info "  python3 dev-utils/test_api.py --suite auth"
