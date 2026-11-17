"""AO PostgreSQL storage selection against a stub Kubernetes API."""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

HELPER = Path(__file__).resolve().parents[2] / "addons/ao/lib/postgres-storage.sh"
DEPLOY = Path(__file__).resolve().parents[2] / "addons/ao/deploy.sh"
pytestmark = pytest.mark.skipif(
    sys.platform == "win32", reason="requires a POSIX shell and executable stub"
)


def _set(size):
    return json.dumps(
        {
            "spec": {
                "volumeClaimTemplates": [
                    {
                        "metadata": {"name": "data"},
                        "spec": {"resources": {"requests": {"storage": size}}},
                    }
                ]
            }
        }
    )


def _pvc(size):
    return json.dumps({"spec": {"resources": {"requests": {"storage": size}}}})


def _run(tmp_path, requested="3Gi", statefulset="", pvc="", fail=""):
    kubectl = tmp_path / "kubectl"
    kubectl.write_text(
        "#!/bin/bash\n"
        'if [ "$2" = "$FAIL_KIND" ]; then echo "API unavailable" >&2; exit 1; fi\n'
        'case "$2" in statefulset) printf "%s" "$STATEFULSET" ;; '
        'pvc) printf "%s" "$PVC" ;; *) exit 2 ;; esac\n',
        encoding="utf-8",
    )
    kubectl.chmod(0o755)
    return subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; ao_postgres_storage_size ao "$2"',
            "_",
            str(HELPER),
            requested,
        ],
        env={
            **os.environ,
            "PATH": f"{tmp_path}:{os.environ['PATH']}",
            "STATEFULSET": statefulset,
            "PVC": pvc,
            "FAIL_KIND": fail,
        },
        capture_output=True,
        text=True,
        check=False,
    )


@pytest.mark.parametrize(
    ("statefulset", "pvc", "requested", "expected"),
    [
        ("", "", "3Gi", "3Gi"),
        ("", "", "10Gi", "10Gi"),
        (_set("5Gi"), "", "3Gi", "5Gi"),
        (_set("5Gi"), _pvc("10Gi"), "10Gi", "5Gi"),
        ("", _pvc("5Gi"), "3Gi", "5Gi"),
        ("", "", "1.5Gi", "1.5Gi"),
    ],
)
def test_storage_selection(tmp_path, statefulset, pvc, requested, expected):
    result = _run(tmp_path, requested, statefulset, pvc)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == expected


@pytest.mark.parametrize(
    ("statefulset", "pvc", "requested", "fail"),
    [
        ("", "", "3Gi", "statefulset"),
        ("", "", "3Gi", "pvc"),
        ('{"spec":{}}', "", "3Gi", ""),
        ("", '{"spec":{}}', "3Gi", ""),
        ("not json", "", "3Gi", ""),
        ("", "", "3Gi|evil", ""),
        (_set("3Gi\nother: value"), "", "3Gi", ""),
    ],
)
def test_unreadable_or_invalid_size_fails_closed(tmp_path, statefulset, pvc, requested, fail):
    result = _run(tmp_path, requested, statefulset, pvc, fail)
    assert result.returncode != 0
    assert not result.stdout
    assert "ERROR:" in result.stderr


@pytest.mark.parametrize(
    ("crd", "cluster", "fail", "expected", "ok"),
    [
        ("", "", "", "", True),
        ("crd/clusters", "", "", "", True),
        (
            "crd/clusters",
            "cluster/orchestrator-postgres",
            "",
            "cluster/orchestrator-postgres",
            True,
        ),
        ("", "", "crd", "", False),
        ("crd/clusters", "", "cluster", "", False),
    ],
)
def test_cnpg_detection_distinguishes_missing_from_failed(
    tmp_path, crd, cluster, fail, expected, ok
):
    kubectl = tmp_path / "kubectl"
    kubectl.write_text(
        "#!/bin/bash\n"
        'kind="$2"; [ "$kind" = "clusters.postgresql.cnpg.io" ] && kind=cluster\n'
        'if [ "$kind" = "$FAIL_KIND" ]; then echo "API unavailable" >&2; exit 1; fi\n'
        'if [ "$kind" = crd ]; then printf "%s" "$CRD"; else printf "%s" "$CLUSTER"; fi\n',
        encoding="utf-8",
    )
    kubectl.chmod(0o755)
    result = subprocess.run(
        ["bash", "-c", 'source "$1"; ao_cnpg_cluster_name ao', "_", str(HELPER)],
        env={
            **os.environ,
            "PATH": f"{tmp_path}:{os.environ['PATH']}",
            "CRD": crd,
            "CLUSTER": cluster,
            "FAIL_KIND": fail,
        },
        capture_output=True,
        text=True,
        check=False,
    )
    assert (result.returncode == 0) is ok
    assert result.stdout == expected
    if not ok:
        assert "refusing to change" in result.stderr


@pytest.mark.parametrize(
    ("failure", "ok", "pvc_deleted"),
    [
        ("", True, True),
        ("crd", False, False),
        ("crd-disappeared", False, False),
        ("cluster-get", False, False),
        ("cluster-delete", False, False),
        ("cluster-stuck", False, False),
        ("database-crd", False, False),
        ("database-lookup", False, False),
        ("database-owner", False, False),
        ("database-delete", False, False),
        ("pvc-delete", False, True),
    ],
)
def test_cnpg_reset_fails_closed_before_replacement(tmp_path, failure, ok, pvc_deleted):
    kubectl = tmp_path / "kubectl"
    state = tmp_path / "cluster-present"
    state.touch()
    log = tmp_path / "calls"
    kubectl.write_text(
        "#!/bin/bash\n"
        'echo "$1 $2 $3" >> "$LOG"\n'
        'case "$1 $2 $3" in\n'
        '  "get crd clusters.postgresql.cnpg.io") '
        '[ "$FAIL" != crd ] || exit 1; '
        '[ "$FAIL" = crd-disappeared ] || echo crd/clusters ;;\n'
        '  "get crd databases.postgresql.cnpg.io") '
        '[ "$FAIL" != database-crd ] || exit 1; echo crd/databases ;;\n'
        '  "get clusters.postgresql.cnpg.io orchestrator-postgres") '
        '[ "$FAIL" != cluster-get ] || exit 1; '
        '[ ! -f "$STATE" ] || echo cluster/orchestrator-postgres ;;\n'
        '  "delete clusters.postgresql.cnpg.io orchestrator-postgres") '
        '[ "$FAIL" != cluster-delete ] || exit 1; '
        '[ "$FAIL" = cluster-stuck ] || rm -f "$STATE" ;;\n'
        '  "get database "*) '
        '[ "$FAIL" != database-lookup ] || exit 1; '
        '[ "$FAIL" != database-owner ] || [ "$3" != temporal ] || printf other-cluster; '
        '[ "$FAIL" = database-owner ] && [ "$3" = temporal ] || printf orchestrator-postgres ;;\n'
        '  "delete database "*) '
        '[ "$FAIL" != database-delete ] || exit 1 ;;\n'
        '  "delete pvc orchestrator-postgres-1") '
        '[ "$FAIL" != pvc-delete ] || exit 1 ;;\n'
        "  *) exit 2 ;;\nesac\n",
        encoding="utf-8",
    )
    kubectl.chmod(0o755)
    result = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; ao_remove_cnpg_storage ao cluster/orchestrator-postgres',
            "_",
            str(HELPER),
        ],
        env={
            **os.environ,
            "PATH": f"{tmp_path}:{os.environ['PATH']}",
            "FAIL": failure,
            "LOG": str(log),
            "STATE": str(state),
        },
        capture_output=True,
        text=True,
        check=False,
    )
    assert (result.returncode == 0) is ok, result.stderr
    assert ("delete pvc orchestrator-postgres-1" in log.read_text()) is pvc_deleted


@pytest.mark.parametrize(
    ("legacy", "force", "expected_reset", "expected_code"),
    [(True, "", False, 1), (True, "1", True, 0), (False, "", False, 0), (False, "1", True, 0)],
)
def test_legacy_credentials_never_reset_the_database_without_force(
    legacy, force, expected_reset, expected_code
):
    script = DEPLOY.read_text(encoding="utf-8")
    section = script.split('\n_legacy_secret=""\n', 1)[1].split(
        "\n# Reuse the existing password", 1
    )[0]
    result = subprocess.run(
        [
            "bash",
            "-c",
            'NAMESPACE=ao\nkubectl() { [ "$1" = get ] && [ "$LEGACY" = 1 ]; }\n'
            'reset_ao_postgres_storage() { echo reset; }\n_legacy_secret=""\n' + section,
        ],
        env={**os.environ, "FORCE": force, "LEGACY": "1" if legacy else "0"},
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == expected_code
    assert ("reset" in result.stdout) is expected_reset
    if legacy and not force:
        assert "refusing to reset" in result.stderr


@pytest.mark.parametrize(
    ("statefulset", "pvc", "requested", "fail", "expected"),
    [
        (_set("5Gi"), "", "3Gi", "", "5Gi"),
        ("", _pvc("5Gi"), "3Gi", "", "5Gi"),
        ("", "", "10Gi", "", "10Gi"),
        ("", "", "3Gi", "statefulset", None),
    ],
)
def test_apply_renders_selected_size_and_never_applies_after_lookup_failure(
    tmp_path, statefulset, pvc, requested, fail, expected
):
    kubectl = tmp_path / "kubectl"
    kubectl.write_text(
        "#!/bin/bash\n"
        'if [ "$1" = apply ]; then cat > "$APPLIED"; exit 0; fi\n'
        'if [ "$2" = "$FAIL_KIND" ]; then exit 1; fi\n'
        'case "$2" in statefulset) printf "%s" "$STATEFULSET" ;; '
        'pvc) printf "%s" "$PVC" ;; *) exit 2 ;; esac\n',
        encoding="utf-8",
    )
    kubectl.chmod(0o755)
    section = DEPLOY.read_text(encoding="utf-8").split("\napply_ao_postgres_manifest() {", 1)[1]
    section = section.split("\n# On an already-running AO:", 1)[0]
    applied = tmp_path / "manifest.yaml"
    code = (
        'set -euo pipefail\nsource "$1"\n'
        'ao_postgres_image() { echo "registry.example/postgres:15"; }\n'
        'short_image_ref() { echo "$1"; }\n'
        "NAMESPACE=ao POSTGRES_STORAGE_CLASS=block POSTGRES_IMAGE_FALLBACK=none\n"
        "apply_ao_postgres_manifest() {" + section + "\napply_ao_postgres_manifest\n"
    )
    result = subprocess.run(
        ["bash", "-c", code, "_", str(HELPER)],
        env={
            **os.environ,
            "PATH": f"{tmp_path}:{os.environ['PATH']}",
            "STATEFULSET": statefulset,
            "PVC": pvc,
            "FAIL_KIND": fail,
            "AO_STORAGE_SIZE": requested,
            "APPLIED": str(applied),
            "MANIFESTS_DIR": str(DEPLOY.parent / "manifests"),
        },
        capture_output=True,
        text=True,
        check=False,
    )
    if expected is None:
        assert result.returncode != 0
        assert not applied.exists()
    else:
        assert result.returncode == 0, result.stderr
        manifest = applied.read_text(encoding="utf-8")
        assert f"storage: {expected}" in manifest
        assert "__STORAGE_SIZE__" not in manifest


@pytest.mark.parametrize(
    ("cnpg", "expected"),
    [("cluster/orchestrator-postgres", ""), ("", "deploy\npostgres\n")],
)
def test_running_cnpg_install_does_not_apply_the_new_ao_or_postgres_manifests(cnpg, expected):
    script = DEPLOY.read_text(encoding="utf-8")
    section = script.split("\nreconcile_existing_ao() {", 1)[1].split(
        "\ncleanup_legacy_ea_resources() {", 1
    )[0]
    result = subprocess.run(
        [
            "bash",
            "-c",
            "set -eu\ndeploy_ao_instance() { echo deploy; }\n"
            "reconcile_ao_postgres() { echo postgres; }\n"
            "reconcile_existing_ao() {" + section + "\nreconcile_existing_ao\n",
        ],
        env={**os.environ, "_AO_CNPG_CLUSTER": cnpg},
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == expected


@pytest.mark.parametrize(
    ("size", "ok"), [("bad|value", False), ("0Gi", False), ("0.0", False), ("10Gi", True)]
)
def test_force_validates_requested_size_before_database_reset(size, ok):
    script = DEPLOY.read_text(encoding="utf-8")
    begin = script.index('\nif [ -n "$FORCE" ]; then\n  ao_validate_postgres_storage_size')
    end = script.index("\nAO_REPLICA_COUNT=", begin)
    preflight = script[begin:end]
    code = (
        'source "$1"\nao_cnpg_cluster_name() { echo cluster; }\nNAMESPACE=ao\n'
        + preflight
        + "\necho reset\n"
    )
    result = subprocess.run(
        ["bash", "-c", code, "_", str(HELPER)],
        env={**os.environ, "FORCE": "1", "AO_STORAGE_SIZE": size},
        capture_output=True,
        text=True,
        check=False,
    )
    assert (result.returncode == 0) is ok
    assert ("reset" in result.stdout) is ok
