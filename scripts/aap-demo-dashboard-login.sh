#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/includes/state-service.sh"

# Desktop autostart runs in the user's graphical session, not the root boot job.
if [ "${1:-}" = --always ] || aap_demo_service_managed; then
  exec bash "$SCRIPT_DIR/aap-demo.sh" dashboard
fi
