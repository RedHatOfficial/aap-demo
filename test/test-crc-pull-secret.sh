#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/runtime"

cat >"$TEST_DIR/bin/crc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[ "$1" = start ]
[ "$2" = --pull-secret-file ]
secret_file="$3"
[ -f "$secret_file" ]
[ "$(stat -c '%a' "$secret_file")" = 600 ]
[ "$(cat "$secret_file")" = "$EXPECTED_PULL_SECRET" ]
printf '%s\n' "$secret_file" >"$SECRET_PATH_LOG"
echo "mock CRC start succeeded"
EOF
chmod +x "$TEST_DIR/bin/crc"

export PATH="$TEST_DIR/bin:$PATH"
export XDG_RUNTIME_DIR="$TEST_DIR/runtime"
export EXPECTED_PULL_SECRET='{"auths":{"example.invalid":{"auth":"test"}}}'
export SECRET_PATH_LOG="$TEST_DIR/secret-path"
export PULL_SECRET_VALUE="$EXPECTED_PULL_SECRET"
export AAP_DEMO_CONFIGURE_COREDNS_ONLY=1
export _INFRA_API_LOADED=""
unset SCRIPT_DIR

# shellcheck source=../includes/crc-create.sh
source "$REPO_ROOT/includes/crc-create.sh"

output=$(_crc_start_with_pull_secret "$TEST_DIR/crc-start.log")
grep -Fq 'mock CRC start succeeded' <<<"$output"
secret_path=$(cat "$SECRET_PATH_LOG")
[ ! -e "$secret_path" ]
if grep -Fq -- '--pull-secret-file -' "$REPO_ROOT/includes/crc-create.sh"; then
  echo "FAIL: CRC pull secret still uses unsupported stdin path" >&2
  exit 1
fi

echo "PASS: CRC receives a mode-0600 ephemeral pull-secret file that is removed"
