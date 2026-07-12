#!/usr/bin/env bash
# ============================================================================
# frontend/cloudflare/deploy.sh — provision arboryx.ai (apex) → gs://arboryx.ai/
# ----------------------------------------------------------------------------
# Architecture
# ------------
# Standard "host a static site from GCS on a custom domain" pattern:
#
#   Browser ──https──> Cloudflare (proxy + TLS) ──http──> c.storage.googleapis.com
#                              │                                  │
#                              └─── Host: arboryx.ai ─────────────┘
#                                                                 │
#                                                          Bucket name == Host
#                                                                 │
#                                                       gs://arboryx.ai/...
#
# Bucket is name-matched to the domain because GCS dispatches by Host header
# when reached via c.storage.googleapis.com. The bucket holds ONLY the
# frontend, so making it public is safe — private data lives in the
# unrelated `marketresearch-agents` bucket.
#
# Stages (idempotent; the script auto-detects what's left to do)
# ---------------------------------------------------------------
#   1. Verify CF token + gcloud auth + active account
#   2. Domain ownership: add google-site-verification TXT, prompt for
#      Search Console click, exit so user can flip it
#   3. Create + configure bucket (website main/404 + bucket-wide
#      `allUsers:objectViewer`)
#   4. Sync frontend tree -> gs://arboryx.ai/
#   5. DNS cutover: replace apex A 192.0.2.1 with CNAME -> c.storage.googleapis.com
#   6. Live verify: curl https://arboryx.ai/
#
# Re-running the script is safe — every step short-circuits if the desired
# state is already in place. The only stage that asks for input is #2.
#
# Usage
# -----
#   bash frontend/cloudflare/deploy.sh                # do everything possible
#   bash frontend/cloudflare/deploy.sh --dry-run      # show plan, write nothing
#   bash frontend/cloudflare/deploy.sh --skip-sync    # provision only, no rsync
#   bash frontend/cloudflare/deploy.sh --skip-dns     # everything but DNS cutover
#   bash frontend/cloudflare/deploy.sh --skip-verify  # skip TXT prompt — use when
#                                                     # Search Console auto-verified
#                                                     # the domain (no TXT shown)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$FRONTEND_DIR/.." && pwd)"
CONFIG_FILE="$FRONTEND_DIR/cloudflare.config"

# ---------------------------------------------------------------------------
# Colours / loggers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_HDR=$'\033[1m'; C_OK=$'\033[0;32m'; C_INFO=$'\033[0;36m'
  C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_HDR=''; C_OK=''; C_INFO=''; C_WARN=''; C_ERR=''; C_DIM=''; C_OFF=''
fi
header() { echo; echo -e "${C_HDR}$*${C_OFF}"; }
ok()     { echo -e "${C_OK}[OK]${C_OFF}    $*"; }
info()   { echo -e "${C_INFO}[INFO]${C_OFF}  $*"; }
warn()   { echo -e "${C_WARN}[WARN]${C_OFF}  $*"; }
err()    { echo -e "${C_ERR}[ERR]${C_OFF}   $*" >&2; }
dim()    { echo -e "${C_DIM}$*${C_OFF}"; }

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
DRY_RUN=false
SKIP_SYNC=false
SKIP_DNS=false
SKIP_VERIFY=false
for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY_RUN=true ;;
    --skip-sync)   SKIP_SYNC=true ;;
    --skip-dns)    SKIP_DNS=true ;;
    --skip-verify) SKIP_VERIFY=true ;;
    -h|--help)     sed -n '2,42p' "$0"; exit 0 ;;
    *)             err "Unknown flag: $arg"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
  err "Config not found: $CONFIG_FILE"
  err "Copy from cloudflare.config.example and populate."
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN missing in $CONFIG_FILE}"
: "${CLOUDFLARE_ZONE_ID:?CLOUDFLARE_ZONE_ID missing in $CONFIG_FILE}"
: "${CLOUDFLARE_ZONE_NAME:?CLOUDFLARE_ZONE_NAME missing in $CONFIG_FILE}"
: "${GCP_PROJECT_ID:?GCP_PROJECT_ID missing in $CONFIG_FILE}"
: "${GCS_BUCKET_NAME:?GCS_BUCKET_NAME missing in $CONFIG_FILE}"
: "${SITE_INDEX:=index.html}"
: "${SITE_404:=404.html}"
: "${GCS_BUCKET_LOCATION:=US}"
: "${DOMAIN_OWNER_ACCOUNT:=}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
cf_get()    { curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4$1"; }
cf_post()   { curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" -X POST    "https://api.cloudflare.com/client/v4$1" --data "$2"; }
cf_patch()  { curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" -X PATCH   "https://api.cloudflare.com/client/v4$1" --data "$2"; }
cf_delete() { curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -X DELETE "https://api.cloudflare.com/client/v4$1"; }

bucket_exists() {
  gcloud storage buckets describe "gs://$GCS_BUCKET_NAME" --project="$GCP_PROJECT_ID" --format='value(name)' >/dev/null 2>&1
}

# Banner
header "============================================"
header "  Arboryx — Cloudflare + GCS apex deploy"
header "============================================"
info "Zone        : $CLOUDFLARE_ZONE_NAME (id $CLOUDFLARE_ZONE_ID)"
info "Bucket      : gs://$GCS_BUCKET_NAME (project $GCP_PROJECT_ID)"
info "Frontend src: $FRONTEND_DIR"
$DRY_RUN && warn "DRY RUN — no writes will be made."

# ===========================================================================
# Stage 1 — preconditions
# ===========================================================================
header "Stage 1 — preconditions"

# CF token
if ! cf_get /user/tokens/verify >/dev/null; then
  err "CF API token rejected. Check CLOUDFLARE_API_TOKEN."
  exit 1
fi
ok "CF token active."

# gcloud authed
if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q .; then
  err "No active gcloud account. Run: gcloud auth login"
  exit 1
fi
ACTIVE_ACCT=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -n1)
ok "gcloud active: $ACTIVE_ACCT"

# Bucket-create needs a domain owner. If the active account is an SA and the
# bucket doesn't exist yet, we'll explicitly use $DOMAIN_OWNER_ACCOUNT for
# *only* the create command (it must be authed via `gcloud auth login` already).
if ! bucket_exists; then
  if [[ -n "$DOMAIN_OWNER_ACCOUNT" ]]; then
    if ! gcloud auth list --format='value(account)' | grep -qx "$DOMAIN_OWNER_ACCOUNT"; then
      err "DOMAIN_OWNER_ACCOUNT='$DOMAIN_OWNER_ACCOUNT' is not in gcloud's"
      err "credential cache. Run: gcloud auth login $DOMAIN_OWNER_ACCOUNT"
      exit 1
    fi
    info "Bucket-create will run as: $DOMAIN_OWNER_ACCOUNT (one-time, domain-owner check)"
    info "Everything else runs as : $ACTIVE_ACCT"
  elif [[ "$ACTIVE_ACCT" == *.iam.gserviceaccount.com ]]; then
    err "Bucket gs://$GCS_BUCKET_NAME does not exist and no DOMAIN_OWNER_ACCOUNT"
    err "is set in $CONFIG_FILE. Set it to a Search-Console-verified user account."
    exit 1
  fi
fi

# ===========================================================================
# Stage 2 — domain ownership
# ===========================================================================
header "Stage 2 — domain ownership verification"

if bucket_exists; then
  ok "Bucket already exists; ownership was verified previously. Skipping."
elif $SKIP_VERIFY; then
  ok "Skipping TXT step (--skip-verify). Assuming Search Console auto-verified."
else
  # Look for an existing google-site-verification TXT on the apex.
  EXISTING_TXT=$(cf_get "/zones/$CLOUDFLARE_ZONE_ID/dns_records?type=TXT&name=$CLOUDFLARE_ZONE_NAME" \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('result', []):
    if r['content'].startswith('\"google-site-verification=') or r['content'].startswith('google-site-verification='):
        print(r['content'])
        break
")

  if [[ -n "$EXISTING_TXT" ]]; then
    ok "google-site-verification TXT already in place:"
    dim "    $EXISTING_TXT"
    info "If you've already clicked 'Verify' in Search Console, the next"
    info "stage will create the bucket and continue."
    info "If you haven't, click Verify now, then re-run this script."
    echo
  else
    cat <<EOM

  ${C_HDR}>>> ACTION REQUIRED — open Google Search Console <<<${C_OFF}

  1. Go to: https://search.google.com/search-console/welcome
  2. Add property → ${C_HDR}Domain${C_OFF} (left option, not URL prefix)
  3. Enter: ${C_HDR}$CLOUDFLARE_ZONE_NAME${C_OFF}
  4. Search Console will show a TXT record value beginning with
     ${C_DIM}google-site-verification=...${C_OFF}
     Copy ONLY that value (no quotes, no extra fields).

EOM
    read -r -p "  Paste the google-site-verification value here: " TOKEN_VALUE
    [[ -n "$TOKEN_VALUE" ]] || { err "Empty input. Aborting."; exit 1; }

    # Strip a leading 'google-site-verification=' if user pasted the whole
    # token — store only the value after the '=' as a TXT record.
    TXT_CONTENT="google-site-verification=${TOKEN_VALUE#google-site-verification=}"

    if $DRY_RUN; then
      info "Would POST TXT '$CLOUDFLARE_ZONE_NAME' = $TXT_CONTENT"
    else
      RESP=$(cf_post "/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
        "$(printf '{"type":"TXT","name":"%s","content":"%s","ttl":300}' "$CLOUDFLARE_ZONE_NAME" "$TXT_CONTENT")")
      if echo "$RESP" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("success") else 1)'; then
        ok "TXT record created."
      else
        err "TXT create failed:"
        echo "$RESP" | python3 -m json.tool >&2 || echo "$RESP" >&2
        exit 1
      fi
    fi

    cat <<EOM

  ${C_HDR}>>> NEXT — click Verify in Search Console <<<${C_OFF}

  5. Back in Search Console, click ${C_HDR}VERIFY${C_OFF}.
  6. When it succeeds, re-run this script:
       ${C_HDR}bash frontend/cloudflare/deploy.sh${C_OFF}
     The next stage will create the bucket; everything after that is
     fully automated.

EOM
    exit 0
  fi
fi

# ===========================================================================
# Stage 3 — provision bucket
# ===========================================================================
header "Stage 3 — bucket provisioning"

if bucket_exists; then
  ok "Bucket gs://$GCS_BUCKET_NAME already exists."
else
  CREATE_AS_FLAG=()
  if [[ -n "$DOMAIN_OWNER_ACCOUNT" ]]; then
    CREATE_AS_FLAG=(--account="$DOMAIN_OWNER_ACCOUNT")
  fi

  if $DRY_RUN; then
    info "Would create gs://$GCS_BUCKET_NAME in $GCS_BUCKET_LOCATION (project $GCP_PROJECT_ID)"
    [[ ${#CREATE_AS_FLAG[@]} -gt 0 ]] && info "  ${CREATE_AS_FLAG[*]}"
  else
    info "Creating gs://$GCS_BUCKET_NAME ..."
    if ! gcloud storage buckets create "gs://$GCS_BUCKET_NAME" \
        "${CREATE_AS_FLAG[@]}" \
        --project="$GCP_PROJECT_ID" \
        --location="$GCS_BUCKET_LOCATION" \
        --uniform-bucket-level-access 2>&1 | tee /tmp/.bucket_create.log; then
      if grep -q "you must verify" /tmp/.bucket_create.log; then
        err "GCS rejected bucket create — domain is not verified for the"
        err "Google account doing the create. Confirm Search Console verification"
        err "for $CLOUDFLARE_ZONE_NAME under: ${DOMAIN_OWNER_ACCOUNT:-$ACTIVE_ACCT}"
      fi
      exit 1
    fi
    ok "Bucket created (owner: ${DOMAIN_OWNER_ACCOUNT:-$ACTIVE_ACCT})."
  fi
fi

# Website config (idempotent — gcloud will set even if already set)
if $DRY_RUN; then
  info "Would set website main='$SITE_INDEX' 404='$SITE_404'"
else
  gcloud storage buckets update "gs://$GCS_BUCKET_NAME" \
    --web-main-page-suffix="$SITE_INDEX" \
    --web-error-page="$SITE_404" \
    --project="$GCP_PROJECT_ID" >/dev/null
  ok "Website config: main=$SITE_INDEX, 404=$SITE_404"
fi

# Bucket-wide public-read IAM (uniform access mode required, set above on create)
if $DRY_RUN; then
  info "Would grant allUsers -> roles/storage.objectViewer on gs://$GCS_BUCKET_NAME"
else
  CURRENT_BIND=$(gcloud storage buckets get-iam-policy "gs://$GCS_BUCKET_NAME" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null \
    | python3 -c "
import json, sys
p = json.load(sys.stdin)
for b in p.get('bindings', []):
    if b['role'] == 'roles/storage.objectViewer' and 'allUsers' in b.get('members', []):
        print('present'); break
")
  if [[ "$CURRENT_BIND" == "present" ]]; then
    ok "Public-read IAM already in place."
  else
    gcloud storage buckets add-iam-policy-binding "gs://$GCS_BUCKET_NAME" \
      --member=allUsers --role=roles/storage.objectViewer \
      --project="$GCP_PROJECT_ID" >/dev/null
    ok "Granted allUsers -> roles/storage.objectViewer."
  fi
fi

# ===========================================================================
# Stage 4 — sync frontend
# ===========================================================================
header "Stage 4 — sync frontend tree"

if $SKIP_SYNC; then
  warn "Skipped (--skip-sync)."
else
  # Make sure scripts/config.js exists — if not, regenerate via deploy.sh --local
  if [[ ! -f "$FRONTEND_DIR/scripts/config.js" ]]; then
    warn "frontend/scripts/config.js missing — regenerating via frontend/deploy.sh --local"
    if $DRY_RUN; then
      info "Would run: bash $FRONTEND_DIR/deploy.sh --local"
    else
      bash "$FRONTEND_DIR/deploy.sh" --local
    fi
  fi

  # Excludes: config files (carry secrets), deploy scripts, the cloudflare/
  # subdir, firebase metadata. NOTE: gcloud rsync's --exclude uses re.match
  # (anchored at start), so suffix patterns need a leading `.*`. Lesson from
  # an actual leak — every entry below was carefully sanity-checked.
  EXCLUDES='^(.*\.config|.*\.config\.example|deploy\.sh|cloudflare/.*|firebase\.json|\.firebaserc)$'

  if $DRY_RUN; then
    info "Would: gcloud storage rsync -r --delete-unmatched-destination-objects --exclude='$EXCLUDES' '$FRONTEND_DIR' 'gs://$GCS_BUCKET_NAME/'"
    info "Would: set Cache-Control 'public, max-age=300, must-revalidate' on *.html"
  else
    gcloud storage rsync -r --delete-unmatched-destination-objects \
      --exclude="$EXCLUDES" \
      "$FRONTEND_DIR" "gs://$GCS_BUCKET_NAME/" \
      --project="$GCP_PROJECT_ID"
    ok "Frontend synced."

    # HTML must revalidate frequently — otherwise CF edge serves stale pages
    # for hours after a deploy. CSS/JS keep gcloud's default (long-cache + manual
    # cache-bust via ?cb= if ever needed). Loop is per-file so we don't depend on
    # gcloud-storage glob support, which varies by SDK version.
    for html in "$FRONTEND_DIR"/*.html; do
      [[ -f "$html" ]] || continue
      fname=$(basename "$html")
      gcloud storage objects update "gs://$GCS_BUCKET_NAME/$fname" \
        --cache-control="public, max-age=300, must-revalidate" \
        --project="$GCP_PROJECT_ID" >/dev/null
    done
    ok "Cache-Control set on HTML (max-age=300, must-revalidate)."
  fi
fi

# ===========================================================================
# Stage 5 — DNS cutover
# ===========================================================================
header "Stage 5 — DNS cutover (apex -> c.storage.googleapis.com)"

if $SKIP_DNS; then
  warn "Skipped (--skip-dns)."
else
  # Find the existing apex record (whatever type)
  APEX_JSON=$(cf_get "/zones/$CLOUDFLARE_ZONE_ID/dns_records?name=$CLOUDFLARE_ZONE_NAME")
  APEX_PARSED=$(echo "$APEX_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
target = None
for r in d.get('result', []):
    if r['name'] == '$CLOUDFLARE_ZONE_NAME' and r['type'] in ('A', 'AAAA', 'CNAME'):
        target = r; break
if target:
    print(target['id'], target['type'], target['content'], target.get('proxied', False))
")

  if [[ -z "$APEX_PARSED" ]]; then
    warn "No existing apex A/AAAA/CNAME record — creating CNAME directly."
    APEX_ID=""
    APEX_TYPE=""
    APEX_CONTENT=""
  else
    read -r APEX_ID APEX_TYPE APEX_CONTENT APEX_PROXIED <<< "$APEX_PARSED"
    info "Current apex record: $APEX_TYPE $CLOUDFLARE_ZONE_NAME -> $APEX_CONTENT (proxied=$APEX_PROXIED)"
  fi

  TARGET_CONTENT="c.storage.googleapis.com"

  if [[ "$APEX_TYPE" == "CNAME" && "$APEX_CONTENT" == "$TARGET_CONTENT" ]]; then
    ok "Apex CNAME is already pointing at $TARGET_CONTENT. No change needed."
  else
    BODY=$(printf '{"type":"CNAME","name":"%s","content":"%s","ttl":1,"proxied":true}' "$CLOUDFLARE_ZONE_NAME" "$TARGET_CONTENT")

    if $DRY_RUN; then
      info "Would replace apex with: CNAME $CLOUDFLARE_ZONE_NAME -> $TARGET_CONTENT (proxied)"
    else
      # CF doesn't allow type-change via PATCH on most plans. Delete + create.
      if [[ -n "$APEX_ID" ]]; then
        info "Deleting old $APEX_TYPE record..."
        cf_delete "/zones/$CLOUDFLARE_ZONE_ID/dns_records/$APEX_ID" >/dev/null
      fi
      info "Creating CNAME $CLOUDFLARE_ZONE_NAME -> $TARGET_CONTENT ..."
      RESP=$(cf_post "/zones/$CLOUDFLARE_ZONE_ID/dns_records" "$BODY")
      if echo "$RESP" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("success") else 1)'; then
        ok "Apex CNAME created (proxied)."
      else
        err "CNAME create failed:"
        echo "$RESP" | python3 -m json.tool >&2 || echo "$RESP" >&2
        exit 1
      fi
    fi
  fi
fi

# ===========================================================================
# Stage 6 — live verify
# ===========================================================================
header "Stage 6 — live verify"

if $DRY_RUN; then
  info "Would: curl -sI https://$CLOUDFLARE_ZONE_NAME/"
  info "Done (dry-run)."
  exit 0
fi

# Edge propagation can take ~30s after a fresh CNAME flip. Retry a few times.
TARGET_URL="https://$CLOUDFLARE_ZONE_NAME/"
ATTEMPTS=8
for i in $(seq 1 $ATTEMPTS); do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -L --max-time 15 "$TARGET_URL" || echo "000")
  if [[ "$HTTP_CODE" == "200" ]]; then
    ok "GET $TARGET_URL -> 200 OK"
    SERVER=$(curl -sI --max-time 10 "$TARGET_URL" | grep -i '^server:' | tr -d '\r' || true)
    [[ -n "$SERVER" ]] && info "  $SERVER"
    break
  fi
  warn "Attempt $i/$ATTEMPTS — got HTTP $HTTP_CODE; waiting 8s for edge..."
  sleep 8
done

if [[ "$HTTP_CODE" != "200" ]]; then
  err "Site did not return 200 after $ATTEMPTS attempts."
  err "Investigate:"
  err "  curl -vI $TARGET_URL"
  err "  https://storage.googleapis.com/$GCS_BUCKET_NAME/$SITE_INDEX  (origin reachability)"
  err "  CF dashboard -> SSL/TLS mode is 'Flexible' (origin is HTTP-only)."
  exit 1
fi

echo
header "============================================"
ok "Live at https://$CLOUDFLARE_ZONE_NAME/"
header "============================================"
info "Origin   : gs://$GCS_BUCKET_NAME/ (allUsers:objectViewer)"
info "Edge     : Cloudflare proxied (orange cloud)"
info "TLS      : terminated at CF; backend is HTTP (GCS website endpoint)"
info "Re-deploy: bash frontend/cloudflare/deploy.sh   (rsync + verify)"
