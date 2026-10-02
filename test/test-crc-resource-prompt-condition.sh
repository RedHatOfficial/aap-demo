#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aap-demo-resource-prompt.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/home/.aap-demo"

cat >"$TEST_DIR/bin/crc" <<'MOCK_CRC'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  "status --output json")
    printf '%s\n' '{"crcStatus":"Stopped","openshiftStatus":"Stopped"}'
    ;;
  "daemon" | "config set "*)
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
export AAP_DEMO_CONFIGURE_COREDNS_ONLY=1
export _INFRA_API_LOADED=""

# shellcheck source=../includes/crc-create.sh
source "$REPO_ROOT/includes/crc-create.sh"

CRC_STATUS=Stopped
if ! _crc_resource_prompt_needed; then
  echo "Expected missing CRC machine to use the interactive resource prompt path" >&2
  exit 1
fi

mkdir -p "$HOME/.crc/machines/crc"
: >"$HOME/.crc/machines/crc/.crc-exist"
if ! _crc_resource_prompt_needed; then
  echo "Expected existing stopped CRC machine to still use the interactive resource prompt path" >&2
  exit 1
fi

QUIET=true
if _crc_should_prompt_resources; then
  echo "Did not expect QUIET=true to use the interactive resource prompt path" >&2
  exit 1
fi

echo "CRC resource prompt condition test passed"
