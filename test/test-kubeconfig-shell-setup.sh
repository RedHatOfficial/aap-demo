#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
paths_file="${repo_root}/includes/aap-demo-paths.sh"
cli="${repo_root}/aap-demo.sh"

grep -Fq 'aap_demo_offer_kubeconfig_shell_setup' "$paths_file" "$cli"
grep -Fq 'KUBECONFIG_FROM_ENV' "$cli"
grep -Fq 'quiet' "$paths_file"
grep -Fq 'zsh' "$paths_file"
grep -Fq 'fish' "$paths_file"
grep -Fq 'powershell' "$paths_file"

test_home="$(mktemp -d)"
trap 'rm -rf "$test_home"' EXIT
mkdir -p "$test_home/.aap-demo"
printf 'apiVersion: v1\n' >"$test_home/.aap-demo/kubeconfig.microshift"

HOME="$test_home" AAP_DEMO_DIR="$test_home/.aap-demo" \
  AAP_DEMO_KUBECONFIG="$test_home/.aap-demo/kubeconfig.microshift" \
  bash -c 'source "$1"; aap_demo_offer_kubeconfig_shell_setup false ""' _ "$paths_file" </dev/null

[ ! -e "$test_home/.aap-demo/.kubeconfig-shell-setup" ]
echo "PASS: kubeconfig shell setup honors non-interactive mode and shell detection"
