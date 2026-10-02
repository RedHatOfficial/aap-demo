#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aap-demo-crc-daemon-setup.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/home/.aap-demo"

cat >"$TEST_DIR/bin/uname" <<'MOCK_UNAME'
#!/usr/bin/env bash
printf '%s\n' MINGW64_NT-10.0
MOCK_UNAME
chmod +x "$TEST_DIR/bin/uname"

cat >"$TEST_DIR/bin/powershell.exe" <<'MOCK_POWERSHELL'
#!/usr/bin/env bash
printf 'powershell.exe %s\n' "$*" >>"${AAP_DEMO_TEST_LOG:?}"
exit 1
MOCK_POWERSHELL
chmod +x "$TEST_DIR/bin/powershell.exe"

cat >"$TEST_DIR/bin/crc" <<'MOCK_CRC'
#!/usr/bin/env bash
set -euo pipefail
printf 'crc %s\n' "$*" >>"${AAP_DEMO_TEST_LOG:?}"

case "$*" in
  "status --output json")
    printf '%s\n' '{"crcStatus":"Stopped","openshiftStatus":"Stopped"}'
    ;;
  "config set "*)
    ;;
  "setup --show-progressbars")
    printf 'level=info msg="setup complete"\n'
    ;;
  *)
    echo "unexpected crc args: $*" >&2
    exit 2
    ;;
esac
MOCK_CRC
chmod +x "$TEST_DIR/bin/crc"

export PATH="$TEST_DIR/bin:$PATH"
export HOME="$TEST_DIR/home"
export SCRIPT_DIR="$REPO_ROOT"
export AAP_DEMO_TEST_LOG="$TEST_DIR/calls.log"
export CRC_CPUS=8
export CRC_MEMORY=16384
export CRC_DISK=120
export CRC_PV_SIZE=70
export QUIET=true

if "$REPO_ROOT/includes/crc-create.sh" >/tmp/aap-demo-crc-create-test.out 2>&1; then
  echo "Expected crc-create.sh to stop at missing pull secret" >&2
  exit 1
fi

if ! grep -q '^crc setup --show-progressbars$' "$AAP_DEMO_TEST_LOG"; then
  echo "Expected crc setup to run when Windows crcDaemon task is missing" >&2
  echo "Calls:" >&2
  cat "$AAP_DEMO_TEST_LOG" >&2
  exit 1
fi

echo "CRC create Windows daemon setup test passed"
