#!/usr/bin/env bash
# Regression tests for the APME portal's in-cluster AAP URL selection.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../addons/apme-eap/lib.sh
source "${REPO_ROOT}/addons/apme-eap/lib.sh"

assert_equals() {
  local expected="$1" actual="$2" description="$3"
  if [ "${actual}" != "${expected}" ]; then
    printf '✗ %s: expected %s, got %s\n' "${description}" "${expected}" "${actual}" >&2
    exit 1
  fi
  printf '✓ %s\n' "${description}"
}

assert_equals \
  'http://aap-aap-operator.apps.crc.testing' \
  "$(apme_aap_portal_host_url 'https://aap-aap-operator.apps.crc.testing' 'apps.crc.testing')" \
  'uses HTTP for the default CRC route domain'

assert_equals \
  'http://aap-aap-operator.apps.127.0.0.1.nip.io' \
  "$(apme_aap_portal_host_url 'https://aap-aap-operator.apps.127.0.0.1.nip.io' 'apps.127.0.0.1.nip.io')" \
  'uses HTTP for nip.io MicroShift routes'

assert_equals \
  'https://aap.example.test' \
  "$(apme_aap_portal_host_url 'https://aap.example.test' 'apps.example.test')" \
  'preserves HTTPS for non-MicroShift routes'

assert_equals \
  'http://aap-aap-operator.apps.crc.testing' \
  "$(apme_aap_portal_host_url 'https://aap-aap-operator.apps.crc.testing/' 'apps.crc.testing')" \
  'removes a trailing slash from the portal URL'
