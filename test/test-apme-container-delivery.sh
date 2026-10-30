#!/usr/bin/env bash
# Verify that APME plugin delivery is container-based and sourced externally.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADDON="$ROOT/addons/apme-eap"
PLAYBOOK="$ADDON/playbooks/deploy_apme_portal.yml"
IMAGE_BUILD="$ADDON/playbooks/roles/apme_image_build/tasks/main.yml"
DEFAULTS="$ADDON/defaults.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if find "$ADDON/plugin_packs" -type f -name '*.tar.gz' -print -quit | grep -q .; then
  fail "plugin tarballs must not be checked into aap-demo"
fi

if grep -q 'apme_oci_push' "$PLAYBOOK"; then
  fail "deploy playbook must not push a plugin archive to the cluster"
fi

if test -e "$ADDON/scripts/push_oci_archive.py"; then
  fail "runtime OCI archive publisher must be removed"
fi

grep -q 'ansible/ansible-rhdh-plugins' "$DEFAULTS" \
  || fail "external plugin source repository must be configurable"
grep -q 'fetch-plugin-artifact.sh' "$IMAGE_BUILD" \
  || fail "local image builds must resolve the external artifact"
grep -q 'APME_ARTIFACT_NAME' "$IMAGE_BUILD" \
  || fail "local image builds must support an exact upstream artifact name"
grep -q 'Containerfile.ci' "$IMAGE_BUILD" \
  || fail "local image builds must bake the normalized artifact into a container"

echo "OK: APME container delivery contract"
