#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin"
cat >"$TEST_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$TEST_CURL_ARGS"
cat >"$TEST_CURL_CONFIG"
for argument in "$@"; do
  if [ "$argument" = "@/dev/fd/3" ]; then
    cat <&3 >"$TEST_CURL_PAYLOAD"
  fi
done
EOF
chmod +x "$TEST_DIR/bin/curl"

export PATH="$TEST_DIR/bin:$PATH"
export TEST_CURL_ARGS="$TEST_DIR/args"
export TEST_CURL_CONFIG="$TEST_DIR/config"
export TEST_CURL_PAYLOAD="$TEST_DIR/payload"

# shellcheck source=../includes/secure-curl.sh
source "${REPO_ROOT}/includes/secure-curl.sh"
curl -sk -u 'admin:password-fixture' \
  -H 'Authorization: Bearer token-fixture' \
  -H 'Content-Type: application/json' \
  -d '{"token":"body-fixture"}' \
  https://example.invalid/

if grep -q 'password-fixture\|token-fixture\|body-fixture' "$TEST_CURL_ARGS"; then
  echo "FAIL: secret was present in curl process arguments" >&2
  exit 1
fi
grep -q 'admin:password-fixture' "$TEST_CURL_CONFIG"
grep -q 'Authorization: Bearer token-fixture' "$TEST_CURL_CONFIG"
grep -q 'body-fixture' "$TEST_CURL_PAYLOAD"

: >"$TEST_CURL_ARGS"
: >"$TEST_CURL_PAYLOAD"
printf '%s' '{"subscriptions_username":"stdin-user","subscriptions_password":"stdin-password"}' |
  curl -sk -u 'admin:stdin-admin-password' \
    -H 'Content-Type: application/json' \
    --data-binary @- \
    https://example.invalid/
if grep -q 'stdin-user\|stdin-password\|stdin-admin-password' "$TEST_CURL_ARGS"; then
  echo "FAIL: stdin secret was present in curl process arguments" >&2
  exit 1
fi
grep -q 'subscriptions_username.*stdin-user' "$TEST_CURL_PAYLOAD"
grep -q 'subscriptions_password.*stdin-password' "$TEST_CURL_PAYLOAD"

if "${REPO_ROOT}/aap-demo.sh" status --show-secrets </dev/null >/dev/null 2>"$TEST_DIR/status-error"; then
  echo "FAIL: redirected status disclosed secrets" >&2
  exit 1
fi
grep -q 'requires an interactive terminal' "$TEST_DIR/status-error"

echo "PASS: secrets stay out of child argv and redirected status"
