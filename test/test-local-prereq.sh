#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/home/.aap-demo" "$TEST_ROOT/bin" "$TEST_ROOT/work"
printf '{}\n' >"$TEST_ROOT/home/.aap-demo/pull-secret.txt"

cat >"$TEST_ROOT/bin/crc" <<'EOF'
#!/usr/bin/env bash
printf 'crc cwd=%s args=%s\n' "$PWD" "$*" >>"$TEST_LOG"
EOF

cat >"$TEST_ROOT/bin/groups" <<'EOF'
#!/usr/bin/env bash
echo "test-user libvirt"
EOF

cat >"$TEST_ROOT/fake-aap-demo" <<'EOF'
#!/usr/bin/env bash
printf 'cli cwd=%s args=%s skip_ao=%s quiet=%s\n' \
  "$PWD" "$*" "${AAP_DEMO_SKIP_STANDARD_AO:-false}" "${QUIET:-false}" >>"$TEST_LOG"
EOF

chmod +x "$TEST_ROOT/bin/crc" "$TEST_ROOT/bin/groups" "$TEST_ROOT/fake-aap-demo"

(
  cd "$TEST_ROOT/work"
  HOME="$TEST_ROOT/home" \
    PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
    TEST_LOG="$TEST_ROOT/calls.log" \
    AAP_DEMO_CLI="$TEST_ROOT/fake-aap-demo" \
    "$REPO_ROOT/scripts/local-prereq.sh" --deploy >/dev/null
)

grep -Fx "crc cwd=$REPO_ROOT args=config set preset microshift" "$TEST_ROOT/calls.log"
grep -Fx "crc cwd=$REPO_ROOT args=setup" "$TEST_ROOT/calls.log"
grep -Fx "cli cwd=$REPO_ROOT args=deploy skip_ao=false quiet=false" "$TEST_ROOT/calls.log"

echo "✓ local_prereq_runs_from_resolved_checkout"

mkdir -p "$TEST_ROOT/full-home/Downloads" "$TEST_ROOT/full-bin"
printf '{"auths":{}}\n' >"$TEST_ROOT/full-home/Downloads/pull-secret.txt"

cat >"$TEST_ROOT/full-bin/groups" <<'EOF'
#!/usr/bin/env bash
echo "test-user libvirt"
EOF

cat >"$TEST_ROOT/full-bin/curl" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    touch "$2"
    exit 0
  fi
  shift
done
exit 1
EOF

cat >"$TEST_ROOT/full-bin/tar" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-C" ]]; then
    mkdir -p "$2/crc-linux-test"
    cp "$TEST_CRC_BINARY" "$2/crc-linux-test/crc"
    exit 0
  fi
  shift
done
exit 1
EOF

cat >"$TEST_ROOT/fake-crc" <<'EOF'
#!/usr/bin/env bash
printf 'crc cwd=%s args=%s\n' "$PWD" "$*" >>"$TEST_LOG"
EOF

cat >"$TEST_ROOT/fake-installer" <<'EOF'
#!/usr/bin/env bash
printf 'installer cwd=%s args=%s\n' "$PWD" "$*" >>"$TEST_LOG"
EOF

chmod +x "$TEST_ROOT/full-bin/groups" "$TEST_ROOT/full-bin/curl" \
  "$TEST_ROOT/full-bin/tar" "$TEST_ROOT/fake-crc" "$TEST_ROOT/fake-installer"

(
  cd "$TEST_ROOT/work"
  HOME="$TEST_ROOT/full-home" \
    PATH="$TEST_ROOT/full-bin:/usr/bin:/bin" \
    TEST_LOG="$TEST_ROOT/full-calls.log" \
    TEST_CRC_BINARY="$TEST_ROOT/fake-crc" \
    AAP_DEMO_INSTALLER="$TEST_ROOT/fake-installer" \
    AAP_DEMO_CLI="$TEST_ROOT/fake-aap-demo" \
    "$REPO_ROOT/scripts/local-prereq.sh" --full >/dev/null
)

cat >"$TEST_ROOT/expected-full-calls.log" <<EOF
installer cwd=$REPO_ROOT args=
crc cwd=$REPO_ROOT args=config set preset microshift
crc cwd=$REPO_ROOT args=setup
cli cwd=$REPO_ROOT args=deploy skip_ao=true quiet=false
cli cwd=$REPO_ROOT args=enable mcp-server skip_ao=false quiet=true
cli cwd=$REPO_ROOT args=enable apme-eap skip_ao=false quiet=true
cli cwd=$REPO_ROOT args=enable product-demos skip_ao=false quiet=true
cli cwd=$REPO_ROOT args=enable ao skip_ao=false quiet=true
cli cwd=$REPO_ROOT args=status skip_ao=false quiet=false
EOF

cmp "$TEST_ROOT/expected-full-calls.log" "$TEST_ROOT/full-calls.log"
test "$(stat -c '%a' "$TEST_ROOT/full-home/.aap-demo/pull-secret.txt")" = "600"

echo "✓ local_prereq_full_bootstrap"