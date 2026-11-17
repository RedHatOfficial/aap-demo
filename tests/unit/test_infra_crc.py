"""``infra/crc.py`` over realistic ``crc status -o json`` captures."""

from __future__ import annotations

from pathlib import Path

import pytest

from aap_demo.core.errors import AapDemoError
from aap_demo.exec.runner import CompletedCommand, FakeRunner
from aap_demo.infra import crc as infra_crc

FIXTURES = Path(__file__).parent.parent / "fixtures" / "crc"


def _load(name: str) -> str:
    return (FIXTURES / name).read_text(encoding="utf-8")


def test_get_state_running_from_real_crc_json(fake_runner: FakeRunner) -> None:
    fake_runner.ok("crc status -o json", stdout=_load("status_running.json"))
    assert infra_crc.get_state(fake_runner) == infra_crc.STATE_RUNNING


def test_get_state_stopped_from_real_crc_json(fake_runner: FakeRunner) -> None:
    fake_runner.ok("crc status -o json", stdout=_load("status_stopped.json"))
    assert infra_crc.get_state(fake_runner) == infra_crc.STATE_STOPPED


def test_get_state_not_created_when_crc_status_fails(fake_runner: FakeRunner) -> None:
    fake_runner.fail("crc status -o json", stderr="machine does not exist")
    assert infra_crc.get_state(fake_runner) == infra_crc.STATE_NOT_CREATED


def test_status_json_bounds_a_hung_crc_daemon(fake_runner: FakeRunner) -> None:
    fake_runner.ok("crc status -o json", stdout=_load("status_running.json"))
    infra_crc.status_json(fake_runner)
    assert fake_runner.calls[-1].timeout == infra_crc.STATUS_TIMEOUT_SECONDS


def test_get_state_not_created_when_crc_status_times_out(fake_runner: FakeRunner) -> None:
    fake_runner.register(
        "crc status -o json",
        AapDemoError("command timed out after 2.0s: crc status -o json"),
    )
    assert infra_crc.status_json(fake_runner) == {}
    assert infra_crc.get_state(fake_runner) == infra_crc.STATE_NOT_CREATED


def test_get_state_not_created_when_crc_binary_missing(fake_runner: FakeRunner) -> None:
    fake_runner.register("crc status -o json", FileNotFoundError())
    assert infra_crc.get_state(fake_runner) == infra_crc.STATE_NOT_CREATED


def test_get_state_tolerates_invalid_json(fake_runner: FakeRunner) -> None:
    fake_runner.ok("crc status -o json", stdout="not json")
    assert infra_crc.get_state(fake_runner) == infra_crc.STATE_NOT_CREATED


def test_get_state_tolerates_empty_stdout(fake_runner: FakeRunner) -> None:
    fake_runner.ok("crc status -o json", stdout="")
    assert infra_crc.get_state(fake_runner) == infra_crc.STATE_NOT_CREATED


@pytest.mark.parametrize("preset", ["microshift", "openshift"])
def test_get_name_formats_crc_dash_preset(preset: str) -> None:
    assert infra_crc.get_name(preset) == f"crc-{preset}"


def test_disk_usage_percent_from_real_crc_json() -> None:
    import json

    data = json.loads(_load("status_running.json"))
    # 32212254720 / 107374182400 == 0.3
    assert infra_crc.disk_usage_percent(data) == 30


def test_disk_usage_percent_zero_division_is_safe() -> None:
    assert infra_crc.disk_usage_percent({"diskUse": 5, "diskSize": 0}) == 0


def test_disk_usage_percent_defaults_to_zero_on_missing_fields() -> None:
    assert infra_crc.disk_usage_percent({}) == 0


def test_release_is_newer_compares_numeric_crc_versions() -> None:
    assert infra_crc.release_is_newer("v2.65.0", "2.64.0")
    assert infra_crc.release_is_newer("2.10.0", "2.9.0")
    assert not infra_crc.release_is_newer("2.64.0", "2.64.0")
    assert not infra_crc.release_is_newer("2.63.0", "v2.64.0")
    assert infra_crc.normalize_release("2.58.0+bf65c3") == "2.58.0"
    assert infra_crc.managed_crc_release()
    with pytest.raises(ValueError):
        infra_crc.normalize_release("2.65.0-rc.1")


def test_bundled_microshift_version_prefers_the_microshift_line() -> None:
    text = "CRC version: 2.63.0\nOpenShift version: 4.22.7\nMicroShift version: 4.22.0\n"
    assert infra_crc.bundled_microshift_version(text) == "4.22.0"
    assert infra_crc.bundled_microshift_version("OpenShift version: 4.21.0\n") == "4.21.0"
    assert infra_crc.bundled_microshift_version("no version here") is None


def test_verify_version_accepts_the_recommended_release(app_ctx) -> None:
    app_ctx.runner = FakeRunner().ok("crc status -o json", stdout='{"openshiftVersion": "4.22.5"}')
    assert infra_crc.verify_version(app_ctx) is True
    assert app_ctx.console.stderr == ""


def test_verify_version_warns_and_rejects_below_the_minimum(app_ctx) -> None:
    app_ctx.runner = FakeRunner().ok("crc status -o json", stdout='{"openshiftVersion": "4.21.0"}')
    assert infra_crc.verify_version(app_ctx) is False
    assert "below the recommended version" in app_ctx.console.stderr
    assert "CRC version too old" in app_ctx.console.stderr


def test_verify_version_warns_but_allows_an_explicit_lower_minimum(app_ctx) -> None:
    app_ctx.env = {"CRC_VERSION": "4.21"}
    app_ctx.runner = FakeRunner().ok("crc status -o json", stdout='{"openshiftVersion": "4.21.9"}')
    assert infra_crc.verify_version(app_ctx) is True
    assert "below the recommended version" in app_ctx.console.stderr
    assert "too old" not in app_ctx.console.stderr


def test_verify_version_fails_when_crc_does_not_report_one(app_ctx) -> None:
    app_ctx.runner = FakeRunner().ok("crc status -o json", stdout='{"crcStatus": "Running"}')
    assert infra_crc.verify_version(app_ctx) is False
    assert "Could not detect CRC version" in app_ctx.console.stderr


def test_wait_until_stable_needs_consecutive_healthy_samples() -> None:
    samples = iter(
        [
            '{"crcStatus": "Running", "openshiftStatus": "Running"}',
            '{"crcStatus": "Stopped", "openshiftStatus": "Stopped"}',
            '{"crcStatus": "Running", "openshiftStatus": "Running"}',
            '{"crcStatus": "Running", "openshiftStatus": "Running"}',
            '{"crcStatus": "Running", "openshiftStatus": "Running"}',
        ]
    )
    runner = FakeRunner()
    runner.register(
        "crc status -o json",
        lambda argv: CompletedCommand(argv=argv, returncode=0, stdout=next(samples)),
    )
    runner.ok(
        "kubectl", stdout='{"items":[{"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    )
    slept = []
    assert infra_crc.wait_until_stable(
        runner,
        kubeconfig=Path("/tmp/config"),
        samples=3,
        attempts=6,
        sleep_seconds=5,
        sleep=slept.append,
    )
    assert slept == [5, 5, 5, 5]


def test_wait_until_stable_accepts_an_unreachable_status_when_the_api_answers() -> None:
    runner = FakeRunner()
    runner.ok(
        "crc status -o json",
        stdout='{"crcStatus": "Running", "openshiftStatus": "Unreachable"}',
    )
    runner.ok(
        "kubectl", stdout='{"items":[{"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    )
    assert infra_crc.wait_until_stable(
        runner, kubeconfig=Path("/tmp/config"), samples=1, attempts=1, sleep=lambda _s: None
    )


@pytest.mark.parametrize(
    ("body", "expected"),
    [
        ('{"items":[{"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}', True),
        ('{"items":[]}', False),
        ('{"items":[{"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}', False),
        ('{"items":[{"status":{"conditions":[{"type":"Ready","status":"Unknown"}]}}]}', False),
        ('{"items":[{"status":{}}]}', False),
        ('{"items":[null]}', False),
        ("invalid", False),
    ],
)
def test_stability_requires_api_and_ready_node(body, expected, tmp_path) -> None:
    runner = FakeRunner().ok(
        "crc status", stdout='{"crcStatus":"Running","openshiftStatus":"Running"}'
    )
    runner.ok("kubectl", stdout=body)
    assert (
        infra_crc.wait_until_stable(
            runner, kubeconfig=tmp_path / "config", samples=1, attempts=1, sleep=lambda _: None
        )
        is expected
    )
    call = runner.calls[-1]
    assert str(tmp_path / "config") in call.argv
    assert "--request-timeout=5s" in call.argv
    assert call.timeout == 7


def test_health_failure_guidance_includes_platform_logs(tmp_path) -> None:
    mac = infra_crc.health_failure_hint({"HOME": str(tmp_path)}, "Darwin")
    assert "crc status --log-level debug" in mac
    assert str(tmp_path / ".crc/machines/crc/vfkit.log") in mac
    assert "github.com/crc-org/crc/issues" in mac
    assert "if present" in mac
    linux = infra_crc.health_failure_hint({"HOME": str(tmp_path)}, "Linux")
    assert "crc status --log-level debug" in linux
    assert "vfkit.log" not in linux


def test_stability_rejects_timed_out_api(tmp_path) -> None:
    runner = FakeRunner().ok(
        "crc status", stdout='{"crcStatus":"Running","openshiftStatus":"Running"}'
    )
    runner.register("kubectl", AapDemoError("timed out"))
    assert not infra_crc.wait_until_stable(
        runner, kubeconfig=tmp_path / "config", samples=1, attempts=1
    )


def test_node_readiness_loss_resets_stability_window(tmp_path) -> None:
    ready = '{"items":[{"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    responses = iter([ready, '{"items":[]}', ready, ready, ready])
    runner = FakeRunner().ok(
        "crc status", stdout='{"crcStatus":"Running","openshiftStatus":"Running"}'
    )
    runner.register(
        "kubectl", lambda argv: CompletedCommand(argv=argv, returncode=0, stdout=next(responses))
    )
    sleeps = []
    assert infra_crc.wait_until_stable(
        runner, kubeconfig=tmp_path / "config", samples=3, attempts=5, sleep=sleeps.append
    )
    assert len(sleeps) == 4
