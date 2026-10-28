#!/usr/bin/env bash
# Tests AAP version selection and deployment-profile validation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
VERSION_HELPER="${REPO_DIR}/includes/aap-version.sh"

if [ ! -f "$VERSION_HELPER" ]; then
  echo "FAIL: AAP version helper is missing"
  exit 1
fi

# shellcheck source=../includes/aap-version.sh
source "$VERSION_HELPER"

aap_demo_configure_aap_version 2.6
[ "$AAP_VERSION" = "2.6" ] || {
  echo "FAIL: 2.6 version selection"
  exit 1
}
[ "$AAP_CHANNEL" = "stable-2.6" ] || {
  echo "FAIL: 2.6 channel selection"
  exit 1
}
[ "$(bash -c 'printf "%s" "$AAP_VERSION"')" = "2.6" ] || {
  echo "FAIL: selected version is not exported"
  exit 1
}
echo "PASS: AAP 2.6 selects stable-2.6"

aap_demo_configure_aap_version 2.7
[ "$AAP_VERSION" = "2.7" ] || {
  echo "FAIL: 2.7 version selection"
  exit 1
}
[ "$AAP_CHANNEL" = "stable-2.7" ] || {
  echo "FAIL: 2.7 channel selection"
  exit 1
}
echo "PASS: AAP 2.7 selects stable-2.7"

if aap_demo_configure_aap_version 2.8 >/dev/null 2>&1; then
  echo "FAIL: unsupported AAP version accepted"
  exit 1
fi
echo "PASS: unsupported AAP version rejected"

config_file=$(mktemp)
printf '%s\n' 'AAP_VERSION=2.6' >"$config_file"
if ! env -u AAP_VERSION -u AAP_CHANNEL AAP_DEMO_CONFIG="$config_file" QUIET=true \
  "$REPO_DIR/aap-demo.sh" help 2>&1 | grep -q 'Deploy AAP 2.6'; then
  echo "FAIL: config file does not select AAP version"
  rm -f "$config_file"
  exit 1
fi
echo "PASS: config file selects AAP version"

printf '%s\n' '# command-line environment takes precedence' >"$config_file"
if ! AAP_VERSION=2.6 AAP_DEMO_CONFIG="$config_file" QUIET=true \
  "$REPO_DIR/aap-demo.sh" help 2>&1 | grep -q 'Deploy AAP 2.6'; then
  echo "FAIL: help does not reflect selected AAP version"
  rm -f "$config_file"
  exit 1
fi
echo "PASS: help reflects selected AAP version"

rm -f "$config_file"

config_file=$(mktemp)
invalid_output=$(mktemp)
if AAP_VERSION=2.8 AAP_DEMO_CONFIG="$config_file" QUIET=true \
  "$REPO_DIR/aap-demo.sh" deploy >"$invalid_output" 2>&1; then
  echo "FAIL: deploy accepted unsupported AAP version"
  rm -f "$invalid_output" "$config_file"
  exit 1
fi
if ! grep -q 'Unsupported AAP_VERSION' "$invalid_output"; then
  echo "FAIL: invalid version error missing"
  cat "$invalid_output" >&2
  rm -f "$invalid_output" "$config_file"
  exit 1
fi
rm -f "$invalid_output" "$config_file"
echo "PASS: invalid version fails before deploy"

if grep -q 'AAP_CHANNEL="stable-2.7"' "$REPO_DIR/aap-demo.sh"; then
  echo "FAIL: deploy path still hardcodes stable-2.7"
  exit 1
fi
if ! grep -q 'channel: \$AAP_CHANNEL' "$REPO_DIR/aap-demo.sh"; then
  echo "FAIL: Subscription does not use selected channel"
  exit 1
fi
if ! grep -q 'aap_demo_csv_matches_aap_version' "$REPO_DIR/aap-demo.sh"; then
  echo "FAIL: CSV selection is not version-aware"
  exit 1
fi
echo "PASS: deployment wiring uses selected version/channel"

rendered_subscription=$(sed -E \
  -e 's|namespace: aap|namespace: aap-operator|' \
  -e 's|channel: stable-2\.[0-9]+|channel: stable-2.6|' \
  "$REPO_DIR/config/olm/subscription.yaml")
if ! grep -q '^  channel: stable-2\.6$' <<<"$rendered_subscription"; then
  echo "FAIL: 2.6 Subscription rendering"
  exit 1
fi
echo "PASS: 2.6 Subscription renders stable-2.6"
