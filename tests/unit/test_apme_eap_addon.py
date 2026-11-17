"""Native V2 lifecycle contract for the APME EAP addon."""

from __future__ import annotations

import argparse
import os

import pytest

from aap_demo.addons import get, names, needs_cluster
from aap_demo.core.errors import AddonError


def _env(app_ctx) -> None:
    app_ctx.env = {
        "APME_EAP_OPENSHIFT_API_URL": "https://api.example.test:6443",
        "APME_EAP_CLUSTER_DOMAIN": "apps.example.test",
        "APME_EAP_AAP_HOST": "https://aap.apps.example.test",
        "APME_EAP_AAP_PASSWORD": "redacted-password",
    }


def test_apme_eap_is_a_public_native_addon() -> None:
    addon = get("apme-eap")

    assert addon.name == "apme-eap"
    assert addon.kind == "native"
    assert addon.public is True
    assert addon.needs_cluster is True
    assert "apme-eap" in names()
    assert needs_cluster("apme-eap") is True


def test_enable_runs_packaged_playbook_and_records_state(app_ctx, monkeypatch) -> None:
    _env(app_ctx)
    monkeypatch.setattr(
        "aap_demo.addons.apme_eap.shutil.which",
        lambda name: f"/usr/bin/{name}",
    )
    app_ctx.runner.ok(["ansible-playbook"], stdout="completed\n")

    assert get("apme-eap").enable(app_ctx, argparse.Namespace(addon="apme-eap")) == 0

    call = app_ctx.runner.calls[0]
    assert call.argv[0] == "ansible-playbook"
    assert "playbooks/deploy_apme_portal.yml" in call.argv[1]
    assert call.env["K8S_AUTH_KUBECONFIG"] == str(app_ctx.kubeconfig)
    assert call.cwd.endswith("addons/apme-eap")
    assert app_ctx.config.get("addons.enabled") == ["apme-eap"]
    vars_file = app_ctx.paths.addon_dir("apme-eap") / "vars.yml"
    assert vars_file.is_file()
    assert os.stat(vars_file).st_mode & 0o777 == 0o600
    assert "redacted-password" not in app_ctx.console.stdout


def test_failed_enable_does_not_record_state(app_ctx, monkeypatch) -> None:
    _env(app_ctx)
    monkeypatch.setattr(
        "aap_demo.addons.apme_eap.shutil.which",
        lambda name: f"/usr/bin/{name}",
    )
    app_ctx.runner.fail(["ansible-playbook"], stderr="playbook failed")

    with pytest.raises(AddonError, match="enable apme-eap failed"):
        get("apme-eap").enable(app_ctx, argparse.Namespace(addon="apme-eap"))

    assert app_ctx.config.get("addons.enabled") == []


def test_disable_removes_owned_namespace_and_state(app_ctx) -> None:
    state_dir = app_ctx.paths.addon_dir("apme-eap")
    state_dir.mkdir(parents=True)
    (state_dir / "vars.yml").write_text("private\n", encoding="utf-8")
    app_ctx.config.set("addons.enabled", ["apme-eap", "fleet"])
    app_ctx.runner.ok(["kubectl", "delete", "namespace", "apme"])

    assert get("apme-eap").disable(app_ctx, argparse.Namespace(addon="apme-eap")) == 0

    assert app_ctx.runner.called(["kubectl", "delete", "namespace", "apme"])
    assert app_ctx.config.get("addons.enabled") == ["fleet"]
    assert not state_dir.exists()
