"""Tests for the AAP demo provisioning fast paths."""

from contextlib import redirect_stdout
import importlib.util
import io
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "addons/ao/scripts/provision-aap-demos.py"
SPEC = importlib.util.spec_from_file_location("provision_aap_demos", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def test_reuses_successfully_synced_project():
    api = object.__new__(MODULE.AAP)
    calls = []

    def request(path, method="GET", payload=None):
        calls.append((path, method))
        if path == "/projects/42/":
            return {"status": "successful"}
        if path == "/projects/42/playbooks/":
            return {"results": [{"name": "already-published.yml"}]}
        raise AssertionError(f"unexpected API call: {path} {method}")

    api.request = request
    api.wait_for_project_sync(42)

    assert calls == [
        ("/projects/42/", "GET"),
        ("/projects/42/playbooks/", "GET"),
    ]


def test_missing_license_message_includes_aap_address():
    output = io.StringIO()
    with redirect_stdout(output):
        MODULE.report_missing_license("aap.example.test")

    assert output.getvalue().splitlines() == [
        "WARNING: AAP does not have a registered subscription.",
        "  Please log into AAP at https://aap.example.test and register a subscription.",
    ]
    assert MODULE.EXIT_LICENSE_REQUIRED == 2


if __name__ == "__main__":
    test_reuses_successfully_synced_project()
    test_missing_license_message_includes_aap_address()
    print("AAP provisioning tests passed")
