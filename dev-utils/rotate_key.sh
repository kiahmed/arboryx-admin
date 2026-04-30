#!/usr/bin/env bash
# ============================================================================
# rotate_key.sh — on-demand rotation of arboryx-admin-key OR arboryx-public-key
#
# Adds a new ENABLED version to the named secret. The Cloud Function reads
# ALL enabled versions at cold start and accepts any of them, so the OLD key
# keeps working until you explicitly disable it (--finalize, after soak).
#
# Usage:
#   bash dev-utils/rotate_key.sh public           # rotate the read-only public key
#   bash dev-utils/rotate_key.sh admin            # rotate the admin write key
#   bash dev-utils/rotate_key.sh smtp             # sync SMTP password from config into Secret Manager
#                                                 #   (auto: only adds a new version if the value changed)
#   bash dev-utils/rotate_key.sh public --dry-run # show what would happen
#   bash dev-utils/rotate_key.sh public --finalize <old_version>
#                                                 # disable an old version after soak
#
# After ROTATION (not finalize):
#   public key   -> also re-deploys the frontend so scripts/config.js carries
#                   the new key (you'll be prompted before the deploy fires)
#   admin key    -> updates arboryx_admin_backend.config + reminds you to
#                   re-deploy the Cloud Function so the env-var fallback
#                   matches the new active value (Secret Manager already does)
#
# Soak window:
#   Default: 7 days. Both old + new versions stay ENABLED so consumers cut
#   over gracefully. After the soak, run with --finalize to disable the old
#   version (it stays in history; can be re-enabled if needed).
# ============================================================================

set -euo pipefail

# Resolve repo root regardless of where this script is invoked from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colour helpers (no-op if not a TTY)
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

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
KIND="${1:-}"
DRY_RUN=false
FINALIZE_VERSION=""

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --finalize) FINALIZE_VERSION="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) err "Unknown flag: $1"; exit 1 ;;
  esac
done

if [[ "$KIND" != "public" && "$KIND" != "admin" && "$KIND" != "smtp" ]]; then
  err "First arg must be 'public', 'admin', or 'smtp'"
  echo "  bash dev-utils/rotate_key.sh public"
  echo "  bash dev-utils/rotate_key.sh admin"
  echo "  bash dev-utils/rotate_key.sh smtp"
  echo "  bash dev-utils/rotate_key.sh public --finalize 1"
  exit 1
fi

case "$KIND" in
  public) SECRET_NAME="arboryx-public-key"; CONFIG_FIELD="READ_ONLY_API_KEYS" ;;
  admin)  SECRET_NAME="arboryx-admin-key";  CONFIG_FIELD="API_KEY" ;;
  smtp)   SECRET_NAME="arboryx-smtp-pass";  CONFIG_FIELD="SMTP_PASSWORD" ;;
esac

# ---------------------------------------------------------------------------
# Load project + bail early on missing config
# ---------------------------------------------------------------------------
CONFIG_FILE="$REPO_ROOT/arboryx_admin_backend.config"
if [[ ! -f "$CONFIG_FILE" ]]; then
  err "$CONFIG_FILE not found — copy from .example and populate."
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
: "${PROJECT_ID:?PROJECT_ID not set in $CONFIG_FILE}"

header "============================================"
header "  Arboryx — Key Rotation"
header "============================================"
info "Secret      : $SECRET_NAME"
info "Project     : $PROJECT_ID"
info "Mode        : $(if [[ -n "$FINALIZE_VERSION" ]]; then echo "finalize v$FINALIZE_VERSION"; else echo "rotate (add new version)"; fi)"
info "Dry-run     : $DRY_RUN"
echo

# ---------------------------------------------------------------------------
# FINALIZE path — disable an old version
# ---------------------------------------------------------------------------
if [[ -n "$FINALIZE_VERSION" ]]; then
  info "Will disable version $FINALIZE_VERSION of $SECRET_NAME."
  warn "After this, that version's key value will be REJECTED by the API."
  warn "Make sure no clients still hold it (soak window passed)."
  read -r -p "Continue? (y/N) " confirm
  [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { info "Aborted."; exit 0; }

  if [[ "$DRY_RUN" == true ]]; then
    info "Would run: gcloud secrets versions disable $FINALIZE_VERSION --secret=$SECRET_NAME --project=$PROJECT_ID"
    exit 0
  fi
  gcloud secrets versions disable "$FINALIZE_VERSION" \
    --secret="$SECRET_NAME" \
    --project="$PROJECT_ID"
  ok "Disabled version $FINALIZE_VERSION of $SECRET_NAME."
  warn "Cloud Function warm instances may still hold the disabled key in memory"
  warn "(loaded once at cold start). To evict them immediately, run:"
  info "  bash dev-utils/cold_start_function.sh"
  info "(see that script's header for what it does and when not to skip it.)"
  exit 0
fi

# ---------------------------------------------------------------------------
# ROTATE path — add a new version
# ---------------------------------------------------------------------------
if [[ "$KIND" == "smtp" ]]; then
  # SMTP password isn't generated — it comes from config (the user pasted it
  # in after generating in their Google account). Sync mode: only add a new
  # Secret Manager version if config differs from current 'latest'.
  : "${SMTP_PASSWORD:?SMTP_PASSWORD not set in $CONFIG_FILE}"
  NEW_KEY="$SMTP_PASSWORD"
  CURRENT_LATEST=$(gcloud secrets versions access latest --secret="$SECRET_NAME" --project="$PROJECT_ID" 2>/dev/null || echo "")
  if [[ "$NEW_KEY" == "$CURRENT_LATEST" ]]; then
    ok "Config SMTP_PASSWORD matches Secret Manager 'latest' — no rotation needed."
    info "Current versions:"
    gcloud secrets versions list "$SECRET_NAME" --project="$PROJECT_ID" 2>&1 | head -10
    exit 0
  fi
  info "Config SMTP_PASSWORD differs from Secret Manager 'latest' — will add new version."
  info "  config preview : ${NEW_KEY:0:4}…${NEW_KEY: -4}"
  info "  current preview: ${CURRENT_LATEST:0:4}…${CURRENT_LATEST: -4}"
else
  NEW_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  info "Generated a new key (43 chars, base64-url): ${NEW_KEY:0:8}…${NEW_KEY: -4}"
fi

if [[ "$DRY_RUN" == true ]]; then
  info "Would run: echo -n <new-value> | gcloud secrets versions add $SECRET_NAME --data-file=-"
  case "$KIND" in
    public)
      info "Would update $REPO_ROOT/frontend/arboryx_frontend.config: ARBORYX_PUBLIC_API_KEY=<new>"
      info "Would prompt to run: bash $REPO_ROOT/frontend/deploy.sh"
      ;;
    admin)
      info "Would update $CONFIG_FILE: $CONFIG_FIELD=<new>"
      info "Would prompt to run: bash $REPO_ROOT/cloud_function/deploy.sh"
      ;;
    smtp)
      info "(Config already has the new value — that's our source.) New SM version, no other side-effects."
      info "Reminder function reads 'latest' from Secret Manager at every cold start, picks it up automatically."
      ;;
  esac
  exit 0
fi

# 1) Add as new ENABLED version in Secret Manager
NEW_VER=$(echo -n "$NEW_KEY" | gcloud secrets versions add "$SECRET_NAME" \
  --data-file=- --project="$PROJECT_ID" --format='value(name)')
NEW_VER_NUM="${NEW_VER##*/}"
ok "Added version $NEW_VER_NUM of $SECRET_NAME."

# 2) Update consumer-side config files
if [[ "$KIND" == "public" ]]; then
  FE_CFG="$REPO_ROOT/frontend/arboryx_frontend.config"
  if [[ -f "$FE_CFG" ]]; then
    # Backup, then sed-replace
    cp "$FE_CFG" "$FE_CFG.bak.$(date +%Y%m%d-%H%M%S)"
    if grep -qE '^ARBORYX_PUBLIC_API_KEY=' "$FE_CFG"; then
      sed -i.tmp "s|^ARBORYX_PUBLIC_API_KEY=.*|ARBORYX_PUBLIC_API_KEY=\"$NEW_KEY\"|" "$FE_CFG" && rm -f "$FE_CFG.tmp"
      ok "Updated ARBORYX_PUBLIC_API_KEY in $FE_CFG (backup saved)."
    else
      warn "$FE_CFG had no ARBORYX_PUBLIC_API_KEY line; skipped local update."
    fi
  fi
  echo
  warn "Frontend config.js still has the OLD key until deploy.sh runs."
  read -r -p "Run 'bash frontend/deploy.sh' now to ship new key? (y/N) " confirm
  if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
    bash "$REPO_ROOT/frontend/deploy.sh"
  else
    info "Skipped. Run 'bash frontend/deploy.sh' when ready."
  fi
elif [[ "$KIND" == "admin" ]]; then
  # admin key
  if grep -qE '^API_KEY=' "$CONFIG_FILE"; then
    cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    sed -i.tmp "s|^API_KEY=.*|API_KEY=\"$NEW_KEY\"              # Write-enabled (admin) key (rotated $(date +%Y-%m-%d))|" "$CONFIG_FILE" && rm -f "$CONFIG_FILE.tmp"
    ok "Updated API_KEY in $CONFIG_FILE (backup saved)."
  fi
  echo
  warn "Cloud Function env-var fallback still has the OLD key until redeploy."
  read -r -p "Run 'bash cloud_function/deploy.sh' now to update env-var fallback? (y/N) " confirm
  if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
    bash "$REPO_ROOT/cloud_function/deploy.sh"
  else
    info "Skipped. Run 'bash cloud_function/deploy.sh' when ready."
  fi
else
  # smtp — config is already the new value (that's what we're syncing FROM)
  ok "Config is already authoritative; nothing to update."
  info "The reminder Cloud Function reads 'latest' from Secret Manager at every"
  info "cold start, so it will pick up the new password automatically on next"
  info "invocation (or sooner if the warm instance has been recycled)."
fi

echo
header "============================================"
ok "Rotation complete. New version: $NEW_VER_NUM"
header "============================================"
info "Both OLD and NEW versions of $SECRET_NAME are now ENABLED."
info "Soak window: keep both alive ~7 days, let any cached clients catch up."
info "When you're confident no one's using the old version, finalize:"
info "  bash dev-utils/rotate_key.sh ${KIND} --finalize <OLD_VER_NUMBER>"
echo
info "Current versions (state):"
gcloud secrets versions list "$SECRET_NAME" --project="$PROJECT_ID" 2>&1 | head -10
