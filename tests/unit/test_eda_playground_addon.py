"""EDA Playground uses the Python command's legacy-addon boundary."""

from __future__ import annotations

import argparse
from pathlib import Path

from aap_demo.addons import get, names, needs_cluster
from aap_demo.addons.shell import scripts_root


def _deploy() -> str:
    return str(scripts_root() / "eda-playground" / "deploy.sh")


def test_eda_playground_is_a_public_legacy_addon() -> None:
    addon = get("eda-playground")

    assert addon.name == "eda-playground"
    assert addon.kind == "legacy"
    assert addon.public is True
    assert addon.needs_cluster is True
    assert "eda-playground" in names()
    assert needs_cluster("eda-playground") is True


def test_enable_uses_python_state_and_does_not_run_product_demo_wiring(
    app_ctx, monkeypatch
) -> None:
    monkeypatch.setattr(
        "aap_demo.addons.shell.shutil.which",
        lambda name: f"/usr/bin/{name}",
    )
    app_ctx.runner.ok(["bash", _deploy()], stdout="installed\n")

    assert get("eda-playground").enable(app_ctx, argparse.Namespace(addon="eda-playground")) == 0

    call = app_ctx.runner.calls[0]
    assert call.argv == ("bash", _deploy())
    assert call.env["KUBECONFIG"] == str(app_ctx.kubeconfig)
    assert call.env["NAMESPACE"] == "aap-operator"
    assert call.env["EDA_PLAYGROUND_STATE_DIR"] == str(app_ctx.paths.state_dir / "eda-playground")
    assert app_ctx.config.get("addons.enabled") == ["eda-playground"]
    assert len(app_ctx.runner.calls) == 1


def test_eda_playground_scripts_are_bundled() -> None:
    root = Path(__file__).resolve().parents[2]
    assert (root / "addons/eda-playground/deploy.sh").is_file()
    text = (root / "pyproject.toml").read_text(encoding="utf-8")
    assert '"addons/eda-playground" = "aap_demo/bundled_addons/eda-playground"' in text
