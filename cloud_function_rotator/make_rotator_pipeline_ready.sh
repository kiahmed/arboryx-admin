#!/usr/bin/env bash
# ============================================================================
# make_rotator_pipeline_ready.sh — one-time IAM bootstrap for the rotator
#
# Idempotent. Safe to re-run. Creates the dedicated rotator service account
# and grants the minimum perms needed:
#   - secretmanager.admin            (mint/disable secret versions)
#   - iam.serviceAccountTokenCreator (Cloud Scheduler can mint OIDC tokens
#                                     as this SA, calling the rotator HTTP fn)
#
# Why a separate SA (not market-agent-sa)?
#   The main API function runs as market-agent-sa with secretmanager.secretAccessor
#   (READ only). Granting it admin would mean: if the public-facing API is ever
#   exploited, the attacker also gets full Secret Manager mutation. Keeping the
#   rotator on its own SA isolates that blast radius.
#
# What this script does NOT do:
#   - Deploy the rotator function itself  (run cloud_function_rotator/deploy.sh)
#   - Grant run.invoker on the function   (deploy.sh handles that — function
#                                          must exist before role can be bound)
#
# Usage:
#   bash cloud_function_rotator/make_rotator_pipeline_ready.sh
#   bash cloud_function_rotator/make_rotator_pipeline_ready.sh --dry-run
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/arboryx_admin_backend.config"

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

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

if [[ ! -f "$CONFIG_FILE" ]]; then
  err "Config not found: $CONFIG_FILE"
  err "Copy from .example, populate PROJECT_ID, then re-run."
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
: "${PROJECT_ID:?PROJECT_ID not set in $CONFIG_FILE}"

ROTATOR_SA_NAME="${ROTATOR_SA_NAME:-arboryx-rotator-sa}"
ROTATOR_SA="${ROTATOR_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

header "============================================"
header "  Arboryx — Rotator IAM Bootstrap"
header "============================================"
info "Project    : $PROJECT_ID"
info "Service AC : $ROTATOR_SA"
info "Dry-run    : $DRY_RUN"
echo

# ---------------------------------------------------------------------------
# 1) Create the rotator SA (idempotent)
# ---------------------------------------------------------------------------
if gcloud iam service-accounts describe "$ROTATOR_SA" --project="$PROJECT_ID" >/dev/null 2>&1; then
  ok "SA already exists: $ROTATOR_SA"
else
  if [[ "$DRY_RUN" == true ]]; then
    info "[dry-run] would create SA $ROTATOR_SA"
  else
    info "Creating SA $ROTATOR_SA..."
    gcloud iam service-accounts create "$ROTATOR_SA_NAME" \
      --display-name="Arboryx scheduled key rotator" \
      --description="Rotates arboryx-admin-key on a quarterly schedule. Used by Cloud Scheduler + the rotator Cloud Function. NOT used by the public API." \
      --project="$PROJECT_ID"
    ok "SA created."
  fi
fi

# ---------------------------------------------------------------------------
# 2) Grant roles/secretmanager.admin (project-scoped).
#    add-iam-policy-binding is idempotent — re-runs are no-ops.
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
  info "[dry-run] would grant roles/secretmanager.admin on $PROJECT_ID to $ROTATOR_SA"
else
  info "Granting roles/secretmanager.admin..."
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$ROTATOR_SA" \
    --role="roles/secretmanager.admin" \
    --condition=None \
    --quiet >/dev/null
  ok "Granted roles/secretmanager.admin."
fi

# ---------------------------------------------------------------------------
# 3) Allow this SA to act-as itself (Cloud Scheduler OIDC token minting).
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
  info "[dry-run] would grant roles/iam.serviceAccountTokenCreator on self"
else
  info "Granting roles/iam.serviceAccountTokenCreator..."
  gcloud iam service-accounts add-iam-policy-binding "$ROTATOR_SA" \
    --member="serviceAccount:$ROTATOR_SA" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --project="$PROJECT_ID" \
    --quiet >/dev/null
  ok "Granted roles/iam.serviceAccountTokenCreator."
fi

echo
header "============================================"
ok "Rotator pipeline IAM ready."
header "============================================"
info "Next:"
info "  bash cloud_function_rotator/deploy.sh"
info ""
info "Verify SA + bindings:"
info "  gcloud iam service-accounts describe $ROTATOR_SA --project=$PROJECT_ID"
info "  gcloud projects get-iam-policy $PROJECT_ID \\"
info "    --flatten='bindings[].members' \\"
info "    --format='table(bindings.role,bindings.members)' \\"
info "    --filter='bindings.members:$ROTATOR_SA'"
