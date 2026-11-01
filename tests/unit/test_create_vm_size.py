"""The create size prompt and host fit check (ADR-034)."""

from __future__ import annotations

import pytest

from aap_demo.cluster import bootstrap
from aap_demo.core import config as config_mod
from aap_demo.core import prompts
from aap_demo.core.errors import AapDemoError


class _Answers:
    def __init__(self, *answers: str) -> None:
        self.answers = list(answers)
        self.prompts = []

    def __call__(self, prompt: str) -> str:
        self.prompts.append(prompt)
        if not self.answers:
            raise EOFError
        return self.answers.pop(0)


def _ask(console, *answers: str, host=(16, 65536)):
    read = _Answers(*answers)
    return prompts.vm_size(console, cpus=8, memory_mb=24576, host=host, read=read), read


def test_enter_keeps_the_defaults(app_ctx) -> None:
    chosen, read = _ask(app_ctx.console, "", "")
    assert chosen == (8, 24576)
    assert read.prompts == ["  CPUs [8]: ", "  Memory in GB [24]: "]
    assert "Host: 16 CPUs, 64GB RAM" in app_ctx.console.stdout


def test_answers_replace_the_defaults_and_memory_is_in_gb(app_ctx) -> None:
    assert _ask(app_ctx.console, "6", "16")[0] == (6, 16384)


def test_defaults_are_capped_to_the_host(app_ctx) -> None:
    chosen, read = _ask(app_ctx.console, "", "", host=(4, 16384))
    assert chosen == (4, 16384)
    assert read.prompts == ["  CPUs [4]: ", "  Memory in GB [16]: "]


def test_end_of_input_keeps_the_defaults(app_ctx) -> None:
    assert _ask(app_ctx.console)[0] == (8, 24576)


@pytest.mark.parametrize("answers", [("x", ""), ("0", ""), ("-1", ""), ("", "1.5"), ("", "0")])
def test_invalid_answers_stop(app_ctx, answers) -> None:
    with pytest.raises(AapDemoError, match="Invalid"):
        _ask(app_ctx.console, *answers)


def _no_vm(app_ctx, monkeypatch, *answers: str) -> _Answers:
    read = _Answers(*answers)
    real = prompts.vm_size
    monkeypatch.setattr(prompts, "can_ask", lambda env: True)
    monkeypatch.setattr(
        prompts, "vm_size", lambda console, **kwargs: real(console, read=read, **kwargs)
    )
    monkeypatch.setattr(bootstrap.infra_crc, "has_instance", lambda runner, home: False)
    return read


def _asked(app_ctx) -> None:
    bootstrap._ask_vm_size(app_ctx, (16, 65536), which=lambda name: "/bin/crc")


def test_a_changed_answer_saves_only_the_size(app_ctx, monkeypatch) -> None:
    path = app_ctx.paths.config_file
    config_mod.write(path, {"schema_version": 1, "core": {"namespace": "saved"}})
    app_ctx.config = config_mod.resolve(
        file_data=config_mod.read_yaml(path),
        overrides={"core": {"namespace": "from-a-flag"}, "crc": {"disk_gb": 200}},
        path=path,
    )
    _no_vm(app_ctx, monkeypatch, "6", "16")

    _asked(app_ctx)

    assert app_ctx.config.get("crc.cpus") == 6
    assert app_ctx.config.get("crc.memory_mb") == 16384
    assert config_mod.read_yaml(path) == {
        "schema_version": 1,
        "core": {"namespace": "saved"},
        "crc": {"cpus": 6, "memory_mb": 16384},
    }


def test_an_answer_too_large_for_the_host_is_not_saved(app_ctx, monkeypatch) -> None:
    monkeypatch.setattr(bootstrap, "_swap_mb", lambda: 0)
    _no_vm(app_ctx, monkeypatch, "32", "")
    with pytest.raises(AapDemoError, match="does not fit"):
        _asked(app_ctx)
    assert not app_ctx.paths.config_file.exists()
    assert app_ctx.config.get("crc.cpus") == 8


def test_keeping_the_defaults_writes_nothing(app_ctx, monkeypatch) -> None:
    _no_vm(app_ctx, monkeypatch, "", "")
    _asked(app_ctx)
    assert not app_ctx.paths.config_file.exists()


def test_an_answer_below_the_schema_minimum_stops(app_ctx, monkeypatch) -> None:
    _no_vm(app_ctx, monkeypatch, "1", "")
    with pytest.raises(AapDemoError):
        _asked(app_ctx)


@pytest.mark.parametrize("change", ["explicit", "structured", "no_terminal", "vm_exists"])
def test_it_does_not_ask(app_ctx, monkeypatch, change: str) -> None:
    read = _no_vm(app_ctx, monkeypatch, "6", "16")
    if change == "explicit":
        app_ctx.vm_size_explicit = True
    elif change == "structured":
        app_ctx.output = "json"
    elif change == "no_terminal":
        monkeypatch.setattr(prompts, "can_ask", lambda env: False)
    else:
        monkeypatch.setattr(bootstrap.infra_crc, "has_instance", lambda runner, home: True)

    _asked(app_ctx)

    assert read.prompts == []


def test_interactive_env_asks_without_a_terminal() -> None:
    assert prompts.can_ask({"AAP_DEMO_INTERACTIVE": "1"}) is True


@pytest.mark.parametrize("cpus,memory", [(9, 16384), (8, 16385)])
def test_a_vm_larger_than_the_host_stops_with_a_size_that_fits(
    monkeypatch, cpus: int, memory: int
) -> None:
    monkeypatch.setattr(bootstrap, "_swap_mb", lambda: 0)
    with pytest.raises(AapDemoError, match="does not fit") as raised:
        bootstrap._require_host_fit(cpus, memory, (8, 16384))
    assert "--cpus 8" in (raised.value.hint or "")
    assert f"--memory {min(memory, 16384)}" in (raised.value.hint or "")


def test_a_vm_equal_to_the_host_or_an_unread_host_passes(monkeypatch) -> None:
    monkeypatch.setattr(bootstrap, "_swap_mb", lambda: 0)
    bootstrap._require_host_fit(8, 16384, (8, 16384))
    bootstrap._require_host_fit(64, 999999, (0, 0))


def test_linux_swap_counts_toward_memory(monkeypatch) -> None:
    monkeypatch.setattr(bootstrap, "_swap_mb", lambda: 8192)
    bootstrap._require_host_fit(8, 24576, (8, 16384))


def test_create_stops_before_changing_anything_when_the_vm_does_not_fit(
    app_ctx, fake_runner, monkeypatch
) -> None:
    monkeypatch.setattr(bootstrap, "_swap_mb", lambda: 0)
    monkeypatch.setattr(prompts, "can_ask", lambda env: False)
    calls = []
    monkeypatch.setattr(
        bootstrap.infra_crc, "ensure_managed_crc", lambda *a, **k: calls.append("ensure")
    )
    with pytest.raises(AapDemoError, match="does not fit"):
        bootstrap.create(app_ctx, host=(4, 8192), which=lambda name: None)
    assert calls == []
    assert fake_runner.commands == []
