#!/usr/bin/env bash
# Refuse cluster commands when the current kubeconfig context is remote.
# Issue: https://github.com/RedHatOfficial/aap-demo/issues/252

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="${repo_root}/includes/kubeconfig-guard.sh"
cli="${repo_root}/aap-demo.sh"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required for kubeconfig guard tests" >&2
  exit 1
fi

grep -Fq 'aap_demo_reject_remote_kubeconfig' "$guard" "$cli" "${repo_root}/includes/crc-create.sh"
grep -Fq 'AAP_DEMO_ALLOW_REMOTE_KUBECONFIG' "$cli"
grep -Fq './test/test-kubeconfig-guard.sh' "${repo_root}/.github/workflows/test.yaml"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export HOME="$work/home"
mkdir -p "$HOME"
unset AAP_DEMO_ALLOW_REMOTE_KUBECONFIG COMMAND || true

# Shadow the real crc binary so a developer VM address cannot change results.
crc() {
  if [ "${1:-}" = "ip" ]; then
    printf '%s\n' "${CRC_IP_STUB:-}"
  fi
  return 0
}

new_kubeconfig() {
  local file="$1"
  : >"$file"
  chmod 600 "$file"
}

add_context() {
  local file="$1"
  local name="$2"
  local server="$3"
  KUBECONFIG="$file" kubectl config set-cluster "$name" --server="$server" >/dev/null
  KUBECONFIG="$file" kubectl config set-credentials "$name" --token=fake >/dev/null
  KUBECONFIG="$file" kubectl config set-context "$name" --cluster="$name" --user="$name" >/dev/null
}

use_context() {
  KUBECONFIG="$1" kubectl config use-context "$2" >/dev/null
}

reject_output() {
  local rc
  set +e
  reject_output_text=$(aap_demo_reject_remote_kubeconfig 2>&1)
  rc=$?
  set -e
  printf '%s' "$reject_output_text"
  return "$rc"
}

assert_rejected() {
  local label="$1"
  local output rc
  set +e
  output=$(reject_output)
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    printf 'FAIL %s: expected the remote context to be rejected\n%s\n' "$label" "$output" >&2
    exit 1
  fi
  printf '%s' "$output"
}

assert_allowed() {
  local label="$1"
  local output rc
  set +e
  output=$(reject_output)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    printf 'FAIL %s: expected the local context to be allowed\n%s\n' "$label" "$output" >&2
    exit 1
  fi
}

# shellcheck source=includes/kubeconfig-guard.sh
source "$guard"

remote_kc="$work/remote.yaml"
new_kubeconfig "$remote_kc"
add_context "$remote_kc" microshift "https://127.0.0.1:6443"
add_context "$remote_kc" sandbox "https://api.example.invalid:6443"
use_context "$remote_kc" sandbox
export KUBECONFIG="$remote_kc"
export COMMAND=enable
remote_message=$(assert_rejected "remote current context")
printf '%s\n' "$remote_message" | grep -F 'remote cluster' >/dev/null
printf '%s\n' "$remote_message" | grep -F 'Current context: sandbox' >/dev/null
printf '%s\n' "$remote_message" | grep -F 'https://api.example.invalid:6443' >/dev/null
printf '%s\n' "$remote_message" | grep -F 'use-context microshift' >/dev/null
printf '%s\n' "$remote_message" | grep -F 'AAP_DEMO_ALLOW_REMOTE_KUBECONFIG=true' >/dev/null

use_context "$remote_kc" microshift
assert_allowed "microshift loopback context"

add_context "$remote_kc" localhost-api "https://localhost:6443"
use_context "$remote_kc" localhost-api
assert_allowed "localhost api"

add_context "$remote_kc" crc-name "https://API.CRC.TESTING:6443"
use_context "$remote_kc" crc-name
assert_allowed "api.crc.testing api"

add_context "$remote_kc" v6 "https://[::1]:6443"
use_context "$remote_kc" v6
assert_allowed "ipv6 loopback api"

# A context named microshift is not trusted when its server is remote.
renamed="$work/renamed.yaml"
new_kubeconfig "$renamed"
add_context "$renamed" microshift "https://api.example.invalid:6443"
use_context "$renamed" microshift
export KUBECONFIG="$renamed"
renamed_message=$(assert_rejected "microshift name with remote server")
printf '%s\n' "$renamed_message" | grep -F 'aap-demo kubeconfig' >/dev/null
if printf '%s\n' "$renamed_message" | grep -F 'use-context microshift' >/dev/null; then
  echo "FAIL microshift name with remote server: suggested the remote context" >&2
  exit 1
fi

# CRC's own kubeconfig and `crc ip` identify the VM when the server is not a loopback name.
export CRC_IP_STUB="192.168.130.11"
crc_ip_kc="$work/crc-ip.yaml"
new_kubeconfig "$crc_ip_kc"
add_context "$crc_ip_kc" custom "https://192.168.130.11:6443"
use_context "$crc_ip_kc" custom
export KUBECONFIG="$crc_ip_kc"
assert_allowed "crc ip address"

export CRC_IP_STUB=""
assert_rejected "private ip without crc ip" >/dev/null

mkdir -p "$HOME/.crc/machines/crc"
crc_file="$HOME/.crc/machines/crc/kubeconfig"
new_kubeconfig "$crc_file"
add_context "$crc_file" microshift "https://10.88.0.5:6443"
vm_kc="$work/vm.yaml"
new_kubeconfig "$vm_kc"
add_context "$vm_kc" custom "https://10.88.0.5:6443"
use_context "$vm_kc" custom
export KUBECONFIG="$vm_kc"
assert_allowed "server recorded in the crc kubeconfig"

use_context "$remote_kc" sandbox
export KUBECONFIG="$remote_kc"
export COMMAND=ssh
assert_allowed "ssh skips the guard"
export COMMAND=stop
assert_allowed "stop skips the guard"
export COMMAND=kubeconfig
assert_allowed "kubeconfig refresh skips the guard"
export COMMAND=redhat-status
assert_allowed "redhat-status skips the guard"
export COMMAND=enable
export AAP_DEMO_ALLOW_REMOTE_KUBECONFIG=true
use_context "$remote_kc" sandbox
export KUBECONFIG="$remote_kc"
assert_allowed "explicit remote override"
unset AAP_DEMO_ALLOW_REMOTE_KUBECONFIG

help_output=$("$cli" help 2>&1)
printf '%s\n' "$help_output" | grep -F 'AAP_DEMO_ALLOW_REMOTE_KUBECONFIG' >/dev/null

cli_output=$("$cli" --kubeconfig="$remote_kc" enable ao 2>&1) && cli_rc=0 || cli_rc=$?
if [ "$cli_rc" -eq 0 ]; then
  printf 'FAIL cli enable: remote context was accepted\n%s\n' "$cli_output" >&2
  exit 1
fi
printf '%s\n' "$cli_output" | grep -F 'remote cluster' >/dev/null
if printf '%s\n' "$cli_output" | grep -F 'Enabling addon' >/dev/null; then
  echo "FAIL cli enable: addon deploy started against the remote context" >&2
  exit 1
fi

echo "kubeconfig guard tests passed"
