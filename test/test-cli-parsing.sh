#!/usr/bin/env bash
# Regression tests for top-level and fleet subcommand parsing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAP_DEMO_SH="${SCRIPT_DIR}/../aap-demo.sh"

config_test_dir=$(mktemp -d)
trap 'rm -rf "$config_test_dir"' EXIT

output=""
if output=$(AAP_DEMO_CONFIG="$config_test_dir/missing" QUIET=true "$AAP_DEMO_SH" version destroy 2>&1); then
  echo "FAIL: version accepted an extra top-level command"
  exit 1
fi

if ! grep -q "Unknown argument for 'version': destroy" <<<"$output"; then
  echo "FAIL: version destroy did not report the extra command"
  echo "$output"
  exit 1
fi

echo "PASS: destroy is only accepted as a fleet subcommand"

printf '%s\n' 'NAMESPACE=config-test' >"$config_test_dir/config"

if ! AAP_DEMO_CONFIG="$config_test_dir/config" QUIET=true "$AAP_DEMO_SH" version >/dev/null 2>&1; then
  echo "FAIL: config loading must work with the platform Bash version"
  exit 1
fi

echo "PASS: config loading works with the platform Bash version"
