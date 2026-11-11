#!/usr/bin/env bash
# Regression tests for top-level and fleet subcommand parsing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAP_DEMO_SH="${SCRIPT_DIR}/../aap-demo.sh"
test_home=$(mktemp -d)
trap 'rm -rf "$test_home"' EXIT

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

if output=$(HOME="$test_home" QUIET=true "$AAP_DEMO_SH" fleet ssh ../1 2>&1); then
  echo "FAIL: Fleet SSH accepted an invalid node index"; exit 1
fi
grep -q 'Fleet SSH requires a node index' <<<"$output"
echo "PASS: fleet ssh remains a nested subcommand and validates its node index"

output=$(QUIET=true "$AAP_DEMO_SH" preflight 2>&1) || true
if ! grep -q "aap-demo preflight" <<<"$output"; then
  echo "FAIL: preflight was not recognized as a top-level command"
  echo "$output"
  exit 1
fi

echo "PASS: preflight is recognized as a top-level command"

if output=$(HOME="$test_home" QUIET=true "$AAP_DEMO_SH" fleet auth status 2>&1); then
  echo "FAIL: unconfigured fleet auth status unexpectedly succeeded"
  exit 1
fi
if ! grep -q "Red Hat Customer Portal authentication: not configured" <<<"$output"; then
  echo "FAIL: fleet auth status was not routed as a nested subcommand"
  echo "$output"
  exit 1
fi
if grep -q "AAP Demo Status" <<<"$output"; then
  echo "FAIL: fleet auth status was routed to top-level status"
  echo "$output"
  exit 1
fi

echo "PASS: fleet auth status remains a nested subcommand"

parser=$(sed -n '/^# Parse command line arguments/,/^# Load saved config/p' "$AAP_DEMO_SH")
if ! grep -A12 '^    fleet)' <<<"$parser" | grep -q 'COMMAND" = "enable"' \
  || grep -E 'enable .* wire .* fleet .* version' <<<"$parser" >/dev/null; then
  echo "FAIL: fleet is not parsed as an enable/disable addon argument"
  exit 1
fi

echo "PASS: enable fleet preserves enable as the top-level command"

if ! grep -A7 '^    start | ssh)' <<<"$parser" | grep -q 'COMMAND" = "fleet"'; then
  echo "FAIL: fleet start is not preserved as a nested subcommand"
  exit 1
fi

echo "PASS: fleet start remains a nested subcommand"

if output=$(QUIET=true "$AAP_DEMO_SH" version --json 2>&1); then
  echo "FAIL: version accepted the status/system-info --json option"
  exit 1
fi
if ! grep -q -- "--json is supported only by status and system-info" <<<"$output"; then
  echo "FAIL: invalid --json usage did not produce an actionable error"
  echo "$output"
  exit 1
fi

if output=$(QUIET=true "$AAP_DEMO_SH" system-info --output 2>&1); then
  echo "FAIL: system-info accepted --output without a path"
  exit 1
fi
if ! grep -q -- "--output requires a value" <<<"$output"; then
  echo "FAIL: missing --output value did not produce an actionable error"
  echo "$output"
  exit 1
fi

echo "PASS: structured-output options are validated"

help_output=$(QUIET=true "$AAP_DEMO_SH" --help)
for command in deploy status watch clean redeploy redeploy-all idle preflight diagnose \
  must-gather wire config redhat-status update version help create destroy stop start \
  repair setup ssh kubeconfig system-info dashboard maintenance; do
  if ! grep -Eq "^[[:space:]]+${command}([[:space:]|]|\$)" <<<"$help_output"; then
    echo "FAIL: --help is missing command: $command"
    exit 1
  fi
done
for addon in fleet mcp-server ao ollama setup-pah portal portal-operator apme-eap \
  product-demos product-demo-satellite opa local-cache; do
  if ! grep -Eq "^[[:space:]]+${addon}[[:space:]]" <<<"$help_output"; then
    echo "FAIL: --help is missing addon: $addon"
    exit 1
  fi
done
for text in \
  "fleet auth [configure|status|reset]" \
  "fleet add [count] --image <rhel9|rhel10|local-qcow2-path>" \
  "fleet register" \
  "fleet start" \
  "fleet ssh [index]" \
  "fleet rhc-connect" \
  "fleet list" \
  "fleet remove [count|name]" \
  "fleet destroy" \
  "--refresh-catalog" \
  "--purge-data" \
  "maintenance [--apply]" \
  "maintenance uninstall [--apply]" \
  "AAP_DEMO_UNINSTALL_CONFIRM=UNINSTALL" \
  "status --json" \
  "system-info [--redact] [--json] [--output FILE]" \
  "dashboard [--no-open]" \
  "create --full-demo" \
  "AO_LLM_PROVIDER=ollama|external|none" \
  "aap-demo fleet add 3 --image rhel9" \
  "aap-demo redeploy-all"; do
  if ! grep -Fq -- "$text" <<<"$help_output"; then
    echo "FAIL: --help is missing: $text"
    exit 1
  fi
done

echo "PASS: --help documents public commands, addons, options, and examples"

printf '%s\n' 'NAMESPACE=config-test' >"$config_test_dir/config"

if ! AAP_DEMO_CONFIG="$config_test_dir/config" QUIET=true "$AAP_DEMO_SH" version >/dev/null 2>&1; then
  echo "FAIL: config loading must work with the platform Bash version"
  exit 1
fi

echo "PASS: config loading works with the platform Bash version"
