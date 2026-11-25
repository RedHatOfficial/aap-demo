#!/usr/bin/env bash
# Regression tests for apme_helm_bootstrap platform-aware Helm download.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROLE_DIR="${REPO_ROOT}/addons/apme-eap/playbooks/roles/apme_helm_bootstrap"
DEFAULTS="${ROLE_DIR}/defaults/main.yml"
TASKS="${ROLE_DIR}/tasks/main.yml"

assert_contains() {
  local file="$1" needle="$2" description="$3"
  if ! grep -Fq "${needle}" "${file}"; then
    printf '✗ %s: missing %s in %s\n' "${description}" "${needle}" "${file}" >&2
    exit 1
  fi
  printf '✓ %s\n' "${description}"
}

assert_not_contains() {
  local file="$1" needle="$2" description="$3"
  if grep -Fq "${needle}" "${file}"; then
    printf '✗ %s: found forbidden %s in %s\n' "${description}" "${needle}" "${file}" >&2
    exit 1
  fi
  printf '✓ %s\n' "${description}"
}

assert_contains "${DEFAULTS}" '{{ apme_helm_platform }}' \
  'defaults use apme_helm_platform in archive path'
assert_not_contains "${DEFAULTS}" 'linux-amd64.tar.gz' \
  'defaults do not hardcode linux-amd64 archive name'
assert_contains "${TASKS}" 'darwin-arm64' \
  'tasks map Darwin arm64 to darwin-arm64'
assert_contains "${TASKS}" 'linux-arm64' \
  'tasks map Linux arm64 to linux-arm64'
assert_contains "${TASKS}" 'apme_helm_precheck' \
  'tasks verify existing helm before download'
assert_contains "${TASKS}" 'Remove stale Helm install directory' \
  'tasks remove wrong-arch helm install dir'
