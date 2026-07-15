#!/usr/bin/env bash
# Install Ansible collections from config/requirements.yml
#
# Authenticates against console.redhat.com and/or a Private Automation Hub,
# generates ansible.cfg, and runs ansible-galaxy collection install.
#
# Usage:
#   ./deploy.sh          # Install collections
#   ./deploy.sh --delete # Remove generated ansible.cfg only
#
# Environment / config files:
#   ~/.aap-demo/galaxy-token   — offline token for console.redhat.com
#   ~/.aap-demo/pah-config.yml — PAH URL + auth (token or user/pass)
#   GALAXY_IGNORE_CERTS=true   — skip SSL cert verification
#   SKIP_COLLECTIONS=true      — no-op (for scripted callers)

set -e

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "${ADDON_DIR}/../.." && pwd)"

# Colour vars used by galaxy-auth.sh functions
_RED='\033[0;31m'
_GREEN='\033[0;32m'
_YELLOW='\033[0;33m'
_NC='\033[0m'
_err() { printf "${_RED}▸${_NC} %s\n" "$*" >&2; }

GALAXY_TOKEN_FILE="${HOME}/.aap-demo/galaxy-token"
PAH_CONFIG_FILE="${HOME}/.aap-demo/pah-config.yml"

# shellcheck source=../../includes/galaxy-auth.sh
source "${SCRIPT_DIR}/includes/galaxy-auth.sh"

ACTION="${1:-deploy}"

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  cfg="${SCRIPT_DIR}/ansible.cfg"
  if [ -f "$cfg" ]; then
    rm -f "$cfg"
    echo "✓ ansible.cfg removed"
  else
    echo "Nothing to remove (ansible.cfg not present)"
  fi
  exit 0
fi

cd "${SCRIPT_DIR}"

detect_galaxy_credentials
validate_galaxy_token || exit 1
validate_pah_config   || exit 1
generate_ansible_cfg
install_collections "${SCRIPT_DIR}/config/requirements.yml" || exit 1
