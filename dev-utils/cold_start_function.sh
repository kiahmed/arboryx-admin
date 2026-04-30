#!/usr/bin/env bash
# ============================================================================
# cold_start_function.sh — force a 2nd-gen Cloud Function to recycle warm
# instances so newly-rotated / newly-disabled Secret Manager versions take
# effect immediately.
#
# Why this exists
# ---------------
# Cloud Function instances load Secret Manager values at COLD START only
# (see cloud_function/main.py:_build_valid_keys, called once at module
# import). When you disable an old key version in Secret Manager:
#
#   * NEW cold-started instances will not pick it up. ✓ good
#   * WARM instances keep the previously-loaded key set in `_VALID_KEYS`
#     until they're recycled by Cloud Functions itself. ✗ bad
#
# That second case is a stealth-leak window: a key you just "killed" is
# actually still accepted by warm instances for minutes-to-hours. After a
# leak-driven rotation you cannot tolerate that window.
#
# How it works
# ------------
# Updating ANY env var on a 2nd-gen function ships a new revision, which
# means EVERY existing instance is replaced with a fresh cold-start. We
# bump a no-op env var (`_REDEPLOY=<unix-timestamp>`) so the redeploy is
# purely instance-recycling — source code, real env, and IAM are unchanged.
#
# When to run
# -----------
#   * Right after `dev-utils/rotate_key.sh <kind> --finalize <ver>` so the
#     disabled version actually stops being accepted in the wild.
#   * After any out-of-band Secret Manager change (gcloud secrets versions
#     disable / destroy run by hand, IAM policy changes on a secret, etc.).
#   * When you suspect a warm instance is serving with a stale key set.
#
# What this is NOT
# ----------------
#   * A code or config deploy — use cloud_function/deploy.sh for that.
#   * A way to hot-reload code without bumping a revision; you can't.
#
# Usage
# -----
#   bash dev-utils/cold_start_function.sh                              # admin API (default from config)
#   bash dev-utils/cold_start_function.sh arboryx-key-rotator          # rotator function
#   bash dev-utils/cold_start_function.sh arboryx-rotation-reminder    # reminder function
#   bash dev-utils/cold_start_function.sh <name> --source-dir=PATH     # custom function (unknown name)
#   bash dev-utils/cold_start_function.sh --dry-run                    # show the command, run nothing
#
# Why --source-dir is needed
# --------------------------
# `gcloud functions deploy` always uploads source on every invocation, even
# when the only diff is an env var. So we must point at the function's
# source directory. For the 3 functions in this repo we know the mapping:
#
#     arboryx-admin-api          -> cloud_function/
#     arboryx-key-rotator        -> cloud_function_rotator/
#     arboryx-rotation-reminder  -> cloud_function_reminder/
#
# For anything else, pass --source-dir=/abs/path or run from that function's
# own deploy.sh which knows where its source lives.
#
# Exit codes
# ----------
#   0  redeploy succeeded (or dry-run printed the plan)
#   1  config / arg / gcloud error
#   2  function not found in the configured region
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

# ---------------------------------------------------------------------------
# Arg parsing — positional function name (optional) + --dry-run flag
# ---------------------------------------------------------------------------
DRY_RUN=false
TARGET_FUNCTION=""
SOURCE_DIR_OVERRIDE=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --source-dir=*) SOURCE_DIR_OVERRIDE="${arg#--source-dir=}" ;;
    -h|--help) sed -n '2,68p' "$0"; exit 0 ;;
    --*) err "Unknown flag: $arg"; exit 1 ;;
    *)
      if [[ -n "$TARGET_FUNCTION" ]]; then
        err "Only one function name accepted (got '$TARGET_FUNCTION' and '$arg')"
        exit 1
      fi
      TARGET_FUNCTION="$arg"
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Load PROJECT_ID + LOCATION + default FUNCTION_NAME from backend config
# ---------------------------------------------------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
  err "Config not found: $CONFIG_FILE"
  err "Copy from .example, populate PROJECT_ID/LOCATION/FUNCTION_NAME, then re-run."
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
: "${PROJECT_ID:?PROJECT_ID not set in $CONFIG_FILE}"
: "${LOCATION:?LOCATION not set in $CONFIG_FILE}"
: "${FUNCTION_NAME:?FUNCTION_NAME not set in $CONFIG_FILE}"

# Default: the admin API function defined in config. Override via positional.
TARGET_FUNCTION="${TARGET_FUNCTION:-$FUNCTION_NAME}"

# ---------------------------------------------------------------------------
# Resolve source directory.
#   * Known function names auto-map to their checked-in source dir.
#   * Anything else needs --source-dir=PATH explicitly. We don't try to
#     guess — silently shipping the wrong source would replace the function
#     with bytes from an unrelated dir.
# ---------------------------------------------------------------------------
if [[ -n "$SOURCE_DIR_OVERRIDE" ]]; then
  SOURCE_DIR="$SOURCE_DIR_OVERRIDE"
else
  case "$TARGET_FUNCTION" in
    arboryx-admin-api)         SOURCE_DIR="$REPO_ROOT/cloud_function" ;;
    arboryx-key-rotator)       SOURCE_DIR="$REPO_ROOT/cloud_function_rotator" ;;
    arboryx-rotation-reminder) SOURCE_DIR="$REPO_ROOT/cloud_function_reminder" ;;
    *)
      err "Unknown function '$TARGET_FUNCTION' — no source-dir mapping."
      err "Pass --source-dir=/abs/path/to/dir, or invoke that function's own deploy.sh."
      exit 1
      ;;
  esac
fi

if [[ ! -f "$SOURCE_DIR/main.py" ]]; then
  err "Resolved source dir '$SOURCE_DIR' has no main.py."
  err "gcloud will reject the deploy. Check --source-dir or function name."
  exit 1
fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
TIMESTAMP="$(date +%s)"

header "============================================"
header "  Cloud Function — Force Cold Start"
header "============================================"
info "Function    : $TARGET_FUNCTION"
info "Source dir  : $SOURCE_DIR"
info "Region      : $LOCATION"
info "Project     : $PROJECT_ID"
info "Bump value  : _REDEPLOY=$TIMESTAMP   (no-op env var, purely a cache-buster)"
$DRY_RUN && warn "DRY RUN — gcloud will not be invoked."
echo

# ---------------------------------------------------------------------------
# Sanity check: function must exist in the configured region
# ---------------------------------------------------------------------------
if ! $DRY_RUN; then
  info "Verifying $TARGET_FUNCTION exists in $LOCATION..."
  if ! gcloud functions describe "$TARGET_FUNCTION" \
       --gen2 --region="$LOCATION" --project="$PROJECT_ID" \
       --format="value(name)" >/dev/null 2>&1; then
    err "Function '$TARGET_FUNCTION' not found in $LOCATION (project $PROJECT_ID)."
    err "List with: gcloud functions list --gen2 --regions=$LOCATION --project=$PROJECT_ID"
    exit 2
  fi
  ok "Function found."
  echo
fi

# ---------------------------------------------------------------------------
# Bump the no-op env var. This re-deploys, which recycles every instance.
# Note: --update-env-vars MERGES (does not replace) — existing env vars are
# preserved. That's why we don't have to re-pass PROJECT_ID, API_KEY, etc.
# ---------------------------------------------------------------------------
CMD=(
  gcloud functions deploy "$TARGET_FUNCTION"
  --gen2
  --region="$LOCATION"
  --project="$PROJECT_ID"
  --source="$SOURCE_DIR"
  "--update-env-vars=_REDEPLOY=$TIMESTAMP"
)

info "Will run:"
echo "  ${CMD[*]}"
echo

if $DRY_RUN; then
  warn "Dry run — exiting without invoking gcloud."
  exit 0
fi

info "Triggering redeploy (this takes ~30-60s)..."
"${CMD[@]}"
echo
ok "Cold-start fired. Every $TARGET_FUNCTION instance has been recycled."
info "Next request will load Secret Manager versions fresh, picking up any"
info "rotations / disables that landed before this command ran."
