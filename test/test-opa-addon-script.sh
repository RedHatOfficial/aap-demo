#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/test/test-opa-addon.sh"

grep -Fq 'curl --fail --silent --insecure "https://${AAP_ROUTE}/health"' "$script" \
  || {
    echo 'FAIL: OPA health check must use the host-reachable OpenShift route' >&2
    exit 1
  }

if grep -Fq '.svc.cluster.local:8181/health' "$script"; then
  echo 'FAIL: OPA health check must not use cluster-internal DNS from the host' >&2
  exit 1
fi

echo 'PASS: OPA addon test uses a host-reachable health endpoint'
