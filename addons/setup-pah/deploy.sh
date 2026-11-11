#!/usr/bin/env bash
# Configure Private Automation Hub remotes on a running AAP instance
#
# Stores the Red Hat Automation Hub offline token in ~/.ansible/conf/env.yml.
# Get one at: https://console.redhat.com/ansible/automation-hub/token
#
# Usage:
#   ./deploy.sh    # Configure PAH remotes

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../includes/galaxy-auth.sh
source "${SCRIPT_DIR}/../../includes/galaxy-auth.sh"

NAMESPACE="${NAMESPACE:-aap-operator}"
GALAXY_TOKEN_FILE="${GALAXY_TOKEN_FILE:-${AAP_DEMO_DIR:-$HOME/.aap-demo}/galaxy-token}"
PAH_CONFIG_FILE="${PAH_CONFIG_FILE:-${AAP_DEMO_DIR:-$HOME/.aap-demo}/pah-config.yml}"

export NAMESPACE GALAXY_TOKEN_FILE PAH_CONFIG_FILE

echo "Setting up Private Automation Hub..."
echo ""

ensure_galaxy_credentials

echo "✓ Valid Automation Hub token loaded from encrypted credential storage"
echo ""
echo "Configuring AAP Private Automation Hub remotes..."
configure_pah_remotes
