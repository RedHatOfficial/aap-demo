"""`aap-demo enable product-demos` runs the bash installer and records the addon."""

from __future__ import annotations

import argparse
import os
import stat
from pathlib import Path

import pytest

from aap_demo.addons import get, names, needs_cluster
from aap_demo.addons.shell import (
    BUNDLED_ADDON_DIRS,
    GALAXY_TOKEN_PREFIX,
    PARTIAL_INSTALL_EXIT,
    scripts_root,
    wire_script,
)
from aap_demo.cli.main import _addon_needs_cluster
from aap_demo.core.errors import AddonError, PrerequisiteError
from aap_demo.exec.runner import CompletedCommand

REPO_ROOT = Path(__file__).resolve().parents[2]


def _present_tools(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        "aap_demo.addons.shell.shutil.which",
        lambda name: f"/usr/bin/{name}",
    )


def _deploy(name: str) -> str:
    return str(scripts_root() / name / "deploy.sh")


def _token_files(app_ctx) -> list:
    state = app_ctx.paths.state_dir
    return sorted(state.glob(GALAXY_TOKEN_PREFIX + "*")) if state.exists() else []


def test_packaged_scripts_are_used_outside_a_checkout(monkeypatch, tmp_path: Path) -> None:
    import aap_demo

    packaged = tmp_path / "aap_demo" / "bundled_addons" / "product-demos"
    packaged.mkdir(parents=True)
    (packaged / "deploy.sh").write_text("#!/bin/bash\n", encoding="utf-8")
    init = tmp_path / "aap_demo" / "__init__.py"
    init.write_text("", encoding="utf-8")
    monkeypatch.setattr(aap_demo, "__file__", str(init))

    assert scripts_root() == tmp_path / "aap_demo" / "bundled_addons"


def test_checkout_scripts_are_the_ones_enable_runs() -> None:
    root = scripts_root()
    assert root == REPO_ROOT / "addons"
    assert (root / "product-demos" / "deploy.sh").is_file()
    assert (root / "product-demos-base" / "lib.sh").is_file()
    assert wire_script().is_file()


def test_pyproject_ships_every_product_demo_installer() -> None:
    text = (REPO_ROOT / "pyproject.toml").read_text(encoding="utf-8")
    for name in BUNDLED_ADDON_DIRS:
        assert f'"addons/{name}"' in text
        assert (REPO_ROOT / "addons" / name / "deploy.sh").is_file()


def test_enable_with_no_name_lists_fleet_and_product_demos() -> None:
    assert names() == ["fleet", "product-demo-satellite", "product-demos"]


def test_product_demos_preflight_uses_the_cluster_and_portal_does_not() -> None:
    assert _addon_needs_cluster("enable", argparse.Namespace(addon="product-demos"))
    assert _addon_needs_cluster("disable", argparse.Namespace(addon="product-demo-linux"))
    assert _addon_needs_cluster("fleet", argparse.Namespace())
    assert not _addon_needs_cluster("enable", argparse.Namespace(addon="portal"))
    assert not _addon_needs_cluster("enable", argparse.Namespace(addon=None))
    assert needs_cluster("product-demos")
    assert not needs_cluster("portal")
    assert not needs_cluster(None)


def test_portal_stays_an_addon_error(app_ctx) -> None:
    with pytest.raises(AddonError, match="implemented addons") as excinfo:
        get("portal")
    assert "aap-demo-v1 enable portal" in (excinfo.value.hint or "")
    assert app_ctx.runner.calls == []


def test_missing_jq_stops_before_the_installer(app_ctx, monkeypatch) -> None:
    monkeypatch.setattr("aap_demo.addons.shell.shutil.which", lambda name: None)

    with pytest.raises(PrerequisiteError, match="jq"):
        get("product-demos").enable(app_ctx, argparse.Namespace(addon="product-demos"))

    assert app_ctx.runner.calls == []
    assert "product-demos" not in (app_ctx.config.get("addons.enabled") or [])


def test_enable_runs_the_installer_and_records_it(app_ctx, monkeypatch) -> None:
    _present_tools(monkeypatch)
    app_ctx.runner.ok(["bash", _deploy("product-demos")], stdout="installed\n")
    app_ctx.runner.ok(["bash", str(wire_script())], stdout="wired\n")

    assert get("product-demos").enable(app_ctx, argparse.Namespace(addon="product-demos")) == 0

    deploy_call, wire_call = app_ctx.runner.calls
    assert deploy_call.argv == ("bash", _deploy("product-demos"))
    assert deploy_call.env["KUBECONFIG"] == str(app_ctx.kubeconfig)
    assert deploy_call.env["NAMESPACE"] == "aap-operator"
    assert deploy_call.env["AAP_DEMO_WIRE_AFTER_DEPLOY"] == "0"
    assert wire_call.argv[0:2] == ("bash", str(wire_script()))
    assert Path(wire_call.argv[2]) == scripts_root() / "product-demos-base" / "lib.sh"
    assert app_ctx.config.get("addons.enabled") == ["product-demos", "product-demos-base"]
    assert "Product demos installed" in app_ctx.console.stdout
    assert _token_files(app_ctx) == []


def test_enable_passes_domain_selection_and_a_galaxy_token(app_ctx, monkeypatch) -> None:
    _present_tools(monkeypatch)
    app_ctx.env = {"PRODUCT_DEMOS_DOMAINS": "linux cloud"}
    app_ctx.secrets.set("galaxy-token", "offline-token")
    seen = {}

    def _see_token(args):
        call = app_ctx.runner.calls[-1]
        token_path = Path(call.env["GALAXY_TOKEN_FILE"])
        seen["token"] = token_path.read_text(encoding="utf-8")
        seen["name"] = token_path.name
        seen["mode"] = stat.S_IMODE(token_path.stat().st_mode)
        assert "offline-token" not in " ".join(args)
        return CompletedCommand(argv=tuple(args), returncode=0)

    app_ctx.runner.ok(["bash", _deploy("product-demos")])
    app_ctx.runner.register(["bash", str(wire_script())], _see_token)

    get("product-demos").enable(
        app_ctx,
        argparse.Namespace(addon="product-demos", addon_args=["--ignored"]),
    )

    deploy_call = app_ctx.runner.calls[0]
    assert deploy_call.argv[-1] == "--ignored"
    assert deploy_call.env["PRODUCT_DEMOS_DOMAINS"] == "linux cloud"
    assert seen["token"] == "offline-token\n"
    assert seen["name"].startswith(GALAXY_TOKEN_PREFIX)
    # Windows reports DOS attributes, not Unix mode 0600.
    if os.name != "nt":
        assert seen["mode"] == 0o600
    assert _token_files(app_ctx) == []


def test_locked_keyring_does_not_fail_a_finished_install(app_ctx, monkeypatch) -> None:
    import keyring.errors

    _present_tools(monkeypatch)

    def locked(_name: str) -> str:
        raise keyring.errors.KeyringLocked("login keychain is locked")

    monkeypatch.setattr(app_ctx.secrets, "get", locked)
    app_ctx.runner.ok(["bash", _deploy("product-demos")])
    app_ctx.runner.ok(["bash", str(wire_script())])

    assert get("product-demos").enable(app_ctx, argparse.Namespace()) == 0

    assert "product-demos" in (app_ctx.config.get("addons.enabled") or [])
    assert "GALAXY_TOKEN_FILE" not in (app_ctx.runner.calls[1].env or {})
    assert "KeyringLocked" in app_ctx.console.stderr
    assert "Product demos installed" in app_ctx.console.stdout
    assert app_ctx.runner.calls[1].argv[0:2] == ("bash", str(wire_script()))


def test_failed_enable_does_not_record_or_wire(app_ctx, monkeypatch) -> None:
    _present_tools(monkeypatch)
    app_ctx.runner.fail(["bash", _deploy("product-demos")], stderr="job failed")

    with pytest.raises(AddonError, match="enable product-demos failed"):
        get("product-demos").enable(app_ctx, argparse.Namespace())

    assert app_ctx.runner.commands == [f"bash {_deploy('product-demos')}"]
    assert app_ctx.config.get("addons.enabled") == []


def test_failed_rerun_keeps_an_addon_that_was_already_enabled(app_ctx, monkeypatch) -> None:
    _present_tools(monkeypatch)
    app_ctx.config.set("addons.enabled", ["product-demos", "product-demos-base"])
    app_ctx.config.save()
    app_ctx.runner.fail(["bash", _deploy("product-demos")])

    with pytest.raises(AddonError):
        get("product-demos").enable(app_ctx, argparse.Namespace())

    assert app_ctx.config.get("addons.enabled") == ["product-demos", "product-demos-base"]
    assert app_ctx.runner.calls[0].env["AAP_DEMO_ENABLED_ADDONS"] == (
        "product-demos product-demos-base"
    )


def test_domain_enable_is_accepted(app_ctx, monkeypatch) -> None:
    _present_tools(monkeypatch)
    app_ctx.runner.ok(["bash", _deploy("product-demo-linux")])
    app_ctx.runner.ok(["bash", str(wire_script())])

    assert get("product-demo-linux").enable(app_ctx, argparse.Namespace()) == 0

    assert app_ctx.config.get("addons.enabled") == [
        "product-demo-linux",
        "product-demos-base",
    ]
    assert "product-demo-linux" not in names()


def test_disable_removes_only_the_named_addon(app_ctx, monkeypatch) -> None:
    _present_tools(monkeypatch)
    app_ctx.config.set("addons.enabled", ["product-demos", "product-demos-base", "fleet"])
    app_ctx.config.save()
    app_ctx.runner.ok(["bash", _deploy("product-demos"), "--delete"])

    assert get("product-demos").disable(app_ctx, argparse.Namespace()) == 0

    assert app_ctx.runner.calls[0].argv == ("bash", _deploy("product-demos"), "--delete")
    assert app_ctx.config.get("addons.enabled") == ["product-demos-base", "fleet"]
    assert "product-demos disabled" in app_ctx.console.stdout


def test_wiring_failure_still_leaves_the_addon_enabled(app_ctx, monkeypatch) -> None:
    _present_tools(monkeypatch)
    app_ctx.runner.ok(["bash", _deploy("product-demos")])
    app_ctx.runner.fail(["bash", str(wire_script())], stderr="wire failed")

    assert get("product-demos").enable(app_ctx, argparse.Namespace()) == 0

    assert "product-demos" in app_ctx.config.get("addons.enabled")
    assert "credential wiring did not finish" in app_ctx.console.stderr


def test_token_file_is_created_0600_not_chmodded_later(app_ctx, monkeypatch) -> None:
    """The token file never exists with a wider mode, even under a permissive umask."""
    if os.name == "nt":
        pytest.skip("Windows reports DOS attributes, not Unix mode bits")
    _present_tools(monkeypatch)
    app_ctx.secrets.set("galaxy-token", "offline-token")
    monkeypatch.setattr(
        "pathlib.Path.chmod",
        lambda *_a, **_k: pytest.fail("the token file must not need a chmod"),
    )
    seen = {}

    def _see_token(args):
        token_path = Path(app_ctx.runner.calls[-1].env["GALAXY_TOKEN_FILE"])
        seen["mode"] = stat.S_IMODE(token_path.stat().st_mode)
        return CompletedCommand(argv=tuple(args), returncode=0)

    app_ctx.runner.ok(["bash", _deploy("product-demos")])
    app_ctx.runner.register(["bash", str(wire_script())], _see_token)
    old_umask = os.umask(0o022)
    try:
        assert get("product-demos").enable(app_ctx, argparse.Namespace()) == 0
    finally:
        os.umask(old_umask)

    assert seen["mode"] == 0o600
    assert _token_files(app_ctx) == []


def test_token_write_failure_does_not_fail_a_finished_install(app_ctx, monkeypatch) -> None:
    _present_tools(monkeypatch)
    app_ctx.secrets.set("galaxy-token", "offline-token")

    def no_space(*_args, **_kwargs):
        raise OSError(28, "No space left on device")

    monkeypatch.setattr("aap_demo.addons.shell.tempfile.mkstemp", no_space)
    app_ctx.runner.ok(["bash", _deploy("product-demos")])
    app_ctx.runner.ok(["bash", str(wire_script())])

    assert get("product-demos").enable(app_ctx, argparse.Namespace()) == 0

    assert "product-demos" in (app_ctx.config.get("addons.enabled") or [])
    assert "GALAXY_TOKEN_FILE" not in (app_ctx.runner.calls[1].env or {})
    assert "No space left on device" in app_ctx.console.stderr
    assert "Galaxy credentials were not updated" in app_ctx.console.stderr
    assert "Product demos installed" in app_ctx.console.stdout


def test_token_is_removed_when_the_write_fails_partway(app_ctx, monkeypatch) -> None:
    _present_tools(monkeypatch)
    app_ctx.secrets.set("galaxy-token", "offline-token")

    class _Broken:
        def __init__(self, fd, _mode):
            os.close(fd)

        def __enter__(self):
            return self

        def __exit__(self, *_exc):
            return False

        def write(self, _data):
            raise OSError(5, "Input/output error")

    monkeypatch.setattr("aap_demo.addons.shell.os.fdopen", _Broken)
    app_ctx.runner.ok(["bash", _deploy("product-demos")])
    app_ctx.runner.ok(["bash", str(wire_script())])

    assert get("product-demos").enable(app_ctx, argparse.Namespace()) == 0

    assert "GALAXY_TOKEN_FILE" not in (app_ctx.runner.calls[1].env or {})
    assert "Input/output error" in app_ctx.console.stderr
    assert _token_files(app_ctx) == []


def test_partial_install_is_recorded_and_wired_then_reported(app_ctx, monkeypatch) -> None:
    _present_tools(monkeypatch)
    app_ctx.runner.fail(
        ["bash", _deploy("product-demos")],
        returncode=PARTIAL_INSTALL_EXIT,
        stderr="Some domains failed to install: windows",
    )
    app_ctx.runner.ok(["bash", str(wire_script())])

    with pytest.raises(AddonError, match="some demo domains failed"):
        get("product-demos").enable(app_ctx, argparse.Namespace())

    # The base and the domains that worked are in AAP, so disable must see them.
    assert app_ctx.config.get("addons.enabled") == ["product-demos", "product-demos-base"]
    assert app_ctx.runner.calls[1].argv[0:2] == ("bash", str(wire_script()))
    assert "Product demos installed" not in app_ctx.console.stdout


def test_partial_exit_on_disable_is_still_a_failure(app_ctx, monkeypatch) -> None:
    _present_tools(monkeypatch)
    app_ctx.config.set("addons.enabled", ["product-demos", "product-demos-base"])
    app_ctx.runner.fail(
        ["bash", _deploy("product-demos"), "--delete"], returncode=PARTIAL_INSTALL_EXIT
    )

    with pytest.raises(AddonError, match="disable product-demos failed"):
        get("product-demos").disable(app_ctx, argparse.Namespace())

    assert app_ctx.config.get("addons.enabled") == ["product-demos", "product-demos-base"]
    assert len(app_ctx.runner.calls) == 1


def test_installer_exits_3_only_for_a_partial_install() -> None:
    script = (scripts_root() / "product-demos" / "deploy.sh").read_text(encoding="utf-8")
    statements = [line.strip() for line in script.splitlines()]
    assert statements.count(f"exit {PARTIAL_INSTALL_EXIT}") == 1
    # A failed base install must not pass its own exit code (jq uses 3) through.
    assert 'product-demos-base/deploy.sh" || exit 1' in script


def test_installers_keep_the_collection_async_waits() -> None:
    """Zero async retries let workflow nodes be created before their workflow (Windows)."""
    for path in sorted(scripts_root().glob("product-demo*/**/*.sh")):
        assert "async_retries" not in path.read_text(encoding="utf-8"), path
