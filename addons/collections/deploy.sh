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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAP_DEMO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source shared functions from main script without executing it
# shellcheck source=../../aap-demo.sh
_source_functions() {
  # Extract and eval only the function definitions we need
  local funcs=(detect_galaxy_credentials validate_galaxy_token validate_pah_config
               generate_ansible_cfg install_collections)
  local pattern
  pattern=$(printf "%s\|" "${funcs[@]}")
  pattern="${pattern%\\|}"

  # Source colour vars and helpers by pulling them from the main script
  # shellcheck disable=SC1090
  source <(grep -E '^\s*(_RED|_GREEN|_YELLOW|_NC|_err)[= ]' "${AAP_DEMO_ROOT}/aap-demo.sh" || true)
  _err() { printf "\033[0;31m▸\033[0m %s\n" "$*" >&2; }

  # Source config paths
  GALAXY_TOKEN_FILE="${HOME}/.aap-demo/galaxy-token"
  PAH_CONFIG_FILE="${HOME}/.aap-demo/pah-config.yml"
}

_source_functions

# Inline the required functions (keeps addon self-contained)
# shellcheck source=../../aap-demo.sh
source <(sed -n '/^detect_galaxy_credentials()/,/^}/p;
                 /^validate_galaxy_token()/,/^}/p;
                 /^validate_pah_config()/,/^}/p;
                 /^generate_ansible_cfg()/,/^}/p;
                 /^install_collections()/,/^}/p' \
         "${AAP_DEMO_ROOT}/aap-demo.sh")

ACTION="${1:-deploy}"

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  cfg="${AAP_DEMO_ROOT}/ansible.cfg"
  if [ -f "$cfg" ]; then
    rm -f "$cfg"
    echo "✓ ansible.cfg removed"
  else
    echo "Nothing to remove (ansible.cfg not present)"
  fi
  exit 0
fi

cd "${AAP_DEMO_ROOT}"

detect_galaxy_credentials
validate_galaxy_token || exit 1
validate_pah_config   || exit 1
generate_ansible_cfg
install_collections "${AAP_DEMO_ROOT}/config/requirements.yml" || exit 1
