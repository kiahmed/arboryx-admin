#!/bin/bash
# Sets up GCP auth and quota project for local development.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../arboryx_admin_backend.config"

SVC_ACCOUNT_KEY="$SCRIPT_DIR/service_account.json"

if [ ! -f "$SVC_ACCOUNT_KEY" ]; then
    echo "Error: Service account key not found at $SVC_ACCOUNT_KEY"
    echo "Copy it from the arboryx.ai project:"
    echo "  cp ../arboryx.ai/dev-utils/service_account.json dev-utils/"
    exit 1
fi

echo "Activating service account..."
gcloud auth activate-service-account "$SA_EMAIL" \
    --key-file="$SVC_ACCOUNT_KEY" \
    --project="$PROJECT_ID"

echo "Setting quota project..."
gcloud auth application-default set-quota-project "$PROJECT_ID"

export GOOGLE_APPLICATION_CREDENTIALS="$SVC_ACCOUNT_KEY"
echo ""
echo "Ready. GOOGLE_APPLICATION_CREDENTIALS=$SVC_ACCOUNT_KEY"
echo ""
