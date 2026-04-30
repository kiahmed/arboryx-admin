#!/usr/bin/env bash
# ============================================================================
# dev-utils/list_secrets.sh — inventory Secret Manager secrets
#
# Lists every secret in the configured project, their per-version state, and
# creation / expiry dates. Useful for:
#   - Auditing what's stored in Secret Manager.
#   - Checking soak-window status (which old versions are still enabled).
#   - Seeing whether any secrets have an explicit expireTime set.
#
# About expiry:
#   Secret Manager only enforces an expiry if you set one with --expire-time
#   or --ttl. We don't — we rotate via dev-utils/rotate_key.sh + the quarterly
#   rotator function instead. So "Expires: never" is the expected default
#   for arboryx-* secrets. If you ever see a real timestamp here, that secret
#   has a hard cutoff scheduled.
#
# Usage:
#   bash dev-utils/list_secrets.sh
#   bash dev-utils/list_secrets.sh --json          # machine-readable
#   bash dev-utils/list_secrets.sh --secret <name> # one secret only
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/arboryx_admin_backend.config"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: $CONFIG_FILE not found." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
: "${PROJECT_ID:?PROJECT_ID not set in $CONFIG_FILE}"

# Args
JSON=false
SECRET_FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)   JSON=true; shift ;;
    --secret) SECRET_FILTER="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Collect secret names + per-secret metadata (createTime, expireTime, ttl)
if [[ -n "$SECRET_FILTER" ]]; then
  SECRET_LINES="$(gcloud secrets describe "$SECRET_FILTER" \
    --project="$PROJECT_ID" \
    --format='value(name,createTime,expireTime)' 2>/dev/null || true)"
  if [[ -z "$SECRET_LINES" ]]; then
    echo "ERROR: secret '$SECRET_FILTER' not found in project $PROJECT_ID" >&2
    exit 1
  fi
else
  SECRET_LINES="$(gcloud secrets list \
    --project="$PROJECT_ID" \
    --format='value(name,createTime,expireTime)')"
fi

# Build version data via Python (cleaner than awk for date math + JSON).
# NOTE: heredoc claims stdin, so SECRET_LINES is passed via env var, not pipe.
SECRET_LINES="$SECRET_LINES" python3 - "$PROJECT_ID" "$JSON" <<'PYEOF'
import json, os, re, subprocess, sys
from datetime import datetime, timezone

PROJECT_ID = sys.argv[1]
JSON_OUT = sys.argv[2] == "true"
SECRET_LINES = os.environ.get("SECRET_LINES", "")

# ANSI helpers (TTY only)
TTY = sys.stdout.isatty() and not JSON_OUT
def c(code, s):
    return f"\033[{code}m{s}\033[0m" if TTY else str(s)
HDR    = lambda s: c("1",   s)
OK     = lambda s: c("32",  s)
WARN   = lambda s: c("33",  s)
DIM    = lambda s: c("2",   s)
CYAN   = lambda s: c("36",  s)
ERR    = lambda s: c("31",  s)

STATE_COLOR = {
    "ENABLED":   OK,
    "DISABLED":  WARN,
    "DESTROYED": ERR,
}

def parse_ts(s):
    if not s or s == "-":
        return None
    # gcloud's value() format often strips the timezone — default to UTC.
    s = s.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt

def fmt_dt(dt):
    if dt is None:
        return "-"
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

def age(dt):
    if dt is None:
        return "-"
    delta = datetime.now(timezone.utc) - dt
    days = delta.days
    if days >= 1:
        return f"{days}d"
    hours = delta.seconds // 3600
    if hours >= 1:
        return f"{hours}h"
    return f"{delta.seconds // 60}m"

# Read the secret index (name [tab] createTime [tab] expireTime)
secrets = []
for raw in SECRET_LINES.splitlines():
    parts = raw.split("\t") if "\t" in raw else raw.split()
    if not parts:
        continue
    name = parts[0]
    # `name` field from gcloud uses the bare secret id
    sec = {"name": name.split("/")[-1] if "/" in name else name}
    sec["created"] = parse_ts(parts[1]) if len(parts) > 1 else None
    sec["expires"] = parse_ts(parts[2]) if len(parts) > 2 else None
    secrets.append(sec)

# For each secret, fetch versions
for sec in secrets:
    cmd = ["gcloud", "secrets", "versions", "list", sec["name"],
           "--project", PROJECT_ID,
           "--format", "value(name,state,createTime,destroyTime)"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    versions = []
    for line in out.stdout.splitlines():
        parts = line.split("\t") if "\t" in line else line.split()
        if not parts:
            continue
        ver_path = parts[0]
        ver_num = ver_path.split("/")[-1] if "/" in ver_path else ver_path
        versions.append({
            "version":    ver_num,
            "state":      (parts[1] if len(parts) > 1 else "?").upper(),
            "created":    parse_ts(parts[2]) if len(parts) > 2 else None,
            "destroyed":  parse_ts(parts[3]) if len(parts) > 3 else None,
        })
    sec["versions"] = versions

# --- output ---
if JSON_OUT:
    out = []
    for s in secrets:
        out.append({
            "name":    s["name"],
            "created": s["created"].isoformat() if s["created"] else None,
            "expires": s["expires"].isoformat() if s["expires"] else None,
            "versions": [
                {
                    "version":    v["version"],
                    "state":      v["state"],
                    "created":    v["created"].isoformat() if v["created"] else None,
                    "destroyed":  v["destroyed"].isoformat() if v["destroyed"] else None,
                    "age":        age(v["created"]),
                } for v in s["versions"]
            ],
        })
    print(json.dumps(out, indent=2))
    sys.exit(0)

# Pretty table
print()
print(HDR(f"  Secret Manager — project: {PROJECT_ID}"))
print(HDR("  " + "=" * 60))
if not secrets:
    print(WARN("  (no secrets found)"))
    sys.exit(0)

for s in secrets:
    print()
    print(CYAN(f"  ▎ {s['name']}"))
    print(f"    Secret created : {fmt_dt(s['created'])}  ({DIM(age(s['created']) + ' ago')})")
    expires_str = fmt_dt(s['expires']) if s['expires'] else DIM("never")
    print(f"    Expiry         : {expires_str}")
    if not s["versions"]:
        print(DIM("    (no versions)"))
        continue
    print(f"    Versions ({len(s['versions'])}):")
    # Pad BEFORE applying ANSI so visible-width alignment is correct.
    print(f"      {DIM('ver'):<3}  {DIM('state'):<10}  {DIM('created'):<22}  {DIM('age')}")
    for v in s["versions"]:
        state_fn = STATE_COLOR.get(v["state"], lambda x: x)
        state_str = state_fn(f"{v['state']:<10}")
        print(f"      {v['version']:<3}  {state_str}  {fmt_dt(v['created']):<22}  {age(v['created'])}")

# Summary footer
total_versions = sum(len(s["versions"]) for s in secrets)
enabled = sum(1 for s in secrets for v in s["versions"] if v["state"] == "ENABLED")
disabled = sum(1 for s in secrets for v in s["versions"] if v["state"] == "DISABLED")
destroyed = sum(1 for s in secrets for v in s["versions"] if v["state"] == "DESTROYED")
print()
print(HDR("  " + "=" * 60))
print(f"  {len(secrets)} secret(s) • {total_versions} version(s) total")
print(f"    {OK(f'{enabled} enabled')} • {WARN(f'{disabled} disabled')} • {ERR(f'{destroyed} destroyed')}")
print()
PYEOF
