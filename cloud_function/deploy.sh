#!/bin/bash
# cloud_function/deploy.sh
# Unified deploy script for the Arboryx Admin API backend.
#
# Behaviour:
#   - If the Cloud Function already exists  -> source-only update + env var sync
#   - If it does not exist                  -> full fresh deploy with IAM
#
# Flags:
#   --full      Force a full redeploy even if the function already exists
#   --dry-run   Show what would happen without executing any gcloud commands
#
# Usage (from repo root):
#   bash cloud_function/deploy.sh
#   bash cloud_function/deploy.sh --full
#   bash cloud_function/deploy.sh --dry-run
#   bash cloud_function/deploy.sh --full --dry-run
#   API_KEY=mykey bash cloud_function/deploy.sh

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
            echo "Usage: bash cloud_function/deploy.sh [--full] [--dry-run]"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/arboryx_admin_backend.config"

if [[ ! -f "$CONFIG_FILE" ]]; then
    err "Config file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"
FUNCTION_DIR="$SCRIPT_DIR"

if [[ ! -f "$FUNCTION_DIR/main.py" ]]; then
    err "Cloud Function source not found at: $FUNCTION_DIR/main.py"
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve API key (env var overrides config)
# ---------------------------------------------------------------------------
API_KEY="${API_KEY:-}"

if [[ -z "$API_KEY" ]]; then
    warn "API_KEY is not set. The function will deploy without authentication."
    warn "Set API_KEY in arboryx_admin_backend.config or pass via: API_KEY=<key> bash cloud_function/deploy.sh"
    echo ""
    read -rp "Continue without API key? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "Aborting. Set API_KEY and re-run."
        exit 0
    fi
fi

CACHE_TTL_SECONDS="${CACHE_TTL_SECONDS:-300}"
READ_ONLY_API_KEYS="${READ_ONLY_API_KEYS:-}"
# Track B Phase 2.1: read backend selector.
# Source-of-truth is FINDINGS_BACKEND in arboryx_admin_backend.config (sourced
# above). Shell env overrides for one-off testing. Defaults to "gcs" if neither
# the config nor the shell sets it, preserving legacy behavior.
FINDINGS_BACKEND="${FINDINGS_BACKEND:-gcs}"

# ---------------------------------------------------------------------------
# Build env vars string
# ---------------------------------------------------------------------------
ENV_VARS="PROJECT_ID=$PROJECT_ID"
ENV_VARS+=",STORAGE_BUCKET=$STORAGE_BUCKET"
ENV_VARS+=",DATA_BLOB=market_findings_log.json"
ENV_VARS+=",CACHE_TTL_SECONDS=$CACHE_TTL_SECONDS"
ENV_VARS+=",FINDINGS_BACKEND=$FINDINGS_BACKEND"
if [[ -n "$API_KEY" ]]; then
    ENV_VARS+=",API_KEY=$API_KEY"
fi
if [[ -n "$READ_ONLY_API_KEYS" ]]; then
    ENV_VARS+=",READ_ONLY_API_KEYS=$READ_ONLY_API_KEYS"
fi
# Track A Phase 1: CORS origin allowlist override (empty = use compiled-in default)
if [[ -n "${ALLOWED_ORIGINS:-}" ]]; then
    ENV_VARS+=",ALLOWED_ORIGINS=$ALLOWED_ORIGINS"
fi

# ---------------------------------------------------------------------------
# Check if function already exists
# ---------------------------------------------------------------------------
header "============================================"
header "  Arboryx Admin API — Deploy"
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
info "Backend     : ${BOLD}${FINDINGS_BACKEND}${RESET}"
info "API key     : $(if [[ -n "$API_KEY" ]]; then echo 'SET'; else echo 'NOT SET (open access)'; fi)"
info "Read-only   : $(if [[ -n "$READ_ONLY_API_KEYS" ]]; then echo "SET ($(echo "$READ_ONLY_API_KEYS" | tr ',' '\n' | wc -l | tr -d ' ') key(s))"; else echo 'NOT SET'; fi)"
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
        echo "      --max-instances=${FUNCTION_MAX_INSTANCES:-5} \\"
        echo "      --set-env-vars=\"$ENV_VARS\" \\"
        echo "      --service-account=$SA_EMAIL \\"
        echo "      --project=$PROJECT_ID \\"
        echo "      --allow-unauthenticated"
    else
        info "Would run: gcloud functions deploy $FUNCTION_NAME \\"
        echo "      --gen2 \\"
        echo "      --region=$LOCATION \\"
        echo "      --source=$FUNCTION_DIR \\"
        echo "      --max-instances=${FUNCTION_MAX_INSTANCES:-5} \\"
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
        --max-instances="${FUNCTION_MAX_INSTANCES:-5}" \
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
        --max-instances="${FUNCTION_MAX_INSTANCES:-5}" \
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
