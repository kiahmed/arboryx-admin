#!/bin/bash
# deploy_cloud_func.sh
# Unified deploy script for the AlphaSnap UI API backend.
#
# Behaviour:
#   - If the Cloud Function already exists  -> source-only update + env var sync
#   - If it does not exist                  -> full fresh deploy with IAM
#
# Flags:
#   --full      Force a full redeploy even if the function already exists
#   --dry-run   Show what would happen without executing any gcloud commands
#
# Usage:
#   bash deploy_cloud_func.sh
#   bash deploy_cloud_func.sh --full
#   bash deploy_cloud_func.sh --dry-run
#   bash deploy_cloud_func.sh --full --dry-run
#   API_KEY=mykey bash deploy_cloud_func.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
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
header()  { echo -e "\n${BOLD}$*${RESET}"; }

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
FORCE_FULL=false
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --full)    FORCE_FULL=true ;;
        --dry-run) DRY_RUN=true ;;
        *)
            err "Unknown argument: $arg"
            echo "Usage: bash deploy_cloud_func.sh [--full] [--dry-run]"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/as_backend.config"

if [[ ! -f "$CONFIG_FILE" ]]; then
    err "Config file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"
FUNCTION_DIR="$SCRIPT_DIR/cloud_function"

if [[ ! -d "$FUNCTION_DIR" ]]; then
    err "Cloud Function source directory not found: $FUNCTION_DIR"
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve API key (env var overrides config)
# ---------------------------------------------------------------------------
API_KEY="${API_KEY:-}"

if [[ -z "$API_KEY" ]]; then
    warn "API_KEY is not set. The function will deploy without authentication."
    warn "Set API_KEY in as_backend.config or pass via: API_KEY=<key> bash deploy_cloud_func.sh"
    echo ""
    read -rp "Continue without API key? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "Aborting. Set API_KEY and re-run."
        exit 0
    fi
fi

CACHE_TTL_SECONDS="${CACHE_TTL_SECONDS:-300}"

# ---------------------------------------------------------------------------
# Build env vars string
# ---------------------------------------------------------------------------
ENV_VARS="PROJECT_ID=$PROJECT_ID"
ENV_VARS+=",STORAGE_BUCKET=$STORAGE_BUCKET"
ENV_VARS+=",DATA_BLOB=market_findings_log.json"
ENV_VARS+=",CACHE_TTL_SECONDS=$CACHE_TTL_SECONDS"
if [[ -n "$API_KEY" ]]; then
    ENV_VARS+=",API_KEY=$API_KEY"
fi

# ---------------------------------------------------------------------------
# Check if function already exists
# ---------------------------------------------------------------------------
header "============================================"
header "  AlphaSnap UI API — Deploy"
header "============================================"
echo ""

FUNCTION_EXISTS=false

info "Checking if function '${FUNCTION_NAME}' exists in ${LOCATION}..."

if gcloud functions describe "$FUNCTION_NAME" \
    --gen2 \
    --region="$LOCATION" \
    --project="$PROJECT_ID" \
    --format="value(name)" &>/dev/null; then
    FUNCTION_EXISTS=true
    success "Function exists."
else
    info "Function does not exist — will perform fresh deploy."
fi

# ---------------------------------------------------------------------------
# Decide deploy mode
# ---------------------------------------------------------------------------
if [[ "$FUNCTION_EXISTS" == true && "$FORCE_FULL" == false ]]; then
    DEPLOY_MODE="update"
else
    DEPLOY_MODE="full"
fi

if [[ "$FORCE_FULL" == true && "$FUNCTION_EXISTS" == true ]]; then
    warn "Force-full flag set — will do a full redeploy even though function exists."
fi

echo ""
info "Deploy mode : ${BOLD}${DEPLOY_MODE}${RESET}"
info "Function    : $FUNCTION_NAME"
info "Region      : $LOCATION"
info "Runtime     : $FUNCTION_RUNTIME"
info "Memory      : $FUNCTION_MEMORY"
info "Timeout     : $FUNCTION_TIMEOUT"
info "Cache TTL   : ${CACHE_TTL_SECONDS}s"
info "API key     : $(if [[ -n "$API_KEY" ]]; then echo 'SET'; else echo 'NOT SET (open access)'; fi)"
info "Source      : $FUNCTION_DIR"
echo ""

# ---------------------------------------------------------------------------
# Dry-run: show what would happen and exit
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
    header "--- DRY RUN (no changes will be made) ---"
    echo ""

    if [[ "$DEPLOY_MODE" == "full" ]]; then
        info "Would run: gcloud functions deploy $FUNCTION_NAME \\"
        echo "      --gen2 \\"
        echo "      --region=$LOCATION \\"
        echo "      --runtime=$FUNCTION_RUNTIME \\"
        echo "      --source=$FUNCTION_DIR \\"
        echo "      --entry-point=api_handler \\"
        echo "      --trigger-http \\"
        echo "      --timeout=$FUNCTION_TIMEOUT \\"
        echo "      --memory=$FUNCTION_MEMORY \\"
        echo "      --set-env-vars=\"$ENV_VARS\" \\"
        echo "      --service-account=$SA_EMAIL \\"
        echo "      --project=$PROJECT_ID \\"
        echo "      --allow-unauthenticated"
    else
        info "Would run: gcloud functions deploy $FUNCTION_NAME \\"
        echo "      --gen2 \\"
        echo "      --region=$LOCATION \\"
        echo "      --source=$FUNCTION_DIR \\"
        echo "      --set-env-vars=\"$ENV_VARS\" \\"
        echo "      --project=$PROJECT_ID"
    fi

    echo ""
    success "Dry run complete. No changes were made."
    exit 0
fi

# ---------------------------------------------------------------------------
# Execute deploy
# ---------------------------------------------------------------------------
if [[ "$DEPLOY_MODE" == "full" ]]; then
    header "--- Step 1: Full Deploy ---"
    info "Deploying '$FUNCTION_NAME' (full: infra + source + env + IAM)..."
    echo ""

    gcloud functions deploy "$FUNCTION_NAME" \
        --gen2 \
        --region="$LOCATION" \
        --runtime="$FUNCTION_RUNTIME" \
        --source="$FUNCTION_DIR" \
        --entry-point=api_handler \
        --trigger-http \
        --timeout="$FUNCTION_TIMEOUT" \
        --memory="$FUNCTION_MEMORY" \
        --set-env-vars="$ENV_VARS" \
        --service-account="$SA_EMAIL" \
        --project="$PROJECT_ID" \
        --allow-unauthenticated

    success "Full deploy complete."
else
    header "--- Step 1: Source + Env Update ---"
    info "Updating '$FUNCTION_NAME' (source + env vars only)..."
    echo ""

    gcloud functions deploy "$FUNCTION_NAME" \
        --gen2 \
        --region="$LOCATION" \
        --source="$FUNCTION_DIR" \
        --set-env-vars="$ENV_VARS" \
        --project="$PROJECT_ID"

    success "Source + env update complete."
fi

# ---------------------------------------------------------------------------
# Retrieve function URL
# ---------------------------------------------------------------------------
header "--- Step 2: Verify ---"

FUNCTION_URL=$(gcloud functions describe "$FUNCTION_NAME" \
    --gen2 \
    --region="$LOCATION" \
    --project="$PROJECT_ID" \
    --format="value(serviceConfig.uri)" 2>/dev/null)

if [[ -z "$FUNCTION_URL" ]]; then
    err "Could not retrieve function URL. Check the Cloud Console for status."
    exit 1
fi

success "Function URL: $FUNCTION_URL"

# ---------------------------------------------------------------------------
# Print test commands
# ---------------------------------------------------------------------------
echo ""
header "============================================"
header "  Deployment complete!"
header "============================================"
echo ""
info "API URL: ${BOLD}$FUNCTION_URL${RESET}"
echo ""

# Build header flag for curl examples
if [[ -n "$API_KEY" ]]; then
    AUTH_HEADER="-H 'X-API-Key: $API_KEY' "
else
    AUTH_HEADER=""
fi

info "Test endpoints:"
echo ""
echo "  # Health check (no auth required)"
echo "  curl -s \"$FUNCTION_URL?action=health\" | python3 -m json.tool"
echo ""
echo "  # Categories"
echo "  curl -s ${AUTH_HEADER}\"$FUNCTION_URL?action=categories\" | python3 -m json.tool"
echo ""
echo "  # Recent findings (last 7 days, first 5)"
echo "  curl -s ${AUTH_HEADER}\"$FUNCTION_URL?action=findings&days=7&limit=5\" | python3 -m json.tool"
echo ""
echo "  # Findings by category"
echo "  curl -s ${AUTH_HEADER}\"$FUNCTION_URL?action=findings&category=Robotics\" | python3 -m json.tool"
echo ""
echo "  # Findings by exact date"
echo "  curl -s ${AUTH_HEADER}\"$FUNCTION_URL?action=findings&date=2026-04-09\" | python3 -m json.tool"
echo ""
echo "  # Pagination"
echo "  curl -s ${AUTH_HEADER}\"$FUNCTION_URL?action=findings&limit=10&offset=0&sort=desc\" | python3 -m json.tool"
echo ""
echo "  # Stats"
echo "  curl -s ${AUTH_HEADER}\"$FUNCTION_URL?action=stats\" | python3 -m json.tool"
echo ""
echo "  # Cache status"
echo "  curl -s ${AUTH_HEADER}\"$FUNCTION_URL?action=cache_status\" | python3 -m json.tool"
echo ""
echo "  # Force cache refresh"
echo "  curl -s ${AUTH_HEADER}\"$FUNCTION_URL?action=refresh\" | python3 -m json.tool"
echo ""
