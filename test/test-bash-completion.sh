#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/aap-demo-completion.bash
source "${ROOT_DIR}/scripts/aap-demo-completion.bash"

assert_completes() {
  local expected="$1"
  shift
  COMP_WORDS=("$@")
  COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
  _aap_demo
  if [[ " ${COMPREPLY[*]} " != *" ${expected} "* ]]; then
    printf 'FAIL: expected completion %q for: %s\n' "$expected" "${COMP_WORDS[*]}" >&2
    printf 'Completions: %s\n' "${COMPREPLY[*]}" >&2
    exit 1
  fi
}

assert_not_completes() {
  local unexpected="$1"
  shift
  COMP_WORDS=("$@")
  COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
  _aap_demo
  if [[ " ${COMPREPLY[*]} " == *" ${unexpected} "* ]]; then
    printf 'FAIL: unexpected completion %q for: %s\n' "$unexpected" "${COMP_WORDS[*]}" >&2
    exit 1
  fi
}

assert_completes enable aap-demo ""
assert_completes wire aap-demo ""
assert_completes system-info aap-demo system
assert_completes product-demos aap-demo enable product
assert_completes local-cache aap-demo disable local
assert_completes keepalive aap-demo credentials ""
assert_completes enable aap-demo credentials keepalive ""
assert_completes setup aap-demo credentials keepalive se
assert_completes run aap-demo credentials keepalive r
assert_completes auth aap-demo fleet ""
assert_completes ssh aap-demo fleet s
assert_completes rhc-connect aap-demo fleet rh
assert_completes register aap-demo fleet reg
assert_completes status aap-demo fleet auth st
assert_completes rhel9 aap-demo fleet add --image ""
assert_completes --image=rhel10 aap-demo fleet add --image=rhel
assert_completes --full-demo aap-demo create --
assert_completes --show-secrets aap-demo status --
assert_completes --purge-data aap-demo disable ao --
assert_completes save aap-demo enable local-cache s
assert_not_completes save aap-demo enable ao s

echo "PASS: Bash completion covers commands, addons, nested actions, and options"
