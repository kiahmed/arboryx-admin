#!/usr/bin/env bash
# ============================================================================
# cloud_function_auth/deploy.sh — deploy arboryx-auth (cross-subdomain SSO)
#
# Phase 2. Mints the shared `.arboryx.ai` HttpOnly session cookie.
# Idempotent. Safe to re-run.
#
# Unlike the rotator/reminder (internal-only, scheduler-driven), this function
# is PUBLIC and first-party: it is reached by browsers through a Firebase
# Hosting rewrite (`/__session/**` → this Cloud Run service). So:
#   • --allow-unauthenticated  (Hosting/GCLB + browsers invoke it; the function
#     does its OWN auth via the Firebase ID token / session cookie).
#   • default ingress (all)     (must be reachable from Hosting's frontend).
#   • no Cloud Scheduler job.
#
# Runtime SA: market-agent-sa (roles/firebaseauth.admin) — verifies ID tokens,
# mints session cookies via the Identity Toolkit REST API, reads/writes the
# shared `users/{uid}` docs in the (default) Firestore. It does NOT need
# roles/iam.serviceAccountTokenCreator (create_session_cookie does not sign a
# JWT locally). See main.py header for the details.
#
# Prereqs:
#   1. APIs enabled: cloudfunctions, run, cloudbuild, artifactregistry,
#      firebaseauth, firestore (already enabled for this project).
#   2. Firebase Hosting rewrite in frontend/firebase.json (this repo) points
#      /__session/** at serviceId "arboryx-auth" — deploy that separately with
#      `firebase deploy --only hosting` (or a preview channel for testing).
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1090
source "$REPO_ROOT/arboryx_admin_backend.config"

# Tunables
AUTH_NAME="${AUTH_NAME:-arboryx-auth}"
AUTH_SA="${AUTH_SA:-$SA_EMAIL}"   # market-agent-sa@... (roles/firebaseauth.admin)
AUTH_DIR="$SCRIPT_DIR"
COOKIE_DOMAIN="${COOKIE_DOMAIN:-.arboryx.ai}"
PREVIEW_ORIGIN="${PREVIEW_ORIGIN:-https://arboryx-ai--phase1-auth-mu303eh6.web.app}"

# Colour helpers
if [[ -t 1 ]]; then
  C_HDR=$'\033[1m'; C_OK=$'\033[0;32m'; C_INFO=$'\033[0;36m'; C_WARN=$'\033[0;33m'; C_OFF=$'\033[0m'
else
  C_HDR=''; C_OK=''; C_INFO=''; C_WARN=''; C_OFF=''
fi
header() { echo -e "${C_HDR}$*${C_OFF}"; }
ok()     { echo -e "${C_OK}[OK]${C_OFF}    $*"; }
info()   { echo -e "${C_INFO}[INFO]${C_OFF}  $*"; }
warn()   { echo -e "${C_WARN}[WARN]${C_OFF}  $*"; }

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

header "============================================"
header "  Arboryx — Auth (SSO) Deploy"
header "============================================"
info "Function     : $AUTH_NAME"
info "Service AC   : $AUTH_SA"
info "Cookie domain: $COOKIE_DOMAIN"
info "Project      : $PROJECT_ID"
info "Region       : $LOCATION"
info "Dry-run      : $DRY_RUN"
echo

if ! gcloud iam service-accounts describe "$AUTH_SA" --project="$PROJECT_ID" >/dev/null 2>&1; then
  warn "Service account $AUTH_SA does not exist / not visible."
  warn "Confirm SA_EMAIL in arboryx_admin_backend.config."
  exit 1
fi
ok "Auth SA exists."

# ---------------------------------------------------------------------------
# 1) Deploy the auth function (Gen 2, PUBLIC — invoked via Hosting rewrite)
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
  info "Would run: gcloud functions deploy $AUTH_NAME --gen2 --region=$LOCATION --allow-unauthenticated ..."
else
  header "--- Step 1: Deploy auth function ---"
  gcloud functions deploy "$AUTH_NAME" \
    --gen2 \
    --region="$LOCATION" \
    --runtime=python312 \
    --source="$AUTH_DIR" \
    --entry-point=auth_handler \
    --trigger-http \
    --allow-unauthenticated \
    --timeout=60s \
    --memory=256Mi \
    --max-instances=10 \
    --set-env-vars="PROJECT_ID=$PROJECT_ID,COOKIE_DOMAIN=$COOKIE_DOMAIN,PREVIEW_ORIGIN=$PREVIEW_ORIGIN" \
    --service-account="$AUTH_SA" \
    --project="$PROJECT_ID"
  ok "Auth function deployed."
fi

# ---------------------------------------------------------------------------
# 2) Resolve the Cloud Run URL (Gen 2 functions ARE Cloud Run services)
# ---------------------------------------------------------------------------
AUTH_URL=$(gcloud functions describe "$AUTH_NAME" \
  --gen2 --region="$LOCATION" --project="$PROJECT_ID" \
  --format='value(serviceConfig.uri)' 2>/dev/null || true)
if [[ -z "$AUTH_URL" && "$DRY_RUN" == false ]]; then
  warn "Could not resolve auth URL (deploy probably failed)."
  exit 1
fi
info "Auth URL      : ${AUTH_URL:-<dry-run>}"
info "Cloud Run svc : $AUTH_NAME (region $LOCATION) — use this as the"
info "                firebase.json rewrite serviceId."

echo
header "============================================"
ok "Auth deploy complete."
header "============================================"
info ""
info "Next: publish the Hosting rewrite so /__session/** is first-party:"
info "  cd frontend && firebase deploy --only hosting            # prod"
info "  cd frontend && firebase hosting:channel:deploy phase2-sso  # preview"
info ""
info "Smoke test the deployed function directly (structural — no cookie flow):"
info "  curl -si -X OPTIONS '$AUTH_URL/login' -H 'Origin: https://arboryx.ai' | grep -i access-control"
info "  curl -si '$AUTH_URL/me'   # expect 401 no_session"
info ""
info "View logs:"
info "  gcloud functions logs read $AUTH_NAME --gen2 --region=$LOCATION --project=$PROJECT_ID --limit=20"
