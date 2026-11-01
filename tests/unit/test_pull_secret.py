"""Pull-secret discovery: config wins, otherwise the XDG state directory."""

from __future__ import annotations

from pathlib import Path

import pytest

from aap_demo.cluster import pull_secret, storage
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError
from aap_demo.exec.runner import FakeRunner


def _write(path: Path, text: str = "{}\n") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def test_state_txt_is_used_when_config_is_empty(app_ctx: AppContext) -> None:
    app_ctx.config.set("deploy.pull_secret_path", "")
    secret = _write(app_ctx.paths.state_dir / "pull-secret.txt")
    assert pull_secret.discover(app_ctx) == secret


def test_state_json_is_used_when_txt_is_absent(app_ctx: AppContext) -> None:
    app_ctx.config.set("deploy.pull_secret_path", "")
    secret = _write(app_ctx.paths.pull_secret)
    assert pull_secret.discover(app_ctx) == secret


def test_txt_wins_when_both_default_files_exist(app_ctx: AppContext) -> None:
    app_ctx.config.set("deploy.pull_secret_path", "")
    txt = _write(app_ctx.paths.state_dir / "pull-secret.txt", "txt\n")
    _write(app_ctx.paths.pull_secret, "json\n")
    assert pull_secret.discover(app_ctx) == txt


def test_explicit_path_wins_over_the_state_file(app_ctx: AppContext, tmp_path: Path) -> None:
    _write(app_ctx.paths.state_dir / "pull-secret.txt", "state\n")
    explicit = _write(tmp_path / "mine.txt", "mine\n")
    app_ctx.config.set("deploy.pull_secret_path", str(explicit))
    assert pull_secret.discover(app_ctx) == explicit


def test_a_missing_explicit_path_does_not_fall_back(app_ctx: AppContext, tmp_path: Path) -> None:
    _write(app_ctx.paths.state_dir / "pull-secret.txt")
    app_ctx.config.set("deploy.pull_secret_path", str(tmp_path / "missing.txt"))
    assert pull_secret.discover(app_ctx) is None


def test_legacy_directory_is_not_searched(app_ctx: AppContext) -> None:
    app_ctx.config.set("deploy.pull_secret_path", "")
    _write(app_ctx.paths.legacy_dir / "pull-secret.txt")
    assert pull_secret.discover(app_ctx) is None


def test_unset_hint_uses_a_tilde_when_state_is_under_home(
    app_ctx: AppContext, tmp_path: Path
) -> None:
    app_ctx.env = {"HOME": str(tmp_path)}
    hint = pull_secret.unset_hint(app_ctx)
    assert "~/state/pull-secret.txt" in hint
    assert "config set pull-secret" in hint
    assert "pull-secret.json" in hint


def test_a_rejected_secret_stops_before_the_service_account(app_ctx: AppContext) -> None:
    _write(app_ctx.paths.pull_secret)
    app_ctx.config.set("deploy.pull_secret_path", "")
    runner = FakeRunner().ok("kubectl delete secret").fail("kubectl create secret", stderr="denied")
    app_ctx.runner = runner
    with pytest.raises(AapDemoError, match="Could not create") as caught:
        pull_secret.ensure(app_ctx, "aap-operator")
    assert caught.value.hint == "denied"
    assert not runner.called("kubectl patch serviceaccount")


def test_a_rejected_service_account_patch_is_reported(app_ctx: AppContext) -> None:
    runner = FakeRunner().ok("kubectl get serviceaccount", stdout="")
    runner.fail("kubectl patch serviceaccount", stderr="forbidden")
    app_ctx.runner = runner
    with pytest.raises(AapDemoError, match="default ServiceAccount") as caught:
        pull_secret.attach_to_default_sa(app_ctx, "aap-operator")
    assert caught.value.hint == "forbidden"


def test_rejected_pvcs_stop_the_deploy(app_ctx: AppContext) -> None:
    runner = FakeRunner().ok("kubectl get sc").fail("kubectl apply -f -", stderr="quota exceeded")
    app_ctx.runner = runner
    with pytest.raises(AapDemoError, match="Could not create the PVCs") as caught:
        storage.ensure_aap_pvcs(app_ctx, aap_name="aap", namespace="aap-operator")
    assert caught.value.hint == "quota exceeded"
