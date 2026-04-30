#!/bin/bash
# deploy_arboryx-admin.sh
# Uploads the Arboryx admin UI (arborist_*.html) to GCS and sets it
# publicly readable. Public landing page is deployed via frontend/deploy.sh.
#
# Usage:
#   bash deploy_arboryx-admin.sh
#   bash deploy_arboryx-admin.sh --dry-run

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()     { echo -e "${RED}[ERROR]${RESET} $*"; }

# -- Parse flags --
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *)
            err "Unknown argument: $arg"
            echo "Usage: bash deploy_arboryx-admin.sh [--dry-run]"
            exit 1
            ;;
    esac
done

# -- Load config --
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/arboryx_admin_ui.config"

if [[ ! -f "$CONFIG_FILE" ]]; then
    err "Config file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

# -- Validate --
UI_PATH="$SCRIPT_DIR/$UI_FILE"

if [[ ! -f "$UI_PATH" ]]; then
    err "UI file not found: $UI_PATH"
    exit 1
fi

API_URL="${API_URL:-}"
API_KEY="${API_KEY:-}"

if [[ -z "$API_URL" ]]; then
    err "API_URL is not set in arboryx_admin_ui.config"
    exit 1
fi
if [[ -z "$API_KEY" ]]; then
    err "API_KEY is not set in arboryx_admin_ui.config"
    exit 1
fi

# Check that source file has placeholders (not already injected)
if ! grep -q '__ARBORYX_ADMIN_API_URL__' "$UI_PATH" || ! grep -q '__ARBORYX_ADMIN_API_KEY__' "$UI_PATH"; then
    err "Placeholders not found in $UI_FILE — has it already been injected into the source?"
    exit 1
fi

GCS_DEST="gs://${STORAGE_BUCKET}/${UI_FILE}"

echo ""
echo -e "${BOLD}============================================${RESET}"
echo -e "${BOLD}  Arboryx Admin UI — Deploy${RESET}"
echo -e "${BOLD}============================================${RESET}"
echo ""
info "Project  : $PROJECT_ID"
info "Bucket   : $STORAGE_BUCKET"
info "File     : $UI_FILE"
info "API URL  : $API_URL"
info "API Key  : ***${API_KEY: -4}"
info "Dest     : $GCS_DEST"
echo ""

# -- Dry run --
if [[ "$DRY_RUN" == true ]]; then
    info "Would inject API_URL and API_KEY into temp copy of $UI_FILE"
    info "Would run: gsutil -h Content-Type:text/html -h Cache-Control:no-cache,max-age=0 cp <temp> \"$GCS_DEST\""
    info "Would run: gsutil acl ch -u AllUsers:R \"$GCS_DEST\""
    info "Would upload assets/favicon.ico to gs://${STORAGE_BUCKET}/favicon.ico (if not already present)"
    echo ""
    success "Dry run complete. No changes were made."
    exit 0
fi

# -- Build temp file with injected API key --
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

sed -e "s|__ARBORYX_ADMIN_API_URL__|${API_URL}|g" \
    -e "s|__ARBORYX_ADMIN_API_KEY__|${API_KEY}|g" \
    "$UI_PATH" > "$TMPFILE"
info "API_URL and API_KEY injected into temp build."

# -- Upload --
info "Uploading ${UI_FILE}..."
gsutil -h "Content-Type:text/html" \
       -h "Cache-Control:no-cache, max-age=0" \
       cp "$TMPFILE" "$GCS_DEST"
success "Uploaded to $GCS_DEST"

# -- Make public --
info "Setting public access..."
gsutil acl ch -u AllUsers:R "$GCS_DEST"
success "Public read enabled."

# -- Favicon (upload once; gsutil cp -n skips if dest exists) --
FAVICON_SRC="$SCRIPT_DIR/assets/favicon.ico"
FAVICON_DEST="gs://${STORAGE_BUCKET}/favicon.ico"
if [[ -f "$FAVICON_SRC" ]]; then
    if gsutil -q stat "$FAVICON_DEST"; then
        info "favicon.ico already present in bucket — skipping upload."
    else
        info "Uploading favicon.ico..."
        gsutil -h "Content-Type:image/x-icon" \
               -h "Cache-Control:public, max-age=604800" \
               cp "$FAVICON_SRC" "$FAVICON_DEST"
        gsutil acl ch -u AllUsers:R "$FAVICON_DEST"
        success "favicon.ico uploaded."
    fi
else
    warn "favicon.ico not found at $FAVICON_SRC — skipping."
fi

# -- Output URL --
PUBLIC_URL="https://storage.googleapis.com/${STORAGE_BUCKET}/${UI_FILE}"

echo ""
echo -e "${BOLD}============================================${RESET}"
echo -e "${BOLD}  Deploy complete!${RESET}"
echo -e "${BOLD}============================================${RESET}"
echo ""
info "Public URL:"
echo ""
echo "  $PUBLIC_URL"
echo ""
