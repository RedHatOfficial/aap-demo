"""MicroShift create and destroy over FakeRunner."""

from __future__ import annotations

from pathlib import Path

from aap_demo.cluster import bootstrap
from aap_demo.core.errors import AapDemoError
from aap_demo.exec.runner import CompletedCommand, FakeRunner
from aap_demo.infra.crc import managed_crc_release

KUBECONFIG = """\
apiVersion: v1
kind: Config
clusters:
- name: microshift
  cluster:
    server: https://127.0.0.1:6443
contexts:
- name: microshift
  context:
    cluster: microshift
    user: user
users:
- name: user
  user:
    token: token
"""


def _ssh(argv):
    text = "ok"
    joined = " ".join(argv)
    if "kubeconfig" in joined:
        text = KUBECONFIG
    elif "echo configured" in joined:
        text = "configured\n"
    return CompletedCommand(argv=tuple(argv), returncode=0, stdout=text)


def _status(argv):
    del argv
    body = '{"crcStatus": "Running", "openshiftStatus": "Running"}'
    return CompletedCommand(argv=(), returncode=0, stdout=body)


def _crc_version_text(microshift: str, crc_release: str | None = None) -> str:
    release = crc_release or managed_crc_release()
    return (
        f"CRC version: {release}+abc\nOpenShift version: 4.22.7\nMicroShift version: {microshift}\n"
    )


def _prepare(
    app_ctx,
    tmp_path: Path,
    *,
    first_status: str,
    microshift: str = "4.22.0",
    version=None,
) -> FakeRunner:
    home = tmp_path / "home"
    keydir = home / ".crc" / "machines" / "crc"
    keydir.mkdir(parents=True)
    (keydir / "id_ecdsa").write_text("key")
    secret = tmp_path / "pull-secret.txt"
    secret.write_text("{}\n")
    app_ctx.env = {"HOME": str(home), "AAP_DEMO_CRC_STABILITY_ATTEMPTS": "5"}
    app_ctx.config.set("deploy.pull_secret_path", str(secret))
    app_ctx.assume_yes = True

    calls = {"n": 0}

    def status(argv):
        calls["n"] += 1
        if calls["n"] == 1:
            body = first_status
        else:
            body = '{"crcStatus": "Running", "openshiftStatus": "Running"}'
        return CompletedCommand(argv=tuple(argv), returncode=0, stdout=body)

    runner = FakeRunner()
    runner.fail("mkcert")
    runner.register("crc status -o json", status)
    if version is None:
        runner.ok("crc version", stdout=_crc_version_text(microshift))
    else:
        runner.register("crc version", version)
    runner.ok("crc")
    runner.register("ssh", _ssh)
    runner.ok("kubectl get configmap", stdout="router-internal-default nip.io")
    runner.ok("kubectl get sc nfs-local-rwx")
    runner.ok("kubectl get deployment metrics-server")
    runner.ok("kubectl")
    runner.ok("oc")
    runner.ok("podman")
    app_ctx.runner = runner
    return runner


def test_create_refuses_a_cluster_that_is_already_running(app_ctx, tmp_path) -> None:
    _prepare(app_ctx, tmp_path, first_status='{"crcStatus": "Running"}')
    try:
        bootstrap.create(
            app_ctx,
            sleep=lambda _s: None,
            host=(8, 32768),
            which=lambda _n: "/bin/crc",
        )
    except AapDemoError as exc:
        assert "already running" in exc.message
    else:
        raise AssertionError("create should refuse a running cluster")


def test_create_refuses_the_openshift_preset(app_ctx) -> None:
    app_ctx.config.set("crc.preset", "openshift")
    try:
        bootstrap.create(app_ctx, sleep=lambda _s: None, which=lambda _n: "/bin/crc")
    except AapDemoError as exc:
        assert "OpenShift preset" in exc.message
    else:
        raise AssertionError("openshift preset must be refused")


def test_create_starts_microshift_and_waits_for_stability(app_ctx, tmp_path) -> None:
    runner = _prepare(app_ctx, tmp_path, first_status='{"crcStatus": "Unknown"}')
    bootstrap.create(
        app_ctx,
        sleep=lambda _s: None,
        host=(8, 32768),
        which=lambda name: "/bin/" + name,
    )
    assert "MicroShift: 4.22.0" in app_ctx.console.stdout
    assert runner.called("crc config set preset microshift")
    assert runner.called("crc config set modify-hosts-file false")
    commands = runner.commands
    hosts = commands.index("crc config set modify-hosts-file false")
    start = next(i for i, command in enumerate(commands) if command.startswith("crc start -p"))
    assert hosts < start
    assert runner.called("crc start -p")
    stdout = app_ctx.console.stdout
    assert "Podman remote connection registered" in stdout
    assert (
        "podman --connection aap-demo build ."
        not in stdout.split("Podman remote connection registered", 1)[-1]
    )
    assert "MicroShift API is ready" in stdout
    assert runner.called("crc setup")
    assert "nip.io" in " ".join(runner.commands)
    assert "Host has 8 CPUs and 32GB RAM" in app_ctx.console.stdout
    assert "Completed Preflight" in app_ctx.console.stdout
    assert "Pull secret:" in app_ctx.console.stdout
    assert "CRI-O pull secret is configured" in app_ctx.console.stdout
    assert "Creating aap-demo crc cluster" in app_ctx.console.stdout
    assert "Next:" in app_ctx.console.stdout
    assert "aap-demo deploy" in app_ctx.console.stdout
    assert "aap-demo oc cluster-info" in app_ctx.console.stdout
    assert "MicroShift cluster ready" not in app_ctx.console.stdout


def test_create_upgrades_a_bundle_older_than_the_managed_release(
    app_ctx, tmp_path, monkeypatch
) -> None:
    calls = {"n": 0}

    def version(_argv):
        calls["n"] += 1
        text = (
            _crc_version_text("4.21.0", crc_release="2.58.0")
            if calls["n"] == 1
            else _crc_version_text("4.22.13")
        )
        return CompletedCommand(argv=tuple(_argv), returncode=0, stdout=text)

    runner = _prepare(app_ctx, tmp_path, first_status='{"crcStatus": "Stopped"}', version=version)
    installed: list = []
    monkeypatch.setattr(
        "aap_demo.infra.crc_install.install_managed_release",
        lambda ctx, **_kw: installed.append(ctx) or tmp_path,
    )

    bootstrap.create(
        app_ctx,
        sleep=lambda _s: None,
        host=(8, 32768),
        which=lambda _n: "/bin/crc",
    )

    assert installed
    assert runner.called("crc delete -f")
    assert runner.called("crc setup")
    assert "MicroShift: 4.22.13" in app_ctx.console.stdout


def test_create_allows_an_older_bundle_when_the_floor_is_lowered(app_ctx, tmp_path) -> None:
    runner = _prepare(
        app_ctx, tmp_path, first_status='{"crcStatus": "Unknown"}', microshift="4.21.0"
    )
    app_ctx.env = {**app_ctx.env, "CRC_VERSION": "4.21"}
    bootstrap.create(
        app_ctx,
        sleep=lambda _s: None,
        host=(8, 32768),
        which=lambda name: "/bin/" + name,
    )
    assert runner.called("crc setup")


def test_create_requires_a_pull_secret(app_ctx, tmp_path) -> None:
    _prepare(app_ctx, tmp_path, first_status='{"crcStatus": "Unknown"}')
    app_ctx.config.set("deploy.pull_secret_path", "")
    try:
        bootstrap.create(
            app_ctx,
            sleep=lambda _s: None,
            host=(8, 32768),
            which=lambda _n: "/bin/crc",
        )
    except AapDemoError as exc:
        assert "Pull secret" in exc.message
        assert "config set pull-secret" in (exc.hint or "")
        assert str(app_ctx.paths.state_dir / "pull-secret.txt") in (exc.hint or "")
    else:
        raise AssertionError("missing pull secret must fail")


def test_create_uses_a_state_pull_secret_without_config(app_ctx, tmp_path) -> None:
    runner = _prepare(app_ctx, tmp_path, first_status='{"crcStatus": "Unknown"}')
    app_ctx.config.set("deploy.pull_secret_path", "")
    secret = app_ctx.paths.state_dir / "pull-secret.txt"
    secret.parent.mkdir(parents=True, exist_ok=True)
    secret.write_text("{}\n")
    bootstrap.create(
        app_ctx,
        sleep=lambda _s: None,
        host=(8, 32768),
        which=lambda _n: "/bin/crc",
    )
    assert runner.called(["crc", "start", "-p", str(secret)])
    assert f"Pull secret: {secret}" in app_ctx.console.stdout


def test_crio_pull_secret_is_installed_when_the_probe_fails(app_ctx, tmp_path) -> None:
    secret = tmp_path / "pull-secret.txt"
    secret.write_text('{"auths":{"registry.redhat.io":{"auth":"dGVzdA=="}}}\n', encoding="utf-8")
    key = tmp_path / "id_ecdsa"
    key.write_text("key", encoding="utf-8")
    probes = {"n": 0}

    def ssh(argv):
        joined = " ".join(argv)
        if "echo configured" in joined:
            probes["n"] += 1
            text = "" if probes["n"] == 1 else "configured\n"
            code = 1 if probes["n"] == 1 else 0
            return CompletedCommand(argv=tuple(argv), returncode=code, stdout=text)
        return CompletedCommand(argv=tuple(argv), returncode=0, stdout="")

    runner = FakeRunner()
    runner.register("ssh", ssh)
    app_ctx.runner = runner

    bootstrap._assert_crio_pull_secret(app_ctx, key, secret)

    install = next(call for call in runner.calls if call.input)
    assert "registry.redhat.io" in install.input
    assert "registry.redhat.io" not in app_ctx.console.stdout
    assert "CRI-O pull secret is configured" in app_ctx.console.stdout


def test_crio_pull_secret_assert_fails_when_the_file_stays_missing(app_ctx, tmp_path) -> None:
    secret = tmp_path / "pull-secret.txt"
    secret.write_text('{"auths":{"registry.redhat.io":{"auth":"dGVzdA=="}}}\n', encoding="utf-8")
    key = tmp_path / "id_ecdsa"
    runner = FakeRunner()
    runner.fail("ssh")
    app_ctx.runner = runner
    try:
        bootstrap._assert_crio_pull_secret(app_ctx, key, secret)
    except AapDemoError as exc:
        assert "not configured" in exc.message
    else:
        raise AssertionError("missing CRI-O pull secret must fail create")


def test_crio_pull_secret_rejects_a_file_without_auths(app_ctx, tmp_path) -> None:
    secret = tmp_path / "pull-secret.txt"
    secret.write_text("{}\n", encoding="utf-8")
    key = tmp_path / "id_ecdsa"
    runner = FakeRunner()
    runner.fail("ssh")
    app_ctx.runner = runner
    try:
        bootstrap._assert_crio_pull_secret(app_ctx, key, secret)
    except AapDemoError as exc:
        assert "registry auth file" in exc.message
    else:
        raise AssertionError("a pull secret without auths must be rejected")
    assert all(call.input is None for call in runner.calls)


def test_destroy_refuses_before_the_warning_when_no_cluster_exists(app_ctx, tmp_path) -> None:
    runner = FakeRunner()
    runner.ok(
        "crc status -o json",
        stdout='{"success": true, "crcStatus": "Stopped", "openshiftStatus": "Stopped"}',
    )
    app_ctx.runner = runner
    app_ctx.env = {"HOME": str(tmp_path)}
    app_ctx.assume_yes = False
    try:
        bootstrap.destroy(app_ctx, sleep=lambda _s: None, which=lambda _n: "/bin/crc")
    except AapDemoError as exc:
        assert exc.message == "No CRC cluster to delete"
    else:
        raise AssertionError("destroy must stop when CRC has no VM")
    assert "WARNING" not in app_ctx.console.stdout
    assert not runner.called("crc delete")


def test_destroy_waits_before_showing_the_delete_spinner(app_ctx) -> None:
    runner = FakeRunner()
    runner.ok(
        "crc status -o json",
        stdout='{"crcStatus": "Running", "openshiftVersion": "4.22.13"}',
    )
    runner.ok("crc delete -f")
    runner.ok("podman system connection remove aap-demo")
    app_ctx.runner = runner
    app_ctx.assume_yes = False
    during: dict[str, str] = {}

    def wait(seconds: float) -> None:
        during["stdout"] = app_ctx.console.stdout
        assert seconds == 10

    bootstrap.destroy(app_ctx, sleep=wait, which=lambda name: "/bin/" + name)
    assert "WARNING" in during["stdout"]
    assert "Deleting" not in during["stdout"]
    assert "CRC cluster deleted" in app_ctx.console.stdout
    assert app_ctx.console.task_states() == [
        ("Deleting the CRC cluster", "done"),
        ("Removing the podman connection", "done"),
    ]


def test_destroy_deletes_the_vm_without_a_prompt_when_assumed_yes(app_ctx, tmp_path) -> None:
    runner = _prepare(app_ctx, tmp_path, first_status='{"crcStatus": "Running"}')
    app_ctx.assume_yes = True
    bootstrap.destroy(app_ctx, sleep=lambda _s: None, which=lambda name: "/bin/" + name)
    assert runner.called("crc delete -f")
    assert "CRC cluster deleted" in app_ctx.console.stdout


def test_destroy_preserves_config_when_delete_fails(app_ctx) -> None:
    runner = FakeRunner()
    runner.ok(
        "crc status -o json",
        stdout='{"crcStatus": "Stopped", "openshiftVersion": "4.22.13"}',
    )
    runner.fail("crc delete -f")
    runner.fail("crc delete")
    app_ctx.runner = runner
    app_ctx.assume_yes = True
    try:
        bootstrap.destroy(app_ctx, which=lambda _n: "/bin/crc")
    except AapDemoError as exc:
        assert "CRC delete failed" in exc.message
    else:
        raise AssertionError("failed delete must keep config")


def test_nipio_restart_stays_under_the_domain_step(app_ctx, tmp_path) -> None:
    key = tmp_path / "id_ecdsa"
    key.write_text("key")
    runner = FakeRunner()
    runner.ok("ssh")
    app_ctx.runner = runner
    app_ctx.console.tasks(["Configuring the nip.io base domain", "Waiting for the MicroShift API"])
    bootstrap._configure_nipio(app_ctx, key, sleep=lambda _s: None)
    titles = [title for title, _state in app_ctx.console.task_states()]
    assert titles == [
        "Configuring the nip.io base domain",
        "Waiting for the MicroShift API",
    ]
    assert "Restarting MicroShift with the nip.io domain" in app_ctx.console.stdout
