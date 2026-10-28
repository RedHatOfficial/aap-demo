#!/usr/bin/env bash
# The dashboard's targeted Fix SSL action must be available independently of repair.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../includes/ingress-ca-trust.sh"

CA_PATH="${TMPDIR:-/tmp}/test-ingress-ca.crt"
STATUS_RESULT=0
CALLS=()
get_ingress_ca_cert_path() { printf '%s\n' "$CA_PATH"; }
install_ingress_ca_trust() { CALLS+=(install); }
ingress_ca_trust_status() {
  [[ "$1" == "$CA_PATH" ]] || return 2
  CALLS+=(verify)
  return "$STATUS_RESULT"
}

if ! fix_ingress_ca_trust >/dev/null; then
  echo "FAIL: targeted SSL repair did not pass when TLS trust verified" >&2
  exit 1
fi
if [[ "${CALLS[*]}" != "install verify" ]]; then
  echo "FAIL: targeted SSL repair did not only install and verify ingress trust" >&2
  exit 1
fi

CALLS=()
STATUS_RESULT=1
if fix_ingress_ca_trust >/dev/null 2>&1; then
  echo "FAIL: targeted SSL repair reported success while TLS trust remained unresolved" >&2
  exit 1
fi
if [[ "${CALLS[*]}" != "install verify" ]]; then
  echo "FAIL: failed SSL verification skipped the trust workflow" >&2
  exit 1
fi

echo "PASS: targeted SSL repair installs and verifies trust without cluster repair"

output="$("${SCRIPT_DIR}/../aap-demo.sh" help 2>&1)"
if grep -qE '^    trust-ca[[:space:]]+Repair ingress certificate trust only$' <<<"$output"; then
  echo "PASS: dedicated SSL trust command is documented"
else
  echo "FAIL: help must expose trust-ca separately from cluster repair" >&2
  exit 1
fi
