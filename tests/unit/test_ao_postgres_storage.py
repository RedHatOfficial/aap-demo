"""Exercise the AO storage-size selection with a stub Kubernetes API."""

import os
import subprocess
import sys
from pathlib import Path

import pytest

HELPER = Path(__file__).resolve().parents[2] / "addons/ao/lib/postgres-storage.sh"
pytestmark = pytest.mark.skipif(
    sys.platform == "win32", reason="requires a POSIX shell and executable stub"
)


@pytest.mark.parametrize(
    ("existing", "requested", "expected"),
    [("", "3Gi", "3Gi"), ("", "10Gi", "10Gi"), ("5Gi", "3Gi", "5Gi"), ("5Gi", "10Gi", "5Gi")],
)
def test_storage_size_selection(tmp_path, existing, requested, expected):
    kubectl = tmp_path / "kubectl"
    kubectl.write_text('#!/bin/bash\nprintf "%s" "$EXISTING_SIZE"\n', encoding="utf-8")
    kubectl.chmod(0o755)
    result = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; ao_postgres_storage_size ao "$2"',
            "_",
            str(HELPER),
            requested,
        ],
        env={**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "EXISTING_SIZE": existing},
        capture_output=True,
        text=True,
        check=True,
    )
    assert result.stdout.strip() == expected


def test_lookup_failure_stops_before_selecting_a_size(tmp_path):
    kubectl = tmp_path / "kubectl"
    kubectl.write_text('#!/bin/bash\necho "API unavailable" >&2\nexit 1\n', encoding="utf-8")
    kubectl.chmod(0o755)
    result = subprocess.run(
        ["bash", "-c", 'source "$1"; ao_postgres_storage_size ao 3Gi', "_", str(HELPER)],
        env={**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}"},
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0
    assert not result.stdout
    assert "API unavailable" in result.stderr
    assert "refusing to apply" in result.stderr
