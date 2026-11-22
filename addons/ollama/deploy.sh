#!/usr/bin/env bash
# Remove the in-cluster Ollama of earlier aap-demo releases.
#
# AO now uses Ollama running on the host (ADR-046), so enabling this addon only
# explains that. --delete removes what the old installer created. Kept for one
# release.
#
# Usage:
#   ./deploy.sh          # Explain the host Ollama and exit 1
#   ./deploy.sh --delete # Remove the old in-cluster Ollama

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../includes/ao-host-ollama.sh
source "${SCRIPT_DIR}/../../includes/ao-host-ollama.sh"

ACTION="${1:-deploy}"

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing the in-cluster Ollama from an earlier aap-demo..."
  kubectl delete namespace "$AO_HOST_OLLAMA_OLD_NAMESPACE" --ignore-not-found
  kubectl delete clusterrolebinding aap-demo-ollama-anyuid --ignore-not-found
  echo "✓ In-cluster Ollama removed"
  exit 0
fi

echo "ERROR: aap-demo no longer installs Ollama in the cluster. AO uses Ollama on the host." >&2
echo "  ${AO_HOST_OLLAMA_INSTALL_HINT} See docs/adr/046-ao-host-ollama.md." >&2
exit 1
