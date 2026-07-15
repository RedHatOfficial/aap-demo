#!/usr/bin/env bash
# Configure Private Automation Hub remotes on a running AAP instance
#
# Requires a Red Hat Automation Hub offline token saved at ~/.aap-demo/galaxy-token
# Get one at: https://console.redhat.com/ansible/automation-hub/token
#
# Usage:
#   ./deploy.sh    # Configure PAH remotes

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../includes/galaxy-auth.sh
source "${SCRIPT_DIR}/../../includes/galaxy-auth.sh"

GALAXY_TOKEN_FILE="${GALAXY_TOKEN_FILE:-$HOME/.aap-demo/galaxy-token}"

echo "Setting up Private Automation Hub..."
echo ""

if [ ! -f "$GALAXY_TOKEN_FILE" ]; then
  url="https://console.redhat.com/ansible/automation-hub/token"

  if command -v open >/dev/null 2>&1; then
    open "$url"
    echo "Opening browser to Red Hat Automation Hub..."
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url"
    echo "Opening browser to Red Hat Automation Hub..."
  elif command -v start >/dev/null 2>&1; then
    start "$url"
    echo "Opening browser to Red Hat Automation Hub..."
  else
    echo "Visit this URL in your browser:"
    echo "  $url"
  fi

  echo ""
  echo "Steps:"
  echo "  1. Log in with your Red Hat account"
  echo "  2. Click 'Load token' button"
  echo "  3. Copy the 'Offline Token' (long base64 string, ~1500 characters)"
  echo "  4. Run this command to save it:"
  echo ""
  echo "     echo \"YOUR_OFFLINE_TOKEN\" > ~/.aap-demo/galaxy-token"
  echo "     chmod 600 ~/.aap-demo/galaxy-token"
  echo ""
  echo "  5. Re-run: aap-demo enable setup-pah"
  echo ""
  echo "Documentation: docs/collection-authentication.md"
  exit 0
fi

echo "✓ Galaxy token found at $GALAXY_TOKEN_FILE"
echo ""
echo "Configuring AAP Private Automation Hub remotes..."
configure_pah_remotes
