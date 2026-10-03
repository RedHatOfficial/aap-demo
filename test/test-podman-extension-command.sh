#!/usr/bin/env bash
# Regression tests for the Podman Desktop extension helper command.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAP_DEMO_SH="${SCRIPT_DIR}/../aap-demo.sh"

help_output=$(QUIET=true "$AAP_DEMO_SH" help 2>&1)
if ! grep -q "podman-extension" <<<"$help_output"; then
  echo "FAIL: help does not document podman-extension"
  exit 1
fi

missing_dir="$(mktemp -d "${TMPDIR:-/tmp}/aap-demo-extension-test.XXXXXX")/missing"
trap 'rmdir "${missing_dir%/missing}"' EXIT

if output=$(AAP_DEMO_PODMAN_EXTENSION_DIR="$missing_dir" QUIET=true \
  "$AAP_DEMO_SH" podman-extension 2>&1); then
  echo "FAIL: podman-extension succeeded without an extension manifest"
  exit 1
fi

if ! grep -q "extension directory not found" <<<"$output"; then
  echo "FAIL: missing extension directory error was not actionable"
  echo "$output"
  exit 1
fi

if output=$(PATH=/usr/bin:/bin QUIET=true "$AAP_DEMO_SH" podman-extension 2>&1); then
  echo "FAIL: podman-extension succeeded without npm"
  exit 1
fi

if ! grep -q "npm is required" <<<"$output"; then
  echo "FAIL: missing npm error was not actionable"
  echo "$output"
  exit 1
fi

echo "PASS: Podman Desktop extension command parsing and prerequisite validation"
