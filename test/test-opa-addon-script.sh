#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/test/test-opa-addon.sh"

grep -Fq 'OPA_ROUTE="$(kubectl get route opa -n "$NAMESPACE" -o jsonpath=' "$script" \
  || {
    echo 'FAIL: OPA health check must resolve the OPA route' >&2
    exit 1
  }

grep -Fq 'curl --fail --silent --insecure "https://${OPA_ROUTE}/health"' "$script" \
  || {
    echo 'FAIL: OPA health check must use the host-reachable OpenShift route' >&2
    exit 1
  }

grep -Fq '"https://${AAP_ROUTE}/api/controller/v2/job_templates/?name=${encoded}"' "$script" \
  || {
    echo 'FAIL: AAP template lookups must continue to use the AAP route' >&2
    exit 1
  }

if grep -Fq '.svc.cluster.local:8181/health' "$script"; then
  echo 'FAIL: OPA health check must not use cluster-internal DNS from the host' >&2
  exit 1
fi

echo 'PASS: OPA addon test uses a host-reachable health endpoint'
