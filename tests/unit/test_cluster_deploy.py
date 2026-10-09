"""``cluster/deploy.py`` and the phase-3 CLI commands.

The deploy path is long, so the fixture below registers a *whole healthy
deploy* and the individual tests break one thing each. That keeps every test
about the one failure it names, and it means a new step added to the
orchestration shows up as an unregistered-command assertion rather than as a
silently skipped stage.
"""

from __future__ import annotations

from typing import Optional

import pytest

from aap_demo.cli import lifecycle
from aap_demo.cluster import coredns
from aap_demo.cluster import deploy as deploy_mod
from aap_demo.core.errors import AapDemoError, ClusterUnreachableError
from aap_demo.exec.runner import CompletedCommand, FakeRunner

NS = "aap-operator"


class Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


def _which(*present: str):
    def which(name: str) -> Optional[str]:
        return f"/usr/bin/{name}" if name in present else None

    return which


@pytest.fixture
def healthy(app_ctx, tmp_path, monkeypatch) -> FakeRunner:
    """A runner that answers every call a successful deploy makes."""
    secret = tmp_path / "pull-secret.json"
    secret.write_text("{}")
    app_ctx.config.set("deploy.pull_secret_path", str(secret))
    app_ctx.env = {"HOME": str(tmp_path), "AAP_OCP_VERSION": "4.20"}
    monkeypatch.setattr("shutil.which", _which("kubectl", "oc", "operator-sdk"))

    runner = FakeRunner()
    runner.fail("mkcert")
    # Specific rules first: FakeRunner matches in registration order, so the
    # broad "kubectl get aap" below must not shadow the condition jsonpath.
    runner.ok(
        [
            "kubectl",
            "get",
            "aap",
            "-n",
            NS,
            "-o",
            'jsonpath={.items[0].status.conditions[?(@.type=="Successful")].status}',
        ],
        stdout="True",
    )
    runner.ok(
        ["kubectl", "get", "aap", "-n", NS, "-o", "jsonpath={.items[0].metadata.name}"],
        stdout="aap",
    )
    runner.ok(
        [
            "kubectl",
            "get",
            "aap",
            "-n",
            NS,
            "-o",
            "jsonpath={.items[0].status.adminPasswordSecret}",
        ],
        stdout="aap-admin-password",
    )
    runner.ok("kubectl cluster-info")
    runner.ok("kubectl config current-context", stdout="crc-admin")
    runner.ok(
        "crc status -o json",
        stdout='{"crcStatus": "Running", "openshiftVersion": "4.22.3"}',
    )
    # Real kubectl writes "No resources found" to *stderr*; stdout is empty.
    runner.ok("kubectl get aap", stdout="")
    runner.ok(["kubectl", "get", "crd"])
    runner.ok("operator-sdk olm status")
    runner.ok("crc status")
    runner.ok("kubectl get namespace")
    runner.ok("kubectl create namespace")
    runner.ok("oc adm policy add-scc-to-group")
    runner.ok("kubectl label namespace")
    runner.ok("kubectl delete secret")
    runner.ok("kubectl create secret")
    runner.ok("kubectl get serviceaccount")
    runner.ok("kubectl patch serviceaccount")
    runner.ok("kubectl patch aap")
    runner.ok(["kubectl", "get", "pods", "-n", NS, "-o", "json"], stdout='{"items":[]}')
    runner.ok("kubectl get configmap dns-default", stdout="rewrite router-internal-default")
    runner.ok("kubectl apply -f -")
    runner.ok("kubectl get catalogsource", stdout="READY")
    runner.ok(["kubectl", "get", "csv", "-n", NS, "-o"], stdout="aap-operator.v2.7.0")
    runner.ok("kubectl get csv", stdout="aap-operator.v2.7.0 AAP 2.7.0 Succeeded")
    runner.ok("kubectl wait")
    runner.ok("kubectl get sc")
    runner.ok("kubectl get deployment")
    runner.ok("kubectl get deploy", stdout="")
    runner.ok("kubectl patch deployment")
    runner.ok("kubectl get secret", stdout="czNjcmV0")
    runner.ok("kubectl get route", stdout="aap-aap-operator.apps.127.0.0.1.nip.io")
    app_ctx.runner = runner
    return runner


def _run(app_ctx, **kwargs):
    clock = Clock()
    return deploy_mod.run(app_ctx, sleep=clock.sleep, clock=clock, **kwargs)


def _wait_task(app_ctx):
    return next(task for task in app_ctx.console._tasks if task.title == "Waiting for AAP")


# ---------------------------------------------------------------------------
# Happy path and ordering
# ---------------------------------------------------------------------------


def test_healthy_deploy_reaches_a_ready_aap(app_ctx, healthy) -> None:
    result = _run(app_ctx, cr_name="controller")
    assert result.ready is True
    assert result.aap_name == "aap"
    assert result.csv == "aap-operator.v2.7.0"
    assert result.route == "aap-aap-operator.apps.127.0.0.1.nip.io"
    assert "AAP deployment successful" in app_ctx.console.stdout
    assert ("Waiting for AAP", "done") in app_ctx.console.task_states()
    assert _wait_task(app_ctx).note == "AAP is ready"


def test_deploy_order_is_bashs(app_ctx, healthy) -> None:
    """namespace → CoreDNS → CatalogSource → Subscription → CR."""
    _run(app_ctx, cr_name="controller")
    order = [
        healthy.index_of("kubectl create namespace"),
        healthy.index_of("oc adm policy add-scc-to-group anyuid"),
        healthy.index_of("kubectl get configmap dns-default"),
        healthy.index_of("kubectl get catalogsource"),
        healthy.index_of("kubectl get csv"),
    ]
    assert order == sorted(order)

    applies = [c for c in healthy.calls if c.argv[:2] == ("kubectl", "apply")]
    kinds = [
        next(line for line in (c.input or "").splitlines() if line.startswith("kind:"))
        for c in applies
    ]
    assert kinds == [
        "kind: CatalogSource",
        "kind: OperatorGroup",
        "kind: Subscription",
        # The pre-provisioned PVCs go in before the CR so the operator finds
        # them rather than creating its own on the cluster default class.
        "kind: PersistentVolumeClaim",
        "kind: AnsibleAutomationPlatform",
    ]


def test_controller_cr_needs_no_hub_storage(app_ctx, healthy) -> None:
    _run(app_ctx, cr_name="controller")
    cr = next(
        c.input for c in healthy.calls if "kind: AnsibleAutomationPlatform" in (c.input or "")
    )
    assert "route_host" not in cr
    assert "disabled: true" in cr


# ---------------------------------------------------------------------------
# Failure modes
# ---------------------------------------------------------------------------


def test_unreachable_cluster_fails_before_any_mutation(app_ctx, healthy) -> None:
    healthy._rules.insert(0, (("kubectl", "cluster-info"), CompletedCommand(argv=(), returncode=1)))
    with pytest.raises(ClusterUnreachableError):
        _run(app_ctx)
    assert not healthy.called("kubectl create namespace")


def test_existing_instance_short_circuits_unless_forced(app_ctx, healthy) -> None:
    listing = (
        ("kubectl", "get", "aap", "-n", NS),
        CompletedCommand(argv=(), returncode=0, stdout="NAME   STATUS\naap    Successful\n"),
    )
    # Behind the jsonpath rules, so those reads keep their own stdout.
    bare = next(
        i
        for i, (prefix, _result) in enumerate(healthy._rules)
        if prefix == ("kubectl", "get", "aap")
    )
    healthy._rules.insert(bare, listing)
    result = _run(app_ctx)
    assert result.skipped_existing is True
    assert result.aap_name == "aap"
    assert not healthy.called("kubectl create namespace")
    assert "already exists" in app_ctx.console.stdout
    assert ("Waiting for AAP", "done") in app_ctx.console.task_states()
    assert _wait_task(app_ctx).note == "AAP is ready"


def test_force_reinstalls_over_an_existing_instance(app_ctx, healthy) -> None:
    app_ctx.force = True
    result = _run(app_ctx, cr_name="controller")
    assert result.skipped_existing is False
    assert healthy.called("kubectl create namespace")


def test_catalog_timeout_names_the_describe_command(app_ctx, healthy) -> None:
    healthy._rules.insert(
        0, (("kubectl", "get", "catalogsource"), CompletedCommand(argv=(), returncode=0, stdout=""))
    )
    healthy.ok("kubectl get pods", stdout="Running")
    healthy.ok("kubectl get events", stdout="")
    app_ctx.env = {**app_ctx.env, "AAP_CATALOG_TIMEOUT": "10"}
    with pytest.raises(AapDemoError) as excinfo:
        _run(app_ctx, cr_name="controller")
    assert "CatalogSource not ready" in excinfo.value.message
    assert "kubectl describe pod" in (excinfo.value.hint or "")


def test_deploy_rejects_crc_older_than_the_minimum(app_ctx, healthy) -> None:
    healthy._rules.insert(
        0,
        (
            ("crc", "status", "-o", "json"),
            CompletedCommand(
                argv=(),
                returncode=0,
                stdout='{"crcStatus": "Running", "openshiftVersion": "4.20.1"}',
            ),
        ),
    )
    with pytest.raises(AapDemoError) as excinfo:
        _run(app_ctx, cr_name="controller")
    assert "CRC version check failed" in excinfo.value.message
    assert "too old" in app_ctx.console.stderr
    assert not healthy.called("kubectl create namespace")


def test_catalog_scc_admission_is_not_reported_as_a_timeout(app_ctx, healthy) -> None:
    healthy._rules.insert(
        0, (("kubectl", "get", "catalogsource"), CompletedCommand(argv=(), returncode=0, stdout=""))
    )
    healthy.ok(
        "kubectl get pods",
        stdout="unable to validate against any security context constraint",
    )
    healthy.ok("kubectl get events", stdout="")
    healthy.ok("kubectl get pod", stdout="")
    app_ctx.env = {**app_ctx.env, "AAP_CATALOG_TIMEOUT": "30"}
    with pytest.raises(AapDemoError) as excinfo:
        _run(app_ctx, cr_name="controller")
    assert "rejected by SCC admission" in excinfo.value.message
    assert "not ready after" not in excinfo.value.message


def test_missing_csv_after_ten_minutes_is_fatal(app_ctx, healthy) -> None:
    healthy._rules.insert(
        0, (("kubectl", "get", "csv"), CompletedCommand(argv=(), returncode=0, stdout=""))
    )
    with pytest.raises(AapDemoError) as excinfo:
        _run(app_ctx, cr_name="controller")
    assert "CSV not found" in excinfo.value.message


def test_csv_that_never_succeeds_warns_instead_of_passing_silently(app_ctx, healthy) -> None:
    """§14 R5: bash's ``kubectl wait … || true`` made this invisible."""
    healthy._rules.insert(0, (("kubectl", "wait"), CompletedCommand(argv=(), returncode=1)))
    result = _run(app_ctx, cr_name="controller")
    assert "not Succeeded" in " ".join(result.warnings)
    assert "did not reach Succeeded" in app_ctx.console.stderr


def test_aap_that_never_becomes_successful_is_reported_as_a_timeout(app_ctx, healthy) -> None:
    healthy._rules.insert(
        0,
        (
            ("kubectl", "get", "aap", "-n", NS, "-o"),
            CompletedCommand(argv=(), returncode=0, stdout="False"),
        ),
    )
    result = _run(app_ctx, cr_name="controller")
    assert result.ready is False
    assert "not complete after 60 minutes" in app_ctx.console.stderr
    assert ("Waiting for AAP", "done") in app_ctx.console.task_states()
    assert _wait_task(app_ctx).note == "AAP did not become ready"
    assert "Username: admin" in app_ctx.console.stdout
    assert "Password:" in app_ctx.console.stdout


def test_signature_relaxation_failure_is_a_warning_not_a_stop(app_ctx, healthy) -> None:
    app_ctx.env = {**app_ctx.env, "AAP_OCP_VERSION": "4.22"}
    app_ctx.config.set("crc.preset", "microshift")
    result = _run(app_ctx, cr_name="controller")
    assert "signature policy not relaxed" in result.warnings
    assert result.ready is True


def test_signature_relaxation_is_skipped_on_the_openshift_preset(app_ctx, healthy) -> None:
    app_ctx.env = {**app_ctx.env, "AAP_OCP_VERSION": "4.22"}
    app_ctx.config.set("crc.preset", "openshift")
    result = _run(app_ctx, cr_name="controller")
    assert result.warnings == []


# ---------------------------------------------------------------------------
# Disk space
# ---------------------------------------------------------------------------


@pytest.fixture
def ssh_key(app_ctx, tmp_path):
    machines = tmp_path / ".crc" / "machines" / "crc"
    machines.mkdir(parents=True)
    (machines / "id_ecdsa").write_text("key")
    app_ctx.env = {**app_ctx.env, "HOME": str(tmp_path)}


def test_disk_over_95_percent_stops_the_deploy(app_ctx, ssh_key) -> None:
    app_ctx.runner = FakeRunner().ok(["ssh"], stdout="97")
    assert deploy_mod.check_disk_space(app_ctx) is False
    assert "97% full" in app_ctx.console.stderr


def test_disk_over_80_percent_only_warns(app_ctx, ssh_key) -> None:
    app_ctx.runner = FakeRunner().ok(["ssh"], stdout="85")
    assert deploy_mod.check_disk_space(app_ctx) is True
    assert "85% full" in app_ctx.console.stderr


def test_unreadable_disk_figure_never_blocks_a_deploy(app_ctx, ssh_key) -> None:
    app_ctx.runner = FakeRunner().ok(["ssh"], stdout="not-a-number")
    assert deploy_mod.check_disk_space(app_ctx) is True


def test_no_ssh_key_never_blocks_a_deploy(app_ctx, tmp_path) -> None:
    app_ctx.env = {"HOME": str(tmp_path)}
    app_ctx.runner = FakeRunner()
    assert deploy_mod.check_disk_space(app_ctx) is True


# ---------------------------------------------------------------------------
# CoreDNS
# ---------------------------------------------------------------------------


def test_corefile_with_the_rewrite_needs_no_work() -> None:
    assert coredns.needs_configuration("rewrite ... router-internal-default ...") is False


def test_corefile_with_a_spliced_base_domain_is_malformed() -> None:
    assert coredns.needs_configuration("router-internal-default\n  baseDomain: crc.testing") is True


def test_corefile_without_the_rewrite_needs_configuring() -> None:
    assert coredns.needs_configuration(".:5353 { forward . /etc/resolv.conf }") is True


def test_verify_is_a_no_op_when_there_is_no_dns_configmap(app_ctx) -> None:
    runner = FakeRunner().fail("kubectl get configmap")
    app_ctx.runner = runner
    assert coredns.verify(app_ctx, sleep=lambda _s: None) is True
    assert not runner.called("kubectl patch")


def test_configure_repatches_when_the_dns_operator_clobbers_the_configmap(app_ctx, ssh_key) -> None:
    """R1: MicroShift's DNS controller overwrites the ConfigMap during startup."""
    reads = iter(["", "", "rewrite router-internal-default"])
    runner = FakeRunner()
    runner.ok(["ssh"], stdout="baseDomain: crc.testing")
    runner.register(
        "kubectl get configmap",
        lambda argv: CompletedCommand(argv=argv, returncode=0, stdout=next(reads, "")),
    )
    runner.ok("kubectl patch configmap")
    runner.ok("kubectl rollout")
    app_ctx.runner = runner

    assert coredns.configure(app_ctx, sleep=lambda _s: None) is True
    patches = [c for c in runner.calls if c.argv[:3] == ("kubectl", "patch", "configmap")]
    assert len(patches) == 2
    assert "re-patched" in app_ctx.console.stdout


def test_configure_gives_up_with_a_warning_after_two_attempts(app_ctx, ssh_key) -> None:
    runner = FakeRunner()
    runner.ok(["ssh"], stdout="baseDomain: crc.testing")
    runner.ok("kubectl get configmap", stdout="")
    runner.ok("kubectl patch configmap")
    runner.ok("kubectl rollout")
    app_ctx.runner = runner

    assert coredns.configure(app_ctx, sleep=lambda _s: None) is False
    assert "not persisting" in app_ctx.console.stderr


def test_configure_without_an_ssh_key_fails_loudly(app_ctx, tmp_path) -> None:
    app_ctx.env = {"HOME": str(tmp_path)}
    app_ctx.runner = FakeRunner()
    assert coredns.configure(app_ctx, sleep=lambda _s: None) is False
    assert "No CRC SSH key found" in app_ctx.console.stderr


def test_corefile_escapes_dots_but_not_hyphens() -> None:
    rendered = coredns.render_corefile("apps.my-crc.testing")
    assert "(.*)\\.apps\\.my-crc\\.testing" in rendered
    assert "(.*)\\.apps\\.127\\.0\\.0\\.1\\.nip\\.io" in rendered
    assert not rendered.endswith("\n")


def test_corefile_skips_the_second_rewrite_when_the_domain_is_nipio() -> None:
    rendered = coredns.render_corefile(coredns.NIPIO_ROUTE_DOMAIN)
    assert rendered.count("rewrite stop") == 1
    assert "\n\n    kubernetes " in rendered


def test_configure_skips_a_corefile_that_already_rewrites_nipio(app_ctx, ssh_key) -> None:
    runner = FakeRunner()
    runner.ok(["ssh"], stdout="baseDomain: crc.testing")
    runner.ok("kubectl get configmap", stdout=coredns.render_corefile("apps.crc.testing"))
    app_ctx.runner = runner

    assert coredns.configure(app_ctx, sleep=lambda _s: None) is True
    assert "already configured" in app_ctx.console.stdout
    assert not runner.called("kubectl patch")


def test_render_resolv_strips_the_nipio_search_zone() -> None:
    rendered = coredns.render_resolv(
        "# Generated by CRC\nsearch apps.127.0.0.1.nip.io crc.testing\nnameserver 192.168.127.1\n"
    )
    assert rendered == "search crc.testing\nnameserver 192.168.127.1\n"
    assert coredns.render_resolv(rendered) == rendered


def test_render_resolv_keeps_a_missing_nameserver_on_the_crc_default() -> None:
    rendered = coredns.render_resolv("search crc.testing\n")
    assert rendered == "search crc.testing\nnameserver 192.168.127.1\n"


def test_ensure_search_domain_rewrites_the_vm_resolv_conf(app_ctx, ssh_key) -> None:
    written: dict[str, str] = {}

    def ssh(argv: tuple) -> CompletedCommand:
        joined = " ".join(argv)
        if "tee /etc/resolv.conf" in joined:
            written["body"] = joined
            return CompletedCommand(argv=argv, returncode=0, stdout="")
        return CompletedCommand(
            argv=argv,
            returncode=0,
            stdout="search apps.127.0.0.1.nip.io crc.testing\nnameserver 192.168.127.1\n",
        )

    app_ctx.runner = FakeRunner().register("ssh", ssh)
    assert coredns.ensure_search_domain(app_ctx) is True
    assert "search crc.testing" in written["body"]
    assert "search apps.127.0.0.1.nip.io" not in written["body"]
    assert "192.168.127.1" in written["body"]
    assert "Pod DNS no longer searches apps.127.0.0.1.nip.io" in app_ctx.console.stdout


def test_ensure_search_domain_leaves_a_correct_file_alone(app_ctx, ssh_key) -> None:
    ready = "search crc.testing\nnameserver 192.168.127.1\n"
    app_ctx.runner = FakeRunner().ok("ssh", stdout=ready)
    assert coredns.ensure_search_domain(app_ctx) is True
    assert not any("tee /etc/resolv.conf" in command for command in app_ctx.runner.commands)


def test_verify_updates_pod_search_when_the_rewrite_is_already_present(app_ctx, ssh_key) -> None:
    runner = FakeRunner()
    runner.ok("kubectl get configmap", stdout=coredns.render_corefile("apps.crc.testing"))
    runner.ok("ssh", stdout="search apps.127.0.0.1.nip.io crc.testing\nnameserver 192.168.127.1\n")
    app_ctx.runner = runner
    assert coredns.verify(app_ctx, sleep=lambda _s: None) is True
    assert any("tee /etc/resolv.conf" in command for command in runner.commands)
    assert all("search apps.127.0.0.1.nip.io" not in command for command in runner.commands)


def test_configure_adds_the_nipio_rewrite_when_only_the_cluster_domain_is_covered(
    app_ctx, ssh_key
) -> None:
    stale = (
        "rewrite name regex (.*)\\.apps\\.crc\\.testing "
        "router-internal-default.openshift-ingress.svc"
    )
    reads = iter([stale, stale])
    runner = FakeRunner()
    runner.ok(["ssh"], stdout="baseDomain: crc.testing")
    runner.register(
        "kubectl get configmap",
        lambda argv: CompletedCommand(argv=argv, returncode=0, stdout=next(reads, stale)),
    )
    runner.ok("kubectl patch configmap")
    runner.ok("kubectl rollout")
    app_ctx.runner = runner

    assert coredns.configure(app_ctx, sleep=lambda _s: None) is True
    patches = [c for c in runner.calls if c.argv[:3] == ("kubectl", "patch", "configmap")]
    assert len(patches) == 1
    assert "nip\\\\." in patches[0].argv[-1]


# ---------------------------------------------------------------------------
# CLI commands
# ---------------------------------------------------------------------------


def test_setup_says_what_bash_says(app_ctx) -> None:
    assert lifecycle.setup(app_ctx, _args()) == 0
    assert app_ctx.console.stdout == "CRC setup is handled during 'aap-demo create'"


def test_clean_confirms_then_tears_down(app_ctx, monkeypatch, tmp_path) -> None:
    monkeypatch.setattr("shutil.which", _which("kubectl"))
    app_ctx.env = {"HOME": str(tmp_path)}  # no CRC SSH key -> no image prune
    runner = FakeRunner()
    runner.ok("kubectl config current-context", stdout="crc-admin")
    runner.ok("kubectl cluster-info", stdout="Kubernetes control plane is running at https://x")
    runner.ok("kubectl get aap", stdout="aap   Successful\n")
    runner.ok("kubectl get namespace")
    runner.ok("kubectl patch")
    runner.ok("kubectl delete")
    runner.ok("kubectl get pods")
    app_ctx.runner = runner

    waited = []
    lifecycle._clean(app_ctx, wait=waited.append)

    assert waited == [lifecycle.CLEAN_CONFIRM_SECONDS]
    assert "DESTRUCTIVE OPERATION" in app_ctx.console.stdout
    assert "    - aap" in app_ctx.console.stdout
    assert runner.called("kubectl delete namespace")


def test_clean_skips_the_confirmation_when_quiet(app_ctx, monkeypatch, tmp_path) -> None:
    monkeypatch.setattr("shutil.which", _which("kubectl"))
    app_ctx.env = {"HOME": str(tmp_path)}
    app_ctx.console.quiet = True
    runner = FakeRunner()
    runner.ok("kubectl config current-context")
    runner.ok("kubectl cluster-info")
    runner.ok("kubectl get aap", stdout="")
    runner.ok("kubectl get namespace")
    runner.ok("kubectl delete")
    runner.ok("kubectl get pods")
    app_ctx.runner = runner

    lifecycle._clean(app_ctx, wait=lambda _s: pytest.fail("must not wait when quiet"))


def test_deploy_command_succeeds_on_a_ready_aap(app_ctx, healthy) -> None:
    app_ctx.config.set("deploy.cr", "controller")
    assert lifecycle.deploy(app_ctx, _args()) == 0


@pytest.mark.parametrize(
    ("ready", "skipped", "expected"),
    [(True, False, 0), (False, True, 0), (False, False, 1)],
)
def test_deploy_command_exit_code_follows_readiness(
    app_ctx, monkeypatch, ready, skipped, expected
) -> None:
    """A CR that never reaches Successful is bash's ``return 1``, not a success."""
    monkeypatch.setattr(
        deploy_mod,
        "ensure_cluster_running",
        lambda ctx: "running",
    )
    monkeypatch.setattr(
        deploy_mod,
        "run",
        lambda ctx, **kw: deploy_mod.DeployResult(ready=ready, skipped_existing=skipped),
    )
    assert lifecycle.deploy(app_ctx, _args()) == expected


def test_deploy_refuses_when_no_cluster_exists(app_ctx) -> None:
    app_ctx.runner = FakeRunner().ok("crc status", stdout='{"crcStatus": "Unknown"}')
    with pytest.raises(ClusterUnreachableError) as excinfo:
        lifecycle.deploy(app_ctx, _args())
    assert "aap-demo create" in (excinfo.value.hint or "")


def test_deploy_refuses_when_the_cluster_is_stopped(app_ctx) -> None:
    app_ctx.runner = FakeRunner().ok("crc status", stdout='{"crcStatus": "Stopped"}')
    with pytest.raises(ClusterUnreachableError) as excinfo:
        lifecycle.deploy(app_ctx, _args())
    assert "crc start" in (excinfo.value.hint or "")


def _args():
    import argparse

    return argparse.Namespace()
