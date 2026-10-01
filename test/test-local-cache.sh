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
CACHE_CATALOG_REF='registry.redhat.io/redhat/redhat-operator-index@sha256:cafebabe'
CACHE_CATALOG_KEY=$(printf '%s\n' "$CACHE_CATALOG_REF" | md5sum | awk '{print $1}')
printf '%s\n' 'registry.redhat.io/stale/image@sha256:stale' >"${CACHE_DIR}/stale.ref"
printf 'Copying blob sha256:stale\n' >"${CACHE_DIR}/stale.tar"
printf 'test-key\n' >"$MOCK_HOME/.crc/machines/crc/id_ed25519"

ARCHIVE_DIR="${TEST_DIR}/archive"
mkdir -p "$ARCHIVE_DIR"
printf '%s\n' '{"imageLayoutVersion":"1.0.0"}' >"$ARCHIVE_DIR/oci-layout"
mkdir -p "$ARCHIVE_DIR/blobs/sha256"
printf '%s\n' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}' \
  >"$ARCHIVE_DIR/index.json"
export MOCK_ARCHIVE_DIR="$ARCHIVE_DIR"
tar -cf "${CACHE_DIR}/stale-valid.tar" -C "$ARCHIVE_DIR" oci-layout index.json blobs
printf '%s\n' 'registry.redhat.io/stale/valid@sha256:stale' >"${CACHE_DIR}/stale-valid.ref"

cat >"${MOCK_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_SSH_LOG}"
case "$*" in
  *"crictl images -o json"*)
    printf '%s\n' '{"images":[{"repoDigests":["registry.redhat.io/example/image@sha256:deadbeef"],"size":123},{"repoTags":["registry.redhat.io/redhat/redhat-operator-index:v4.22"],"repoDigests":["registry.redhat.io/redhat/redhat-operator-index@sha256:cafebabe"],"size":456}]}'
    ;;
  *"crictl inspecti"*)
    [ "${MOCK_INSPECT_RESULT:-fail}" = success ]
    ;;
  *"containers-storage:"*"oci-archive:"*)
    [ "${MOCK_EXPORT_RESULT:-success}" = success ] || exit 1
    tar -cf - -C "$MOCK_ARCHIVE_DIR" oci-layout index.json blobs
    ;;
  *"oci-archive:"*"containers-storage:"*)
    tar -tf - >/dev/null 2>&1 || exit 1
    [ "${MOCK_IMPORT_RESULT:-success}" = success ]
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
export MOCK_SSH_LOG="${TEST_DIR}/ssh.log"

if ! "$CACHE_SCRIPT" save >"${TEST_DIR}/save.out" 2>&1; then
  echo "✗ cache save should complete with a successful image export" >&2
  cat "${TEST_DIR}/save.out" >&2
  exit 1
fi
if ! tar -tf "${CACHE_DIR}/${CACHE_KEY}.tar" >/dev/null 2>&1; then
  echo "✗ cache save must write a valid OCI archive" >&2
  exit 1
fi
echo "✓ cache save repairs an invalid OCI archive"
if [ ! -s "${CACHE_DIR}/${CACHE_KEY}.local-ref" ] || [[ "$(cat "${CACHE_DIR}/${CACHE_KEY}.local-ref")" != *@sha256:* ]]; then
  echo "✗ cache save should record the archive's local platform digest" >&2
  exit 1
fi
echo "✓ cache save records the local platform digest"
if [ ! -s "${CACHE_DIR}/catalog-digests" ] \
  || ! grep -q '^4\.22[[:space:]]' "${CACHE_DIR}/catalog-digests" 2>/dev/null; then
  echo "✗ cache save should record the catalog digest for the OCP version" >&2
  exit 1
fi
echo "✓ cache save records the operator catalog digest"
if [ -e "${CACHE_DIR}/stale.tar" ] || [ -e "${CACHE_DIR}/stale.ref" ] \
  || [ -e "${CACHE_DIR}/stale-valid.tar" ] || [ -e "${CACHE_DIR}/stale-valid.ref" ]; then
  echo "✗ cache save should remove stale entries" >&2
  exit 1
fi
echo "✓ cache save removes stale entries"

export MOCK_INSPECT_RESULT=success
if ! "$CACHE_SCRIPT" load >/dev/null 2>&1; then
  echo "✗ valid cached OCI archives should load successfully" >&2
  exit 1
fi
echo "✓ valid cached OCI archives load successfully"

export MOCK_INSPECT_RESULT=success
catalog_ref=$($CACHE_SCRIPT catalog-ref 4.22 2>/dev/null || true)
if [[ "$catalog_ref" != *@sha256:* ]]; then
  echo "✗ catalog-ref should return the loaded local catalog digest" >&2
  exit 1
fi
echo "✓ catalog-ref returns the loaded local catalog digest"

if ! grep -q -- '--quiet --remove-signatures containers-storage:' "$MOCK_SSH_LOG" \
  || ! grep -q -- 'oci-archive:' "$MOCK_SSH_LOG"; then
  echo "✗ cache save should export from containers-storage to oci-archive without signatures" >&2
  exit 1
fi
echo "✓ cache save exports from containers-storage to oci-archive without signatures"

export MOCK_IMPORT_RESULT=fail
export MOCK_INSPECT_RESULT=fail
if "$CACHE_SCRIPT" load >/dev/null 2>&1; then
  echo "✗ digest-preserving cache load should fail when an image import fails" >&2
  exit 1
fi
if ! grep -q -- '--all --preserve-digests oci-archive:' "$MOCK_SSH_LOG"; then
  echo "✗ cache load should preserve digest references" >&2
  exit 1
fi
if [ -e "${CACHE_DIR}/${CACHE_KEY}.tar" ] || [ -e "${CACHE_DIR}/${CACHE_KEY}.ref" ] \
  || [ -e "${CACHE_DIR}/${CACHE_KEY}.local-ref" ]; then
  echo "✗ failed cache imports should evict the invalid cache entry" >&2
  exit 1
fi
echo "✓ digest-preserving cache load reports failed imports"

if ! AAP_DEMO_LOCAL_CACHE_QUIET=1 "$CACHE_SCRIPT" load >/dev/null 2>&1; then
  echo "✗ quiet cache load should remain non-fatal for deploy optimization" >&2
  exit 1
fi
echo "✓ quiet cache load remains non-fatal"

export MOCK_EXPORT_RESULT=fail
rm -f "${CACHE_DIR}/.format-version"
if "$CACHE_SCRIPT" save >/dev/null 2>&1; then
  echo "✗ cache save should fail when an image export fails" >&2
  exit 1
fi
echo "✓ cache save reports failed image exports"

# A stale local digest must not be rewritten into live workloads. The original
# registry digest remains pullable, while the cached digest may no longer exist.
REWRITE_REF='registry.redhat.io/example/gateway@sha256:original'
REWRITE_KEY=$(printf '%s\n' "$REWRITE_REF" | md5sum | awk '{print $1}')
printf '%s\n' "$REWRITE_REF" >"${CACHE_DIR}/${REWRITE_KEY}.ref"
printf '%s\n' 'registry.redhat.io/example/gateway@sha256:stale-local' \
  >"${CACHE_DIR}/${REWRITE_KEY}.local-ref"
export MOCK_REWRITE_REF="$REWRITE_REF"
export MOCK_PATCH_LOG="${TEST_DIR}/patch.log"
cat >"${MOCK_BIN}/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "get deployments,statefulsets,daemonsets,jobs,cronjobs -A -o json")
    printf '%s\n' "{\"items\":[{\"kind\":\"Deployment\",\"metadata\":{\"namespace\":\"aap-operator\",\"name\":\"aap-gateway-operator\"},\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"image\":\"${MOCK_CURRENT_IMAGE:-${MOCK_REWRITE_REF}}\",\"imagePullPolicy\":\"Always\"}]}}}}]}"
    ;;
  "get catalogsources -A -o json")
    printf '%s\n' '{"items":[]}'
    ;;
  "get csv -A -o json")
    printf '%s\n' "{\"items\":[{\"metadata\":{\"namespace\":\"aap-operator\",\"name\":\"aap-operator.v2.7.0\"},\"spec\":{\"install\":{\"spec\":{\"deployments\":[{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"image\":\"${MOCK_CURRENT_IMAGE:-${MOCK_REWRITE_REF}}\",\"imagePullPolicy\":\"Always\"}]}}}}]}}}}]}"
    ;;
  patch*)
    printf '%s\n' "$*" >>"${MOCK_PATCH_LOG}"
    ;;
esac
EOF
chmod +x "${MOCK_BIN}/kubectl"
export MOCK_INSPECT_RESULT=fail
rewrite_output=$($CACHE_SCRIPT rewrite 2>&1)
if [ -s "$MOCK_PATCH_LOG" ]; then
  echo "✗ stale cached digests must not rewrite live workloads" >&2
  echo "$rewrite_output" >&2
  exit 1
fi
echo "✓ stale cached digests are skipped during workload rewrite"

export MOCK_INSPECT_RESULT=success
: >"${MOCK_PATCH_LOG}"
rewrite_output=$($CACHE_SCRIPT rewrite 2>&1)
if ! grep -q 'IfNotPresent' "$MOCK_PATCH_LOG"; then
  echo "✗ cached workload rewrites must disable unconditional registry pulls" >&2
  echo "$rewrite_output" >&2
  exit 1
fi
echo "✓ cached workload rewrites use IfNotPresent"

export MOCK_CURRENT_IMAGE='registry.redhat.io/example/gateway@sha256:stale-local'
: >"${MOCK_PATCH_LOG}"
rewrite_output=$($CACHE_SCRIPT rewrite 2>&1)
if ! grep -q 'IfNotPresent' "$MOCK_PATCH_LOG"; then
  echo "✗ cached workload rewrites must repair already-rewritten workloads" >&2
  echo "$rewrite_output" >&2
  exit 1
fi
echo "✓ cached workload rewrites are idempotent"
if ! grep -q '/spec/install/spec/deployments' "$MOCK_PATCH_LOG"; then
  echo "✗ cached rewrites must update the CSV install strategy" >&2
  exit 1
fi
echo "✓ cached rewrites update the CSV source of truth"
