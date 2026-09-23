#!/usr/bin/env bash
# Regression tests for local-cache archive integrity and load result handling.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CACHE_SCRIPT="${REPO_ROOT}/addons/local-cache/deploy.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

MOCK_BIN="${TEST_DIR}/bin"
MOCK_HOME="${TEST_DIR}/home"
CACHE_DIR="${MOCK_HOME}/.aap-demo/local-cache/microshift"
mkdir -p "$MOCK_BIN" "$CACHE_DIR" "$MOCK_HOME/.crc/machines/crc"

CACHE_REF='registry.redhat.io/example/image@sha256:deadbeef'
CACHE_KEY=$(printf '%s\n' "$CACHE_REF" | md5sum | awk '{print $1}')
printf '%s\n' "$CACHE_REF" >"${CACHE_DIR}/${CACHE_KEY}.ref"
printf 'Copying blob sha256:deadbeef\n' >"${CACHE_DIR}/${CACHE_KEY}.tar"
printf '%s\n' 'registry.redhat.io/stale/image@sha256:stale' >"${CACHE_DIR}/stale.ref"
printf 'Copying blob sha256:stale\n' >"${CACHE_DIR}/stale.tar"
printf 'test-key\n' >"$MOCK_HOME/.crc/machines/crc/id_ed25519"

ARCHIVE_DIR="${TEST_DIR}/archive"
mkdir -p "$ARCHIVE_DIR"
printf '[{"Config":"config.json","RepoTags":[],"Layers":[]}]\n' \
  >"$ARCHIVE_DIR/manifest.json"
export MOCK_ARCHIVE_DIR="$ARCHIVE_DIR"
tar -cf "${CACHE_DIR}/stale-valid.tar" -C "$ARCHIVE_DIR" manifest.json
printf '%s\n' 'registry.redhat.io/stale/valid@sha256:stale' >"${CACHE_DIR}/stale-valid.ref"

cat >"${MOCK_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"crictl images -o json"*)
    printf '%s\n' '{"images":[{"repoDigests":["registry.redhat.io/example/image@sha256:deadbeef"],"size":123}]}'
    ;;
  *"crictl inspecti"*)
    exit 1
    ;;
  *"docker-archive:/dev/stdout"*)
    if [[ "$*" != *" --remove-signatures "* ]]; then
      exit 1
    fi
    if [[ "$*" != *" --quiet "* ]]; then
      printf 'Copying blob sha256:deadbeef\n'
    fi
    tar -cf - -C "$MOCK_ARCHIVE_DIR" manifest.json
    ;;
  *"docker-archive:/dev/stdin"*)
    tar -tf - >/dev/null 2>&1 || exit 1
    if [[ "$*" == *"aap-demo-cache-"* ]]; then
      [ "${MOCK_FALLBACK_RESULT:-success}" = success ]
    else
      [ "${MOCK_IMPORT_RESULT:-success}" = success ]
    fi
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "${MOCK_BIN}/ssh"

cat >"${MOCK_BIN}/crc" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  config\ get\ preset) printf '%s\n' 'microshift' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "${MOCK_BIN}/crc"

export HOME="$MOCK_HOME"
export PATH="$MOCK_BIN:$PATH"
export CRC_SSH_PORT=2222

if ! "$CACHE_SCRIPT" save >"${TEST_DIR}/save.out" 2>&1; then
  echo "✗ cache save should complete with a successful image export" >&2
  cat "${TEST_DIR}/save.out" >&2
  exit 1
fi
if ! tar -tf "${CACHE_DIR}/${CACHE_KEY}.tar" >/dev/null 2>&1; then
  echo "✗ cache save must write a valid Docker archive" >&2
  exit 1
fi
echo "✓ cache save repairs an invalid Docker archive"
if [ -e "${CACHE_DIR}/stale.tar" ] || [ -e "${CACHE_DIR}/stale.ref" ] \
  || [ -e "${CACHE_DIR}/stale-valid.tar" ] || [ -e "${CACHE_DIR}/stale-valid.ref" ]; then
  echo "✗ cache save should remove stale entries" >&2
  exit 1
fi
echo "✓ cache save removes stale entries"

if ! "$CACHE_SCRIPT" load >/dev/null 2>&1; then
  echo "✗ valid cached Docker archives should load successfully" >&2
  exit 1
fi
echo "✓ valid cached Docker archives load successfully"

export MOCK_IMPORT_RESULT=fail
export MOCK_FALLBACK_RESULT=success
if ! "$CACHE_SCRIPT" load >/dev/null 2>&1; then
  echo "✗ digest-mismatched cache imports should fall back to a cache tag" >&2
  exit 1
fi
echo "✓ digest-mismatched cache imports fall back to a cache tag"

export MOCK_FALLBACK_RESULT=fail
if "$CACHE_SCRIPT" load >/dev/null 2>&1; then
  echo "✗ explicit cache load should fail when an image import fails" >&2
  exit 1
fi
echo "✓ explicit cache load reports failed imports"

if ! AAP_DEMO_LOCAL_CACHE_QUIET=1 "$CACHE_SCRIPT" load >/dev/null 2>&1; then
  echo "✗ quiet cache load should remain non-fatal for deploy optimization" >&2
  exit 1
fi
echo "✓ quiet cache load remains non-fatal"
