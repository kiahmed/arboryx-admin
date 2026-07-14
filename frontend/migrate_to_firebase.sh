#!/bin/bash
# ============================================================================
# migrate_to_firebase.sh — one-time cutover of the arboryx.ai apex (tier-1)
# from the GCS bucket to Firebase Hosting.
# ----------------------------------------------------------------------------
# Steps (each idempotent):
#   1. IDEMPOTENCY GATE — ask Firebase whether arboryx.ai is already an ACTIVE
#      custom domain on the hosting site. If so, print "migration already done"
#      and STOP (does not redeploy or touch DNS).
#   2. Deploy the frontend tree to Firebase Hosting  (frontend/deploy.sh --firebase).
#   3. Link the apex domain: register arboryx.ai on the site, push the required
#      A/AAAA/TXT records into Cloudflare (replacing the old GCS CNAME), poll
#      until active                                    (frontend/link_domain.py).
#
# After it reports live, the old GCS bucket + its Cloudflare CNAME are no longer
# in the serving path and can be retired (NOT done automatically — see the note
# printed at the end).
#
# Usage:
#   bash frontend/migrate_to_firebase.sh            # do the migration
#   bash frontend/migrate_to_firebase.sh --dry-run  # show what would happen
#   (or:  make migrate  [DRY=1] )
#
# Identity: creating the hosting site + registering the custom domain both need
# roles/firebasehosting.admin. Both steps honor GOOGLE_APPLICATION_CREDENTIALS,
# so point it at a service-account key with that role to run the WHOLE migration
# as that SA (one identity for both the firebase CLI and link_domain.py):
#   GOOGLE_APPLICATION_CREDENTIALS=dev-utils/service_account.json make migrate
# Otherwise it uses your interactive `firebase login` / `gcloud` account.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}$*${RESET}"; }

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) err "Unknown argument: $arg"; exit 1 ;;
  esac
done

CONFIG_FILE="$SCRIPT_DIR/arboryx_frontend.config"
[[ -f "$CONFIG_FILE" ]] || { err "Copy arboryx_frontend.config.example → arboryx_frontend.config and fill it in."; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"
: "${FIREBASE_PROJECT:?FIREBASE_PROJECT not set in arboryx_frontend.config}"
: "${FIREBASE_SITE:=arboryx-ai}"
APEX="arboryx.ai"

# Preconditions
for bin in firebase gcloud python3; do
  command -v "$bin" >/dev/null 2>&1 || { err "$bin not found on PATH."; exit 1; }
done

header "============================================"
header "  arboryx.ai apex → Firebase Hosting migration"
header "============================================"
info "Project : $FIREBASE_PROJECT"
info "Site    : $FIREBASE_SITE"
info "Apex    : $APEX"
info "Dry-run : $DRY_RUN"

# ---------------------------------------------------------------------------
# 1. Idempotency gate
# ---------------------------------------------------------------------------
header "--- Step 1: check if already migrated ---"
set +e
python3 "$SCRIPT_DIR/link_domain.py" --check
CHECK_RC=$?
set -e
if [[ "$CHECK_RC" -eq 0 ]]; then
  success "Migration already done — $APEX is already served (ACTIVE) by Firebase Hosting."
  info "Nothing to do. To re-deploy content only: make frontend-firebase"
  exit 0
elif [[ "$CHECK_RC" -eq 2 ]]; then
  warn "Could not determine migration status (auth/API error above). Aborting to be safe."
  exit 2
fi
info "Not yet on Firebase Hosting (check rc=$CHECK_RC) — proceeding with migration."

if [[ "$DRY_RUN" == true ]]; then
  header "--- DRY RUN: would perform steps 2 and 3 ---"
  info "Step 2 would run: bash $SCRIPT_DIR/deploy.sh --firebase"
  info "Step 3 would run: python3 $SCRIPT_DIR/link_domain.py"
  echo
  python3 "$SCRIPT_DIR/link_domain.py" --dry-run || true
  echo
  success "Dry run complete. No changes made."
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Deploy content to Firebase Hosting
# ---------------------------------------------------------------------------
header "--- Step 2: deploy frontend to Firebase Hosting ---"
bash "$SCRIPT_DIR/deploy.sh" --firebase

# ---------------------------------------------------------------------------
# 3. Link the apex domain + flip Cloudflare DNS
# ---------------------------------------------------------------------------
header "--- Step 3: link $APEX + Cloudflare DNS cutover ---"
python3 "$SCRIPT_DIR/link_domain.py"

echo
header "============================================"
success "Migration steps complete."
header "============================================"
info "Verify: curl -sI https://$APEX should now be served by Firebase Hosting."
warn "The old GCS bucket ('$APEX') + its Cloudflare CNAME (→ c.storage.googleapis.com)"
warn "are NO LONGER in the serving path once the new A/AAAA records propagate."
warn "Retire them manually only AFTER you've confirmed the site is live on Firebase:"
info "  - remove the old apex CNAME in Cloudflare if link_domain didn't overwrite it"
info "  - the bucket can be kept as a backup or deleted once you're confident"
info "Re-running this script is safe — it will report 'already done' once active."
