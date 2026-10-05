"""``cli/observe.py``: the ``status`` and ``diagnose`` command bodies (design §3.3)."""

from __future__ import annotations

import argparse
import json

import pytest

from aap_demo.cli import observe
from aap_demo.core.context import AppContext
from aap_demo.core.version import VersionInfo
from aap_demo.exec.runner import FakeRunner


@pytest.fixture(autouse=True)
def _stub_version(monkeypatch: pytest.MonkeyPatch) -> None:
    from aap_demo.cluster import status as status_mod

    fake_version = VersionInfo(
        version="1.2.3",
        source="/src",
        install_mode="checkout",
        git_sha="abc1234",
    )
    monkeypatch.setattr(status_mod.version_mod, "version_info", lambda runner: fake_version)
    monkeypatch.setattr(status_mod.version_mod, "remote_url", lambda runner: "unknown")


def _ns(**kwargs) -> argparse.Namespace:
    return argparse.Namespace(**kwargs)


# -- status -------------------------------------------------------------


def test_status_text_output_reports_not_created(
    app_ctx: AppContext, fake_runner: FakeRunner
) -> None:
    fake_runner.fail("crc status -o json")
    rc = observe.status(app_ctx, _ns())
    assert rc == 0
    # Report body is stdout whatever the severity — bash printed all of it
    # there, and splitting it across streams loses the ordering between the
    # state line and its "Start with" hint. Bash's cluster line also carries
    # no ✓/⚠/✗ glyph, just a colored word.
    assert "Cluster:     not running" in app_ctx.console.stdout
    assert "aap-demo create" in app_ctx.console.stdout
    assert app_ctx.console.stderr == ""


def test_status_json_output_is_well_formed(app_ctx: AppContext, fake_runner: FakeRunner) -> None:
    fake_runner.fail("crc status -o json")
    app_ctx.output = "json"
    rc = observe.status(app_ctx, _ns())
    assert rc == 0
    payload = json.loads(app_ctx.console.stdout)
    assert payload["cluster_state"] == "not_created"
    assert payload["tool_version"] == "1.2.3 (abc1234)"


# -- diagnose -------------------------------------------------------------


def test_diagnose_ai_requires_the_claude_cli(
    app_ctx: AppContext, fake_runner: FakeRunner, monkeypatch
) -> None:
    fake_runner.fail("crc status -o json")
    fake_runner.fail("kubectl cluster-info")
    monkeypatch.setattr("aap_demo.cluster.runtime.shutil.which", lambda _name: None)
    rc = observe.diagnose(app_ctx, _ns(ai=True))
    assert rc == 1
    assert "claude" in app_ctx.console.stderr


def test_diagnose_returns_1_when_cluster_unreachable(
    app_ctx: AppContext, fake_runner: FakeRunner
) -> None:
    fake_runner.fail("crc status -o json")
    fake_runner.fail("kubectl cluster-info")
    rc = observe.diagnose(app_ctx, _ns(ai=False))
    assert rc == 1
    assert "Cannot proceed without cluster connectivity" in app_ctx.console.stdout


def test_diagnose_returns_0_when_fully_healthy(
    app_ctx: AppContext, fake_runner: FakeRunner
) -> None:
    fake_runner.ok(
        "crc status -o json", stdout='{"crcStatus": "Running", "diskUse": 1, "diskSize": 100}'
    )
    fake_runner.ok("kubectl cluster-info", stdout="ok")
    fake_runner.fail(["kubectl", "get", "sc", "topolvm-provisioner"])
    fake_runner.fail(["kubectl", "get", "sc", "nfs-local-rwx"])
    fake_runner.fail(["kubectl", "get", "namespace", app_ctx.namespace])
    fake_runner.ok(["kubectl", "get", "clusterrolebinding", "-o", "wide"], stdout="")
    fake_runner.ok(
        [
            "kubectl",
            "get",
            "aap",
            "-n",
            app_ctx.namespace,
            "-o",
            "jsonpath={.items[0].metadata.name}",
        ],
        stdout="",
    )
    fake_runner.ok(["kubectl", "get", "pods", "-n", "openshift-dns", "--no-headers"], stdout="")

    rc = observe.diagnose(app_ctx, _ns(ai=False))

    # Missing storage classes and no namespace are warnings/info, not
    # failures, on a cluster that has never been deployed to.
    assert rc == 0


def test_diagnose_returns_0_when_issues_exist_but_the_cluster_is_reachable(
    app_ctx: AppContext, fake_runner: FakeRunner
) -> None:
    """Bash exits 1 only on lost connectivity (aap-demo.sh:1046); §3.4 keeps
    0/1/2 exactly as bash used them, so found issues still exit 0."""
    fake_runner.ok(
        "crc status -o json", stdout='{"crcStatus": "Running", "diskUse": 99, "diskSize": 100}'
    )
    fake_runner.ok("kubectl cluster-info", stdout="ok")
    fake_runner.fail(["kubectl", "get", "sc", "topolvm-provisioner"])
    fake_runner.fail(["kubectl", "get", "sc", "nfs-local-rwx"])
    fake_runner.fail(["kubectl", "get", "namespace", app_ctx.namespace])
    fake_runner.ok(["kubectl", "get", "clusterrolebinding", "-o", "wide"], stdout="")
    fake_runner.ok(
        [
            "kubectl",
            "get",
            "aap",
            "-n",
            app_ctx.namespace,
            "-o",
            "jsonpath={.items[0].metadata.name}",
        ],
        stdout="",
    )
    fake_runner.ok(["kubectl", "get", "pods", "-n", "openshift-dns", "--no-headers"], stdout="")

    rc = observe.diagnose(app_ctx, _ns(ai=False))

    assert rc == 0
    # Every report line — checks and summary — is stdout, and each check line
    # is indented two spaces under its section header, as bash printed them.
    assert "issue(s)" in app_ctx.console.stdout
    assert app_ctx.console.stderr == ""
    assert "  [x] Disk usage: 99% — critically low space" in app_ctx.console.stdout_lines
    assert "Storage:" in app_ctx.console.stdout_lines


def test_diagnose_json_output(app_ctx: AppContext, fake_runner: FakeRunner) -> None:
    fake_runner.fail("crc status -o json")
    fake_runner.fail("kubectl cluster-info")
    app_ctx.output = "json"

    rc = observe.diagnose(app_ctx, _ns(ai=False))

    assert rc == 1
    payload = json.loads(app_ctx.console.stdout)
    assert payload["cluster_reachable"] is False
