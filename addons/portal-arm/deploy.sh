#!/usr/bin/env bash
# Backward-compatible alias — portal-arm is merged into addons/portal (auto-detects CPU).
set -e
echo "Note: portal-arm is merged into the portal addon (auto-detects cluster CPU)."
echo "      Running: aap-demo enable portal"
echo ""
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../portal/deploy.sh" "$@"
