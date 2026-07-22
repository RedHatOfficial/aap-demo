#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Configuration
IMAGE_NAME="${IMAGE_NAME:-localhost/apme-ee}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

echo "======================================"
echo "Building APME Execution Environment"
echo "======================================"
echo "Image: ${FULL_IMAGE}"
echo ""

# Check prerequisites
if ! command -v ansible-builder &> /dev/null; then
    echo "❌ ansible-builder not found. Install with: pip install ansible-builder"
    echo ""
    echo "Falling back to direct podman build..."

    if ! command -v podman &> /dev/null; then
        echo "❌ podman not found either. Install podman or ansible-builder."
        exit 1
    fi

    echo "Building with podman..."
    podman build -f Containerfile -t "${FULL_IMAGE}" .
else
    echo "Building with ansible-builder..."
    ansible-builder build \
        --tag "${FULL_IMAGE}" \
        --container-runtime podman \
        --verbosity 3
fi

echo ""
echo "✅ Build complete!"
echo ""
echo "Verify the build:"
echo "  podman run -it --rm ${FULL_IMAGE} /bin/bash -c 'oc version --client && skopeo --version'"
echo ""
echo "Push to registry:"
echo "  podman push ${FULL_IMAGE} quay.io/YOUR_ORG/apme-ee:latest"
echo ""
echo "Or push to OpenShift internal registry:"
echo "  podman tag ${FULL_IMAGE} image-registry.openshift-image-registry.svc:5000/aap-operator/apme-ee:latest"
echo "  podman push image-registry.openshift-image-registry.svc:5000/aap-operator/apme-ee:latest"
