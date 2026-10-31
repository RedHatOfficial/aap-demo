"""Pull-secret discovery: config wins, otherwise the XDG state directory."""

from __future__ import annotations

from pathlib import Path

from aap_demo.cluster import pull_secret
from aap_demo.core.context import AppContext


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
