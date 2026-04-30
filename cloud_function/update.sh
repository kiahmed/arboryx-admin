#!/bin/bash
# cloud_function/update.sh
# DEPRECATED — this script now delegates to cloud_function/deploy.sh.
# The unified script auto-detects whether to do a full deploy or a source update.

echo "NOTE: cloud_function/update.sh is deprecated. Forwarding to cloud_function/deploy.sh..."
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/deploy.sh" "$@"
