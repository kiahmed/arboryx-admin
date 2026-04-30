#!/usr/bin/env bash
# ============================================================================
# make_reminder_pipeline_ready.sh — one-time IAM bootstrap for the reminder
#
# Idempotent. Safe to re-run. Creates the dedicated reminder service account
# and grants the minimum perms needed:
#   - secretmanager.secretAccessor   (read arboryx-smtp-pass at runtime)
#   - iam.serviceAccountTokenCreator (Cloud Scheduler can mint OIDC tokens
#                                     as this SA, calling the reminder fn)
#
# Why a separate SA (not the rotator SA)?
#   The reminder only needs to: read one specific secret + send email. Granting
#   the rotator SA (which has secretmanager.admin) the additional power to send
#   email is unnecessary blast-radius. The reminder SA is read-only and cannot
#   mutate any secret, deploy code, or call any other API.
#
# What this script does NOT do:
#   - Deploy the reminder function itself  (run cloud_function_reminder/deploy.sh)
#   - Grant run.invoker on the function    (deploy.sh handles that — function
#                                           must exist before role can be bound)
#   - Push the SMTP password to Secret Manager (run dev-utils/rotate_key.sh smtp)
#
# Usage:
#   bash cloud_function_reminder/make_reminder_pipeline_ready.sh
#   bash cloud_function_reminder/make_reminder_pipeline_ready.sh --dry-run
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

REMINDER_SA_NAME="${REMINDER_SA_NAME:-arboryx-reminder-sa}"
REMINDER_SA="${REMINDER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

header "============================================"
header "  Arboryx — Reminder IAM Bootstrap"
header "============================================"
info "Project    : $PROJECT_ID"
info "Service AC : $REMINDER_SA"
info "Dry-run    : $DRY_RUN"
echo

# ---------------------------------------------------------------------------
# 1) Create the reminder SA (idempotent)
# ---------------------------------------------------------------------------
if gcloud iam service-accounts describe "$REMINDER_SA" --project="$PROJECT_ID" >/dev/null 2>&1; then
  ok "SA already exists: $REMINDER_SA"
else
  if [[ "$DRY_RUN" == true ]]; then
    info "[dry-run] would create SA $REMINDER_SA"
  else
    info "Creating SA $REMINDER_SA..."
    gcloud iam service-accounts create "$REMINDER_SA_NAME" \
      --display-name="Arboryx rotation-reminder notifier" \
      --description="Sends quarterly rotation-reminder emails via Gmail SMTP. Reads only arboryx-smtp-pass from Secret Manager." \
      --project="$PROJECT_ID"
    ok "SA created."
  fi
fi

# ---------------------------------------------------------------------------
# 2) Grant roles/secretmanager.secretAccessor (project-scoped).
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
  info "[dry-run] would grant roles/secretmanager.secretAccessor on $PROJECT_ID to $REMINDER_SA"
else
  info "Granting roles/secretmanager.secretAccessor..."
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$REMINDER_SA" \
    --role="roles/secretmanager.secretAccessor" \
    --condition=None \
    --quiet >/dev/null
  ok "Granted roles/secretmanager.secretAccessor."
fi

# ---------------------------------------------------------------------------
# 3) Allow this SA to act-as itself (Cloud Scheduler OIDC token minting).
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
  info "[dry-run] would grant roles/iam.serviceAccountTokenCreator on self"
else
  info "Granting roles/iam.serviceAccountTokenCreator..."
  gcloud iam service-accounts add-iam-policy-binding "$REMINDER_SA" \
    --member="serviceAccount:$REMINDER_SA" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --project="$PROJECT_ID" \
    --quiet >/dev/null
  ok "Granted roles/iam.serviceAccountTokenCreator."
fi

echo
header "============================================"
ok "Reminder pipeline IAM ready."
header "============================================"
info "Next:"
info "  bash cloud_function_reminder/deploy.sh"
info ""
info "Tighter scope (optional): if you'd rather restrict the reminder SA to"
info "ONLY the SMTP secret (not all secrets), drop the project-wide grant"
info "and add a per-secret binding instead:"
info ""
info "  gcloud projects remove-iam-policy-binding $PROJECT_ID \\"
info "    --member=serviceAccount:$REMINDER_SA \\"
info "    --role=roles/secretmanager.secretAccessor"
info "  gcloud secrets add-iam-policy-binding arboryx-smtp-pass \\"
info "    --member=serviceAccount:$REMINDER_SA \\"
info "    --role=roles/secretmanager.secretAccessor \\"
info "    --project=$PROJECT_ID"
