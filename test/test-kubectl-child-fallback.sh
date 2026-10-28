#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$(cat "${repo_root}/aap-demo.sh")"

if ! grep -q 'export -f kubectl' <<<"$script"; then
  echo '✗ oc fallback must be exported to child Bash processes' >&2
  exit 1
fi

echo 'kubectl child-process fallback checks passed'

selection=$(sed -n '/^check_kubectl() {$/,/^}$/p' "${repo_root}/aap-demo.sh")
(
  kubectl() { return 126; }
  oc() { printf 'oc %s\n' "$*"; }
  export -f oc
  eval "$selection"
  check_kubectl
  [[ "$(kubectl get nodes)" == 'oc get nodes' ]]
  [[ "$(bash -c 'kubectl get nodes')" == 'oc get nodes' ]]
)
(
  kubectl() { printf 'kubectl %s\n' "$*"; }
  oc() { return 1; }
  eval "$selection"
  check_kubectl
  [[ "$(kubectl get nodes)" == 'kubectl get nodes' ]]
)
echo 'Client selection handles usable and unusable kubectl, including child shells'
