#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${1:-${AAP_DEMO_PODMAN_EXTENSION_IMAGE:-localhost/aap-demo-podman-extension:dev}}"
CONTAINERFILE="${SCRIPT_DIR}/Containerfile"

if ! command -v podman &>/dev/null; then
  printf 'ERROR: podman is required to build the Podman Desktop extension image\n' >&2
  printf 'Install Podman, then rerun: %s [image-name]\n' "$0" >&2
  exit 1
fi

if [ ! -f "$CONTAINERFILE" ]; then
  printf 'ERROR: Containerfile not found: %s\n' "$CONTAINERFILE" >&2
  exit 1
fi

echo "Building Podman Desktop extension image: ${IMAGE}"
podman build --file "$CONTAINERFILE" --tag "$IMAGE" "$SCRIPT_DIR"

echo "✓ Podman Desktop extension image built"
echo "  OCI image: ${IMAGE}"
echo ""
echo "To install it in Podman Desktop:"
echo "  1. Open Extensions → Install custom..."
echo "  2. Enter: ${IMAGE}"
echo "  3. Select Install, then confirm it is active."
