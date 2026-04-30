#!/usr/bin/env bash
# ============================================================================
# firestore/make_firestore_pipeline_ready.sh — one-time Firestore bootstrap
#
# Idempotent. Safe to re-run. Brings the project's Firestore database into
# the state the Arboryx data layer expects:
#
#   1. Enables the Firestore API (firestore.googleapis.com).
#   2. Creates the (default) Firestore database in Native mode at LOCATION
#      from arboryx_admin_backend.config — only if it doesn't already exist.
#   3. Deploys the security rules in firestore.rules.
#   4. Deploys the composite indexes in firestore.indexes.json.
#   5. Grants the API service account roles/datastore.user on the project
#      so the Cloud Function can read/write Firestore (Phase 2.1+).
#
# What this script does NOT do:
#   - Migrate data from GCS JSON  (run dev-utils/sync_gcs_to_firestore.py)
#   - Switch the API to read from Firestore  (env-flag flip in PR 2)
#
# Prerequisites:
#   - gcloud authenticated as a project owner / editor (gcloud auth list)
#   - arboryx_admin_backend.config populated with PROJECT_ID, LOCATION,
#     SA_EMAIL.
#
# Usage:
#   bash firestore/make_firestore_pipeline_ready.sh
#   bash firestore/make_firestore_pipeline_ready.sh --dry-run
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/arboryx_admin_backend.config"
INDEXES_FILE="$SCRIPT_DIR/firestore.indexes.json"
RULES_FILE="$SCRIPT_DIR/firestore.rules"

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
  err "Copy from .example, populate PROJECT_ID/LOCATION/SA_EMAIL, then re-run."
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${PROJECT_ID:?PROJECT_ID not set in config}"
: "${LOCATION:?LOCATION not set in config}"
: "${SA_EMAIL:?SA_EMAIL not set in config}"

header "============================================"
header "  Firestore — One-Time Pipeline Bootstrap"
header "============================================"
info "Project   : $PROJECT_ID"
info "Location  : $LOCATION"
info "API SA    : $SA_EMAIL"
info "Indexes   : $INDEXES_FILE"
info "Rules     : $RULES_FILE"
$DRY_RUN && warn "DRY RUN — no mutations will be applied."
echo

# ---------------------------------------------------------------------------
# 1. Enable Firestore API
# ---------------------------------------------------------------------------
header "--- 1/5 Enable firestore.googleapis.com ---"
if gcloud services list --enabled --project="$PROJECT_ID" \
     --filter="config.name=firestore.googleapis.com" --format="value(name)" \
     | grep -q firestore; then
  ok "firestore.googleapis.com already enabled."
else
  if $DRY_RUN; then
    info "[dry-run] would: gcloud services enable firestore.googleapis.com"
  else
    gcloud services enable firestore.googleapis.com --project="$PROJECT_ID"
    ok "Enabled firestore.googleapis.com"
  fi
fi
echo

# ---------------------------------------------------------------------------
# 2. Create Firestore database (Native mode) — once per project
# ---------------------------------------------------------------------------
header "--- 2/5 Create Firestore database (Native mode) ---"
# `(default)` is the canonical database id; we use it (single-DB project).
if gcloud firestore databases describe --database="(default)" \
     --project="$PROJECT_ID" >/dev/null 2>&1; then
  ok "Firestore database '(default)' already exists."
else
  if $DRY_RUN; then
    info "[dry-run] would: gcloud firestore databases create --location=$LOCATION --type=firestore-native"
  else
    gcloud firestore databases create \
      --location="$LOCATION" \
      --type=firestore-native \
      --project="$PROJECT_ID"
    ok "Created Firestore database in $LOCATION (Native mode)."
  fi
fi
echo

# ---------------------------------------------------------------------------
# 3. Deploy security rules
# ---------------------------------------------------------------------------
header "--- 3/5 Deploy security rules ---"
if [[ ! -f "$RULES_FILE" ]]; then
  err "Rules file missing: $RULES_FILE"
  exit 1
fi
if $DRY_RUN; then
  info "[dry-run] would: gcloud firestore security-rules update '$RULES_FILE'"
else
  # `gcloud firestore` does not currently support rule deploys directly;
  # use the firebase CLI if available, otherwise instruct the user.
  if command -v firebase >/dev/null 2>&1; then
    (cd "$SCRIPT_DIR" && firebase deploy --only firestore:rules \
      --project "$PROJECT_ID" --non-interactive)
    ok "Deployed firestore.rules via firebase CLI."
  else
    warn "firebase CLI not installed — rules NOT auto-deployed."
    warn "Install with:  npm install -g firebase-tools"
    warn "Then run:      firebase deploy --only firestore:rules --project $PROJECT_ID"
    warn "Or paste $RULES_FILE into:"
    warn "  https://console.cloud.google.com/firestore/databases/-default-/rules?project=$PROJECT_ID"
  fi
fi
echo

# ---------------------------------------------------------------------------
# 4. Deploy composite indexes
# ---------------------------------------------------------------------------
header "--- 4/5 Deploy composite indexes ---"
if [[ ! -f "$INDEXES_FILE" ]]; then
  err "Indexes file missing: $INDEXES_FILE"
  exit 1
fi
# Each index is created via gcloud (idempotent — re-creating an existing
# index is a no-op). Parse the JSON and emit one create call per entry.
python3 - "$INDEXES_FILE" "$PROJECT_ID" "$DRY_RUN" <<'PYEOF'
import json, subprocess, sys
indexes_file, project_id, dry_run = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
with open(indexes_file) as f:
    spec = json.load(f)
for idx in spec.get("indexes", []):
    coll = idx["collectionGroup"]
    fields = idx["fields"]
    # --async: submit the create operation and return immediately. Without
    # this, gcloud blocks until the index finishes building (minutes).
    args = ["gcloud", "firestore", "indexes", "composite", "create",
            f"--collection-group={coll}",
            f"--query-scope={idx.get('queryScope', 'COLLECTION')}",
            f"--project={project_id}",
            "--async"]
    for f in fields:
        path = f["fieldPath"]
        order = f.get("order", "ASCENDING").lower()
        args.append(f"--field-config=field-path={path},order={order}")
    label = " + ".join(f'{f["fieldPath"]}({f.get("order","ASC")[:3]})' for f in fields)
    print(f"  index: {coll} — {label}")
    if dry_run:
        print(f"  [dry-run] {' '.join(args)}")
        continue
    res = subprocess.run(args, capture_output=True, text=True, timeout=60)
    combined = (res.stderr + res.stdout).lower()
    if res.returncode == 0:
        print(f"  [ok] submitted (build runs in background).")
    elif "already exists" in combined:
        print(f"  [ok] already exists.")
    else:
        print(f"  [err] {res.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
PYEOF
ok "Index submissions complete. Builds run async — track progress at:"
ok "  https://console.cloud.google.com/firestore/databases/-default-/indexes?project=$PROJECT_ID"
echo

# ---------------------------------------------------------------------------
# 5. Grant API service account Firestore access
# ---------------------------------------------------------------------------
header "--- 5/5 Grant $SA_EMAIL roles/datastore.user ---"
# `roles/datastore.user` covers Firestore reads + writes via the Datastore
# legacy role surface, which Firestore Native still honors. This is the
# minimum role for an app-level read/write workload.
if $DRY_RUN; then
  info "[dry-run] would: gcloud projects add-iam-policy-binding $PROJECT_ID \\"
  info "                   --member=serviceAccount:$SA_EMAIL --role=roles/datastore.user"
else
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="roles/datastore.user" \
    --condition=None >/dev/null
  ok "Granted roles/datastore.user to $SA_EMAIL."
fi
echo

header "============================================"
ok "Firestore pipeline ready."
header "============================================"
info "Next:"
info "  1. Verify in console: https://console.cloud.google.com/firestore?project=$PROJECT_ID"
info "  2. Backfill data:     python3 dev-utils/sync_gcs_to_firestore.py --dry-run"
info "                        python3 dev-utils/sync_gcs_to_firestore.py"
info "  3. Cut over the API:  (Phase 2.1 PR 2 — env flag FINDINGS_BACKEND=firestore)"
