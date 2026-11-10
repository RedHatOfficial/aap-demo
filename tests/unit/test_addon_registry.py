"""The addon registry, the ``Addon`` protocol, and the shared building blocks (ADR-040)."""

from __future__ import annotations

import ast
import json
from pathlib import Path

import pytest
import yaml

from aap_demo.addons import get, names, needs_cluster, registry
from aap_demo.addons.base import Addon
from aap_demo.addons.common import playbook_job
from aap_demo.core.errors import AddonError
from aap_demo.exec.runner import FakeRunner

COMMON = Path(__file__).resolve().parents[2] / "src" / "aap_demo" / "addons" / "common"


def test_every_registered_addon_meets_the_protocol() -> None:
    for name, addon in registry().items():
        assert isinstance(addon, Addon), name
        assert addon.name == name
        assert addon.kind in ("native", "legacy")
        assert isinstance(addon.public, bool)
        assert isinstance(addon.needs_cluster, bool)


def test_kinds_and_listed_names() -> None:
    assert get("fleet").kind == "native"
    assert get("product-demos").kind == "legacy"
    assert names() == ["fleet", "product-demo-satellite", "product-demos"]
    # A domain installer is enabled by name but not listed.
    assert get("product-demo-linux").public is False


def test_get_returns_the_registered_instance() -> None:
    assert get("product-demos") is get("product-demos")


@pytest.mark.parametrize("name", [None, "", "portal"])
def test_needs_cluster_is_false_for_no_name_or_an_unknown_one(name) -> None:
    assert needs_cluster(name) is False


def test_unknown_addon_lists_what_is_implemented() -> None:
    with pytest.raises(AddonError, match="implemented addons: fleet, product-demo-satellite"):
        get("portal")


def test_common_does_not_import_any_one_addon() -> None:
    """``addons/common`` stays generic: no imports from fleet, shell, or the registry."""
    for path in sorted(COMMON.glob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.module:
                module = node.module
            elif isinstance(node, ast.Import):
                module = node.names[0].name
            else:
                continue
            if module.startswith("aap_demo.addons"):
                assert module.startswith("aap_demo.addons.common"), f"{path.name}: {module}"


def _job_runner() -> FakeRunner:
    runner = FakeRunner()
    runner.ok(["kubectl", "get", "secrets"], stdout=json.dumps({"items": []}))
    runner.ok(["kubectl", "apply"])
    runner.ok(
        ["kubectl", "get", "job"],
        stdout=json.dumps({"status": {"conditions": [{"type": "Complete", "status": "True"}]}}),
    )
    runner.ok(["kubectl", "delete"])
    return runner


def _job(**overrides) -> playbook_job.PlaybookJob:
    values = dict(
        label="Demo",
        name="aap-demo-demo-install-0001",
        namespace="demo-runner",
        image="registry.example/ee:1",
        playbook="install.yml",
        purpose="installing the demo",
        files={"install.yml": "- hosts: localhost\n"},
        extra_vars={"state": "present"},
        mount_root="/opt/demo",
        grants=(("demo-a", "demo-role"), ("demo-b", "demo-role")),
        pull_secret_source="aap-operator",  # pragma: allowlist secret
    )
    values.update(overrides)
    return playbook_job.PlaybookJob(**values)


def test_playbook_job_binds_and_cleans_up_every_grant(app_ctx, monkeypatch) -> None:
    app_ctx.runner = _job_runner()
    progress: list = []
    monkeypatch.setattr(app_ctx.console, "progress", progress.append)

    playbook_job.run(app_ctx, _job())

    applied = [
        document
        for call in app_ctx.runner.calls
        if call.argv[:2] == ("kubectl", "apply") and call.input
        for document in yaml.safe_load_all(call.input)
    ]
    bindings = [d for d in applied if d["kind"] == "RoleBinding"]
    assert {(b["metadata"]["namespace"], b["roleRef"]["name"]) for b in bindings} == {
        ("demo-runner", "aap-demo-demo-install-0001"),
        ("demo-a", "demo-role"),
        ("demo-b", "demo-role"),
    }
    job = next(d for d in applied if d["kind"] == "Job")
    container = job["spec"]["template"]["spec"]["containers"][0]
    assert container["command"][1] == "/opt/demo/playbooks/install.yml"
    assert "hostAliases" not in job["spec"]["template"]["spec"]
    deletes = [call.argv for call in app_ctx.runner.calls if call.argv[:2] == ("kubectl", "delete")]
    assert ("-n", "demo-a") == deletes[1][-3:-1]
    assert ("-n", "demo-b") == deletes[2][-3:-1]
    assert progress[0] == "Submitting Demo job: installing the demo"


def test_playbook_job_failure_keeps_the_logs_and_still_cleans_up(app_ctx) -> None:
    runner = FakeRunner()
    runner.ok(["kubectl", "get", "secrets"], stdout=json.dumps({"items": []}))
    runner.ok(["kubectl", "apply"])
    runner.ok(
        ["kubectl", "get", "job"],
        stdout=json.dumps({"status": {"conditions": [{"type": "Failed", "status": "True"}]}}),
    )
    runner.ok(["kubectl", "logs"], stdout="TASK failed")
    runner.fail(["kubectl", "delete", "rolebinding"], stderr="forbidden")
    runner.ok(["kubectl", "delete"])
    app_ctx.runner = runner

    with pytest.raises(AddonError, match="playbook failed: install.yml") as excinfo:
        playbook_job.run(app_ctx, _job())

    hint = excinfo.value.hint or ""
    assert "TASK failed" in hint
    assert hint.count("forbidden") == 2
    assert sum(1 for c in runner.calls if c.argv[:2] == ("kubectl", "delete")) == 3
