#!/bin/bash
# update_cloud_func.sh
# DEPRECATED — this script now delegates to the unified deploy_cloud_func.sh.
# The unified script auto-detects whether to do a full deploy or a source update.

echo "NOTE: update_cloud_func.sh is deprecated. Forwarding to deploy_cloud_func.sh..."
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/deploy_cloud_func.sh" "$@"
