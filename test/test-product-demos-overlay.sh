#!/usr/bin/env bash
# Regression checks for copying Product Demos overlay playbooks into AAP.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_SCRIPT="${ROOT_DIR}/addons/product-demos-base/lib.sh"

overlay_block=$(sed -n '/^apd_overlay_project_playbook()/,/^apd_register_project_playbooks()/p' "$LIB_SCRIPT")

if ! grep -Fq 'kubectl cp' <<<"$overlay_block"; then
  echo "FAIL: overlay copy must have a kubectl cp fallback" >&2
  exit 1
fi

if ! grep -Fq 'awx-manage shell -c' <<<"$overlay_block" || \
   ! grep -Fq 'sys.stdin.buffer.read' <<<"$overlay_block"; then
  echo "FAIL: overlay copy must have a controller-native Python fallback" >&2
  exit 1
fi

if ! grep -Fq 'Direct overlay copy failed' <<<"$overlay_block" || \
   ! grep -Fq 'kubectl cp fallback failed' <<<"$overlay_block"; then
  echo "FAIL: overlay copy failures must include actionable remote errors" >&2
  exit 1
fi

echo "PASS: product-demos overlay copy has a fallback and diagnostics"
