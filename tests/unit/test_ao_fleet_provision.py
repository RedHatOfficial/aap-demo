"""AO provisioning forwards the selected Fleet target to the AAP adapter."""

import os
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def run_provision(
    exit_code, missing_aap=False, missing_ao=False, service_ready=False, manual_ready=False
):
    source = (REPO / "addons/ao/deploy.sh").read_text()
    function = source.split("\nprovision_aap_demos() {", 1)[1].split("\n\nAO_PULL_SECRET_NAME=", 1)[
        0
    ]
    script = (
        """
set -e
NAMESPACE=ao AAP_NAMESPACE=aap SCRIPT_DIR=/addon
aap_gateway_route_host() { echo aap.example; }
wire_ao_route_host() { echo ao.example; }
wire_ao_login_token() { [ "${MOCK_MISSING_AO}" = 1 ] || echo token; }
wire_ao_find_credential_by_name() { echo credential; }
wire_ao_find_integration_by_name() { echo integration; }
wire_aap_gateway_token() { [ "${MOCK_MISSING_AAP}" = 1 ] || echo aap-token; }
ao_python_command() { echo capture; }
capture() {
  printf '<%s>\\n' "$@"
  local next=0 arg
  for arg in "$@"; do
    if [ "$next" = service ] && [ "$MOCK_SERVICE_READY" = 1 ]; then printf 'ready\\n' > "$arg"; fi
    if [ "$next" = manual ] && [ "$MOCK_MANUAL_READY" = 1 ]; then printf 'ready\\n' > "$arg"; fi
    case "$arg" in
      --fleet-service-status-file) next=service ;;
      --fleet-manual-status-file) next=manual ;;
      *) next=0 ;;
    esac
  done
  return "${MOCK_EXIT}"
}
WIRE_AAP_CREDENTIAL_NAME=a WIRE_AAP_INTEGRATION_NAME=b
AO_LLM_PROVIDER=none AO_AAP_SYNC_RAN=0
provision_aap_demos() {\n"""
        + function
        + "\nprovision_aap_demos\n"
    )
    return subprocess.run(
        ["bash", "-c", script],
        env={
            **os.environ,
            "AAP_DEMO_FLEET_HOST": "fleet-ubi9",
            "MOCK_EXIT": str(exit_code),
            "MOCK_MISSING_AAP": "1" if missing_aap else "0",
            "MOCK_MISSING_AO": "1" if missing_ao else "0",
            "MOCK_SERVICE_READY": "1" if service_ready else "0",
            "MOCK_MANUAL_READY": "1" if manual_ready else "0",
        },
        text=True,
        capture_output=True,
    )


def test_ao_provisioner_receives_selected_fleet_host():
    result = run_provision(0)
    assert result.returncode == 0
    assert "<--fleet-host>\n<fleet-ubi9>" in result.stdout
    assert "</addon/scripts/fleet-workflow.py>" in result.stdout


def test_ao_provisioning_failure_stops_fleet_setup():
    result = run_provision(1)
    assert result.returncode != 0


def test_missing_aap_credentials_stop_fleet_setup():
    result = run_provision(0, missing_aap=True)
    assert result.returncode != 0


def test_missing_ao_credentials_stop_fleet_setup():
    result = run_provision(0, missing_ao=True)
    assert result.returncode != 0


def test_service_workflow_is_enabled_only_if_its_template_was_created():
    assert "<--include-service>" in run_provision(0, service_ready=True).stdout
    assert "<--include-service>" not in run_provision(0, service_ready=False).stdout


def test_disk_workflow_readiness_is_independent_of_service_workflow():
    result = run_provision(0, service_ready=False, manual_ready=True)
    assert "<--include-disk-demo-101>" in result.stdout
    assert "<--include-service>" not in result.stdout
