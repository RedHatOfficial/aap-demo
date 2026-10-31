"""Phase 2 cluster operations over FakeRunner."""

from __future__ import annotations

import base64

from aap_demo.cluster import runtime
from aap_demo.exec.runner import CompletedCommand, FakeRunner


def test_stop_reports_success_even_when_crc_stop_fails(app_ctx) -> None:
    app_ctx.runner = FakeRunner().fail("crc stop")
    runtime.stop(app_ctx)
    assert "CRC cluster stopped" in app_ctx.console.stdout


def test_idle_shows_the_current_state(app_ctx) -> None:
    runner = FakeRunner()
    runner.ok(
        ["kubectl", "get", "aap", "-n", "aap-operator", "-o"],
        stdout="demo",
    )
    runner.ok(
        ["kubectl", "get", "aap", "demo", "-n", "aap-operator", "-o"],
        stdout="false",
    )
    app_ctx.runner = runner
    assert runtime.idle(app_ctx, None) == 0
    assert "AAP 'demo' is running" in app_ctx.console.stdout


def test_idle_patches_the_cr_when_scaling_down(app_ctx) -> None:
    runner = FakeRunner()
    runner.ok(["kubectl", "get", "aap", "-n", "aap-operator", "-o"], stdout="demo")
    runner.ok(["kubectl", "get", "aap", "demo", "-n", "aap-operator", "-o"], stdout="false")
    runner.ok("kubectl patch")
    app_ctx.runner = runner
    assert runtime.idle(app_ctx, "true") == 0
    assert runner.called("kubectl patch aap demo")
    assert "set to idle" in app_ctx.console.stdout


def test_idle_fails_when_no_aap_exists(app_ctx) -> None:
    app_ctx.runner = FakeRunner().ok("kubectl get aap", stdout="")
    assert runtime.idle(app_ctx, None) == 1
    assert "No AAP instance" in app_ctx.console.stderr


def test_repair_deletes_crashloop_pods(app_ctx) -> None:
    runner = FakeRunner()
    runner.ok("oc adm policy")
    runner.ok("kubectl get configmap", stdout="")
    runner.ok(
        "kubectl get pods",
        stdout="gateway-0 0/1 CrashLoopBackOff 3 1m\napi-0 1/1 Running 0 1m\n",
    )
    runner.ok("kubectl delete pod")
    app_ctx.runner = runner
    runtime.repair(
        app_ctx,
        sleep=lambda _s: None,
        which=lambda name: "/bin/oc" if name == "oc" else None,
    )
    assert runner.called("kubectl delete pod gateway-0")
    assert "In-cluster repair complete" in app_ctx.console.stdout


def test_must_gather_keeps_local_files_when_oc_fails(app_ctx, tmp_path) -> None:
    app_ctx.paths.config_file.parent.mkdir(parents=True, exist_ok=True)
    app_ctx.paths.config_file.write_text("preset: microshift\n", encoding="utf-8")
    runner = FakeRunner()
    runner.ok("crc status", stdout="CRC VM: Running\n")
    runner.ok("crc version", stdout="CRC version: 2.58.0\n")
    runner.ok("kubectl", stdout="ok\n")
    runner.fail("oc adm must-gather", returncode=2, stderr="image pull failed")
    app_ctx.runner = runner
    dest = tmp_path / "gather"
    assert runtime.must_gather(app_ctx, str(dest)) == 0
    assert (dest / "aap-demo" / "crc-status.txt").read_text(encoding="utf-8") == "CRC VM: Running\n"
    assert "still collected" in app_ctx.console.stdout


def test_watch_prints_the_success_summary(app_ctx) -> None:
    password = base64.b64encode(b"secret").decode("ascii")
    runner = FakeRunner()
    runner.ok(
        ["kubectl", "get", "aap", "-n", "aap-operator", "-o"],
        stdout="True",
    )
    runner.register(
        "kubectl get route",
        lambda argv: CompletedCommand(argv=argv, returncode=0, stdout="aap.apps.127.0.0.1.nip.io"),
    )
    runner.register(
        "kubectl get csv",
        lambda argv: CompletedCommand(argv=argv, returncode=0, stdout="aap-operator.v2.7.0"),
    )
    runner.register(
        "kubectl get secret",
        lambda argv: CompletedCommand(argv=argv, returncode=0, stdout=password),
    )
    app_ctx.runner = runner
    assert runtime.watch(app_ctx, sleep=lambda _s: None) == 0
    assert "AAP deployment successful" in app_ctx.console.stdout
    assert "Password: secret" in app_ctx.console.stdout


def test_analyze_refuses_a_missing_claude_cli(app_ctx) -> None:
    assert runtime.analyze(app_ctx, which=lambda _name: None) == 1
    assert "claude" in app_ctx.console.stderr


def test_analyze_sends_diagnostics_to_claude(app_ctx) -> None:
    runner = FakeRunner()
    runner.ok("kubectl", stdout="gateway-0 0/1 CrashLoopBackOff 1 1m\n")
    runner.ok("claude -p", stdout="Restart the gateway pod.\n")
    app_ctx.runner = runner
    assert runtime.analyze(app_ctx, which=lambda _name: "/usr/bin/claude") == 0
    assert runner.called("claude -p")
    assert "Restart the gateway pod." in app_ctx.console.stdout
