#!/usr/bin/env bash
# ============================================================================
# manage_admin_users.sh — CRUD for the Arboryx Admin UI sign-in credentials.
#
# The admin UI (arborist_*.html) no longer embeds an API key. Operators sign in
# with a username + password; the Cloud Function verifies them and mints a
# session token. Credentials are a JSON object {username: password} stored in
# Secret Manager secret `arboryx-admin-users`. The function reads the LATEST
# enabled version on each sign-in.
#
# TRADEOFF (by design): passwords are stored as PLAINTEXT inside Secret Manager
# (encrypted at rest, IAM-gated) — not as one-way hashes — so this script can
# hand the human-readable password back to you via `list` / `get`. If you never
# need to retrieve a password, switch to hashes; but retrieval was the explicit
# requirement here.
#
# There is NO sign-up path anywhere. Accounts exist only because this script
# created them. Intended for a single operator (default user: kazi-admin).
#
# Usage:
#   bash dev-utils/manage_admin_users.sh create [username]    # gen strong pw, add user
#   bash dev-utils/manage_admin_users.sh rotate [username]    # regen pw for existing user
#   bash dev-utils/manage_admin_users.sh set <username> <pw>  # set an explicit password
#   bash dev-utils/manage_admin_users.sh list                 # all users + passwords
#   bash dev-utils/manage_admin_users.sh get <username>       # one user's password
#   bash dev-utils/manage_admin_users.sh --username <name>    # alias for `get <name>`
#   bash dev-utils/manage_admin_users.sh delete <username>
#
# Default username when omitted: kazi-admin
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

command -v jq      >/dev/null || { err "jq is required."; exit 1; }
command -v gcloud  >/dev/null || { err "gcloud is required."; exit 1; }
command -v python3 >/dev/null || { err "python3 is required."; exit 1; }

DEFAULT_USER="kazi-admin"
SECRET_NAME="arboryx-admin-users"

CONFIG_FILE="$REPO_ROOT/arboryx_admin_backend.config"
[[ -f "$CONFIG_FILE" ]] || { err "$CONFIG_FILE not found — copy from .example and populate."; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"
: "${PROJECT_ID:?PROJECT_ID not set in $CONFIG_FILE}"

# --- helpers ---------------------------------------------------------------
gen_password() {
  # 22 chars from an UNAMBIGUOUS alphabet (no 0/O/1/l/I) plus a few safe
  # symbols — ~128 bits of entropy, still copy/read-able by a human.
  python3 - <<'PY'
import secrets
alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#%^*-_=+"
print("".join(secrets.choice(alphabet) for _ in range(22)))
PY
}

secret_exists() {
  gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" >/dev/null 2>&1
}

ensure_secret() {
  if ! secret_exists; then
    info "Secret '$SECRET_NAME' does not exist — creating it."
    gcloud secrets create "$SECRET_NAME" \
      --replication-policy="automatic" \
      --project="$PROJECT_ID" >/dev/null
    ok "Created secret '$SECRET_NAME'."
  fi
}

read_users() {
  # Emit the current user map as JSON. '{}' if the secret/version is missing
  # or the payload isn't valid JSON.
  local raw
  if ! secret_exists; then echo '{}'; return; fi
  raw="$(gcloud secrets versions access latest --secret="$SECRET_NAME" --project="$PROJECT_ID" 2>/dev/null || echo '')"
  if [[ -z "$raw" ]] || ! echo "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo '{}'
  else
    echo "$raw"
  fi
}

write_users() {
  # $1 = compact JSON object. Adds a new ENABLED version.
  local json="$1"
  echo "$json" | jq -e 'type == "object"' >/dev/null 2>&1 || { err "Refusing to write non-object JSON."; exit 1; }
  ensure_secret
  local ver
  ver="$(printf '%s' "$json" | gcloud secrets versions add "$SECRET_NAME" \
      --data-file=- --project="$PROJECT_ID" --format='value(name)')"
  info "Wrote secret version: ${ver##*/}"
}

# --- arg parsing -----------------------------------------------------------
CMD="${1:-}"
if [[ "$CMD" == "--username" ]]; then
  CMD="get"; set -- get "${2:-}"
fi
ARG_USER="${2:-}"
ARG_PW="${3:-}"

header "============================================"
header "  Arboryx Admin — User Management"
header "============================================"
info "Project : $PROJECT_ID"
info "Secret  : $SECRET_NAME"
echo

case "$CMD" in
  create)
    USER="${ARG_USER:-$DEFAULT_USER}"
    users="$(read_users)"
    if echo "$users" | jq -e --arg u "$USER" 'has($u)' >/dev/null; then
      err "User '$USER' already exists. Use 'rotate' to change the password."
      exit 1
    fi
    PW="$(gen_password)"
    users="$(echo "$users" | jq --arg u "$USER" --arg p "$PW" '.[$u]=$p')"
    write_users "$users"
    ok "Created user '$USER'."
    echo
    header "  username : $USER"
    header "  password : $PW"
    echo
    warn "Store this now — you can re-read it any time with:"
    info "  bash dev-utils/manage_admin_users.sh get $USER"
    ;;

  rotate)
    USER="${ARG_USER:-$DEFAULT_USER}"
    users="$(read_users)"
    echo "$users" | jq -e --arg u "$USER" 'has($u)' >/dev/null || { err "User '$USER' not found. Use 'create'."; exit 1; }
    PW="$(gen_password)"
    users="$(echo "$users" | jq --arg u "$USER" --arg p "$PW" '.[$u]=$p')"
    write_users "$users"
    ok "Rotated password for '$USER'."
    echo
    header "  username : $USER"
    header "  password : $PW"
    ;;

  set)
    USER="${ARG_USER:-}"
    [[ -n "$USER" && -n "$ARG_PW" ]] || { err "Usage: set <username> <password>"; exit 1; }
    users="$(read_users)"
    users="$(echo "$users" | jq --arg u "$USER" --arg p "$ARG_PW" '.[$u]=$p')"
    write_users "$users"
    ok "Set password for '$USER'."
    ;;

  list)
    users="$(read_users)"
    n="$(echo "$users" | jq 'length')"
    if [[ "$n" == "0" ]]; then
      warn "No users defined yet. Create one:"
      info "  bash dev-utils/manage_admin_users.sh create"
      exit 0
    fi
    header "  USERNAME                    PASSWORD"
    header "  --------                    --------"
    echo "$users" | jq -r 'to_entries[] | "  \(.key)	\(.value)"' \
      | awk -F'\t' '{ printf "  %-26s  %s\n", $1, $2 }'
    ;;

  get)
    USER="${ARG_USER:-}"
    [[ -n "$USER" ]] || { err "Usage: get <username>"; exit 1; }
    users="$(read_users)"
    pw="$(echo "$users" | jq -r --arg u "$USER" '.[$u] // empty')"
    [[ -n "$pw" ]] || { err "User '$USER' not found."; exit 1; }
    header "  username : $USER"
    header "  password : $pw"
    ;;

  delete)
    USER="${ARG_USER:-}"
    [[ -n "$USER" ]] || { err "Usage: delete <username>"; exit 1; }
    users="$(read_users)"
    echo "$users" | jq -e --arg u "$USER" 'has($u)' >/dev/null || { err "User '$USER' not found."; exit 1; }
    users="$(echo "$users" | jq --arg u "$USER" 'del(.[$u])')"
    write_users "$users"
    ok "Deleted user '$USER'. Their active session (if any) is NOT revoked — sign them out via the UI or let it expire."
    ;;

  ""|-h|--help)
    sed -n '2,40p' "$0"
    ;;

  *)
    err "Unknown command: $CMD"
    sed -n '30,40p' "$0"
    exit 1
    ;;
esac
