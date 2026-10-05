"""``cluster/status.py``: ``aap-demo status`` data gathering (design §2.2).

``version_mod.version_info``/``remote_url`` are monkeypatched to a canned
value throughout — they have their own git-plumbing behavior (untested here
by design; that belongs to whatever exercises ``core/version.py`` directly)
and coupling every status test to whether this checkout has a ``.git`` would
test the wrong thing.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from aap_demo.cluster import status as status_mod
from aap_demo.core.console import RecordingConsole
from aap_demo.core.context import AppContext
from aap_demo.core.version import VersionInfo
from aap_demo.exec.runner import FakeRunner

FAKE_VERSION = VersionInfo(
    version="1.2.3",
    source="/src",
    install_mode="checkout",
    git_sha="abc1234",
    git_branch="main",
    git_date="2026-01-01T00:00:00+00:00",
    python="3.12.0",
    platform="Darwin arm64",
)


@pytest.fixture(autouse=True)
def _stub_version(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(status_mod.version_mod, "version_info", lambda runner: FAKE_VERSION)
    monkeypatch.setattr(status_mod.version_mod, "remote_url", lambda runner: "unknown")


def test_gather_reports_not_created_without_further_probing(
    app_ctx: AppContext, fake_runner: FakeRunner
) -> None:
    fake_runner.fail("crc status -o json")
    report = status_mod.gather(app_ctx)
    assert report.cluster_state == status_mod.infra_crc.STATE_NOT_CREATED
    assert report.cluster_name is None
    assert report.namespaces == []
    # No kubectl calls at all: bash returns immediately when not running.
    assert not fake_runner.called("kubectl")


def test_gather_reports_stopped_without_further_probing(
    app_ctx: AppContext, fake_runner: FakeRunner
) -> None:
    fake_runner.ok("crc status -o json", stdout='{"crcStatus": "Stopped"}')
    report = status_mod.gather(app_ctx)
    assert report.cluster_state == status_mod.infra_crc.STATE_STOPPED
    assert not fake_runner.called("kubectl")


def _register_running_cluster(fake_runner: FakeRunner) -> None:
    fake_runner.ok(
        "crc status -o json",
        stdout='{"crcStatus": "Running", "openshiftVersion": "4.21.0"}',
    )
    fake_runner.ok(
        "kubectl get ns --no-headers -o custom-columns=:metadata.name",
        stdout="aap\nopenshift-dns\nkube-system\ndefault\n",
    )
    fake_runner.ok(
        ["kubectl", "get", "pods", "-n", "aap", "--no-headers"],
        stdout=(
            "gateway-1  1/1  Running  0  1h\n"
            "gateway-2  1/1  Running  0  1h\n"
            "migrate-1  0/1  Completed  0  1h\n"
        ),
    )
    fake_runner.ok(["kubectl", "get", "aap", "-n", "aap", "--no-headers"], stdout="myaap  1  1h\n")
    fake_runner.ok(
        [
            "kubectl",
            "get",
            "aap",
            "myaap",
            "-n",
            "aap",
            "-o",
            'jsonpath={.status.conditions[?(@.type=="Successful")].status}',
        ],
        stdout="True",
    )
    fake_runner.ok(["kubectl", "get", "route", "-A", "--no-headers"], stdout="")
    fake_runner.ok(["kubectl", "get", "aap", "-A", "--no-headers"], stdout="aap  myaap  1  1h\n")
    fake_runner.ok(
        [
            "kubectl",
            "get",
            "aap",
            "-n",
            "aap",
            "-o",
            "jsonpath={.items[0].status.adminPasswordSecret}",
        ],
        stdout="myaap-admin-password",
    )
    fake_runner.ok(
        [
            "kubectl",
            "get",
            "secret",
            "-n",
            "aap",
            "myaap-admin-password",
            "-o",
            "jsonpath={.data.password}",
        ],
        stdout="c2VjcmV0",  # base64("secret")
    )
    fake_runner.fail(["kubectl", "get", "namespace", "automation-orchestrator"])
    fake_runner.ok(
        [
            "kubectl",
            "get",
            "csv",
            "-n",
            "aap-operator",
            "-o",
            "jsonpath={.items[0].metadata.name}",
        ],
        stdout="aap-operator.v2.7.0-0.1790279930",
    )
    fake_runner.ok(
        [
            "kubectl",
            "get",
            "aap",
            "-n",
            "aap-operator",
            "-o",
            "jsonpath={.items[0].status.version}",
        ],
        stdout="2.7.0",
    )


def test_gather_running_cluster_full_report(
    app_ctx: AppContext, fake_runner: FakeRunner, tmp_path: Path
) -> None:
    _register_running_cluster(fake_runner)
    # No CRC SSH key in this tmp home -> vm_info stays None; that path is
    # covered separately below.
    app_ctx.env = {"HOME": str(tmp_path)}

    report = status_mod.gather(app_ctx)

    assert report.cluster_state == status_mod.infra_crc.STATE_RUNNING
    assert report.cluster_name == "crc-microshift"
    assert report.cluster_version == "4.21.0"
    assert report.aap_version == "2.7.0"
    assert report.aap_csv == "aap-operator.v2.7.0-0.1790279930"
    assert report.tool_version == "1.2.3 (abc1234)"

    assert len(report.namespaces) == 1
    ns = report.namespaces[0]
    assert ns.name == "aap"
    assert ns.pods_total == 2  # "Completed" pod excluded
    assert ns.pods_running == 2
    assert ns.aap_name == "myaap"
    assert ns.aap_status == "healthy"

    assert len(report.credentials) == 1
    assert report.credentials[0] == status_mod.CredentialInfo(
        namespace="aap", username="admin", password="secret"
    )

    addon_names = {a.name: a.enabled for a in report.addons}
    assert addon_names["ao"] is False
    assert set(addon_names) == set(status_mod.AVAILABLE_ADDONS)


def test_gather_picks_up_vm_stats_when_ssh_key_present(
    app_ctx: AppContext, fake_runner: FakeRunner, tmp_path: Path
) -> None:
    _register_running_cluster(fake_runner)
    machines_dir = tmp_path / ".crc" / "machines" / "crc"
    machines_dir.mkdir(parents=True)
    (machines_dir / "id_ed25519").write_text("fake-key")
    app_ctx.env = {"HOME": str(tmp_path)}

    fake_runner.ok("ssh -p 2222", stdout="  OS:           RHEL 9\n  CPUs:         8\n")

    report = status_mod.gather(app_ctx)

    assert report.vm_info == "  OS:           RHEL 9\n  CPUs:         8"


def test_gather_marks_ao_enabled_from_config(
    app_ctx: AppContext, fake_runner: FakeRunner, tmp_path: Path
) -> None:
    _register_running_cluster(fake_runner)
    # "ao" is already in config, so _ao_credentials skips the namespace probe
    # and goes straight to the secret lookup (aap-demo.sh:1856-1862).
    fake_runner.ok(
        ["kubectl", "get", "secret", "-n", "automation-orchestrator", "-o", "name"], stdout=""
    )
    app_ctx.config.data.setdefault("addons", {})["enabled"] = ["ao"]
    # No CRC SSH key under this empty HOME -> gather() skips the VM-stats SSH
    # call entirely, rather than reaching for whatever real CRC install this
    # test happens to run next to.
    app_ctx.env = {"HOME": str(tmp_path)}

    report = status_mod.gather(app_ctx)

    addon_names = {a.name: a.enabled for a in report.addons}
    assert addon_names["ao"] is True
    # Config already says ao is enabled, so bash's namespace fallback check
    # for automation-orchestrator must not even run.
    assert not fake_runner.called("kubectl get namespace automation-orchestrator")


def test_gather_falls_back_to_ao_namespace_when_not_in_config(
    app_ctx: AppContext, fake_runner: FakeRunner, tmp_path: Path
) -> None:
    app_ctx.env = {"HOME": str(tmp_path)}
    fake_runner.ok("crc status -o json", stdout='{"crcStatus": "Running"}')
    fake_runner.ok("kubectl get ns --no-headers -o custom-columns=:metadata.name", stdout="")
    fake_runner.ok(["kubectl", "get", "route", "-A", "--no-headers"], stdout="")
    fake_runner.ok(["kubectl", "get", "aap", "-A", "--no-headers"], stdout="")
    fake_runner.ok(
        [
            "kubectl",
            "get",
            "csv",
            "-n",
            "aap-operator",
            "-o",
            "jsonpath={.items[0].metadata.name}",
        ],
        stdout="",
    )
    fake_runner.ok(
        [
            "kubectl",
            "get",
            "aap",
            "-n",
            "aap-operator",
            "-o",
            "jsonpath={.items[0].status.version}",
        ],
        stdout="",
    )
    fake_runner.ok(["kubectl", "get", "namespace", "automation-orchestrator"], stdout="")
    fake_runner.ok(
        ["kubectl", "get", "secret", "-n", "automation-orchestrator", "-o", "name"],
        stdout="secret/ao-admin-password\n",
    )
    fake_runner.ok(
        [
            "kubectl",
            "get",
            "secret/ao-admin-password",
            "-n",
            "automation-orchestrator",
            "-o",
            "jsonpath={.data.password}",
        ],
        stdout="c2VjcmV0",
    )

    report = status_mod.gather(app_ctx)

    addon_names = {a.name: a.enabled for a in report.addons}
    assert addon_names["ao"] is True
    assert any(c.namespace == "automation-orchestrator" for c in report.credentials)


def test_render_text_stopped_shows_start_hint(app_ctx: AppContext) -> None:
    report = status_mod.StatusReport(tool_version="1.0.0 (abc)", built="today")
    report.cluster_state = status_mod.infra_crc.STATE_STOPPED
    status_mod.render_text(app_ctx.console, report)
    assert "crc start" in app_ctx.console.stdout


def test_render_text_not_created_shows_create_hint(app_ctx: AppContext) -> None:
    report = status_mod.StatusReport(tool_version="1.0.0 (abc)", built="today")
    status_mod.render_text(app_ctx.console, report)
    assert "aap-demo create" in app_ctx.console.stdout


def test_render_text_running_lists_namespaces_and_credentials(app_ctx: AppContext) -> None:
    report = status_mod.StatusReport(tool_version="1.0.0 (abc)", built="today")
    report.cluster_state = status_mod.infra_crc.STATE_RUNNING
    report.cluster_name = "crc-microshift"
    report.kubeconfig = "/home/x/kubeconfig"
    report.namespaces = [
        status_mod.NamespaceInfo(
            name="aap", pods_running=2, pods_total=2, aap_name="myaap", aap_status="healthy"
        )
    ]
    report.credentials = [
        status_mod.CredentialInfo(namespace="aap", username="admin", password="secret")
    ]
    report.addons = [status_mod.AddonStatus(name="portal", enabled=True)]

    report.cluster_version = "4.21.0"
    report.aap_version = "2.7.0"
    report.aap_csv = "aap-operator.v2.7.0-0.1790279930"
    status_mod.render_text(app_ctx.console, report)

    out = app_ctx.console.stdout
    assert "MicroShift:  4.21.0" in out
    assert "AAP:         2.7.0" in out
    assert "CSV:         aap-operator.v2.7.0-0.1790279930" in out
    assert "Cluster:     running (crc-microshift)" in out
    assert "aap" in out
    assert "myaap" in out
    assert "admin / secret" in out
    assert "portal" in out
    assert "enabled" in out


def test_render_text_names_an_openshift_preset_cluster(app_ctx: AppContext) -> None:
    report = status_mod.StatusReport(tool_version="1.0.0 (abc)", built="today")
    report.cluster_state = status_mod.infra_crc.STATE_RUNNING
    report.cluster_name = "crc-openshift"
    report.cluster_version = "4.22.0"
    status_mod.render_text(app_ctx.console, report)
    assert "OpenShift:   4.22.0" in app_ctx.console.stdout


# -- output parity with bash's cmd_status printing -------------------------


def test_render_text_keeps_report_body_on_stdout_and_the_cluster_word_unglyphed(
    app_ctx: AppContext,
) -> None:
    """Bash's cluster line is ``Cluster:     <colored word>`` — no ✓/⚠/✗ — and
    every line of the report goes to stdout regardless of severity."""
    for state, word in (
        (status_mod.infra_crc.STATE_RUNNING, "running"),
        (status_mod.infra_crc.STATE_STOPPED, "stopped"),
        (status_mod.infra_crc.STATE_NOT_CREATED, "not running"),
    ):
        console = RecordingConsole()
        report = status_mod.StatusReport(tool_version="1.0.0 (abc)", built="today")
        report.cluster_state = state
        status_mod.render_text(console, report)
        assert f"Cluster:     {word}" in console.stdout_lines
        assert console.stderr == ""


def test_render_text_aligns_aap_and_plain_namespace_rows(app_ctx: AppContext) -> None:
    """A glyph prefix on the AAP row shifted bash's %-30s column two to the
    right relative to the plain rows next to it."""
    report = status_mod.StatusReport(tool_version="1.0.0 (abc)", built="today")
    report.cluster_state = status_mod.infra_crc.STATE_RUNNING
    report.namespaces = [
        status_mod.NamespaceInfo(
            name="aap", pods_running=2, pods_total=2, aap_name="myaap", aap_status="healthy"
        ),
        status_mod.NamespaceInfo(
            name="aap-deploying",
            pods_running=1,
            pods_total=2,
            aap_name="other",
            aap_status="deploying",
        ),
        status_mod.NamespaceInfo(name="nfs-storage", pods_running=1, pods_total=1),
    ]

    status_mod.render_text(app_ctx.console, report)

    rows = [line for line in app_ctx.console.stdout_lines if line.startswith("  aap")]
    rows += [line for line in app_ctx.console.stdout_lines if line.startswith("  nfs-storage")]
    assert rows == [
        f"  {'aap':<30} 2/2 pods   myaap",
        f"  {'aap-deploying':<30} 1/2 pods   other (Deploying)",
        f"  {'nfs-storage':<30} 1/1 pods",
    ]
    assert app_ctx.console.stderr == ""


def test_render_text_prints_source_even_when_unknown(app_ctx: AppContext) -> None:
    """Bash prints ``Source:`` unconditionally (aap-demo.sh:1731)."""
    report = status_mod.StatusReport(tool_version="1.0.0 (abc)", built="today")
    report.cluster_state = status_mod.infra_crc.STATE_RUNNING

    status_mod.render_text(app_ctx.console, report)

    assert any(line.startswith("Source:") for line in app_ctx.console.stdout_lines)


def test_render_text_tls_block_matches_bash(app_ctx: AppContext, fake_runner: FakeRunner) -> None:
    """``ingress_ca_trust_status`` prints *two* lines when nothing is saved,
    padded with %-18s (includes/ingress-ca-trust.sh:384-387)."""
    _register_running_cluster(fake_runner)
    app_ctx.env = {"HOME": str(app_ctx.paths.state_dir)}

    report = status_mod.gather(app_ctx)
    status_mod.render_text(app_ctx.console, report)

    assert "  Ingress CA file:   not saved" in app_ctx.console.stdout_lines
    assert (
        "  Browser trust:     unknown (run aap-demo deploy or create)"
        in app_ctx.console.stdout_lines
    )
