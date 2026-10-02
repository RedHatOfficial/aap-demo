#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aap-demo-crc-linux-daemon.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/home/.aap-demo"

cat >"$TEST_DIR/bin/uname" <<'MOCK_UNAME'
#!/usr/bin/env bash
printf '%s\n' Linux
MOCK_UNAME
chmod +x "$TEST_DIR/bin/uname"

cat >"$TEST_DIR/bin/powershell.exe" <<'MOCK_POWERSHELL'
#!/usr/bin/env bash
printf 'powershell.exe should not be called on Linux\n' >&2
exit 2
MOCK_POWERSHELL
chmod +x "$TEST_DIR/bin/powershell.exe"

cat >"$TEST_DIR/bin/crc" <<'MOCK_CRC'
#!/usr/bin/env bash
set -euo pipefail
printf 'crc %s\n' "$*" >>"${AAP_DEMO_TEST_LOG:?}"

case "$*" in
  "daemon")
    ;;
  "status --output json")
    printf '%s\n' '{"crcStatus":"Stopped","openshiftStatus":"Stopped"}'
    ;;
  "config set "*)
    ;;
  "setup --show-progressbars")
    echo "crc setup should not run for a stopped Linux cluster solely because Windows daemon checks exist" >&2
    exit 2
    ;;
  *)
    echo "unexpected crc args: $*" >&2
    exit 2
    ;;
esac
MOCK_CRC
chmod +x "$TEST_DIR/bin/crc"

cat >"$TEST_DIR/bin/python3" <<'MOCK_PYTHON'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' Stopped
MOCK_PYTHON
chmod +x "$TEST_DIR/bin/python3"

export PATH="$TEST_DIR/bin:$PATH"
export HOME="$TEST_DIR/home"
export SCRIPT_DIR="$REPO_ROOT"
export AAP_DEMO_TEST_LOG="$TEST_DIR/calls.log"
export CRC_CPUS=8
export CRC_MEMORY=16384
export CRC_DISK=120
export CRC_PV_SIZE=70
export QUIET=true

if "$REPO_ROOT/includes/crc-create.sh" >/tmp/aap-demo-crc-create-linux-test.out 2>&1; then
  echo "Expected crc-create.sh to stop at missing pull secret" >&2
  exit 1
fi

if grep -q '^crc setup --show-progressbars$' "$AAP_DEMO_TEST_LOG"; then
  echo "crc setup unexpectedly ran on Linux daemon guard path" >&2
  cat "$AAP_DEMO_TEST_LOG" >&2
  exit 1
fi

echo "CRC create Linux daemon guard test passed"
