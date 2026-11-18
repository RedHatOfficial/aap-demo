"""Native V2 lifecycle contract for the APME EAP addon."""

from __future__ import annotations

import argparse
import hashlib
import json
import tempfile
from pathlib import Path

import pytest
import yaml

from aap_demo.addons import apme_eap, get, names, needs_cluster
from aap_demo.core.errors import AddonError
from aap_demo.exec.runner import CompletedCommand


def _env(app_ctx) -> None:
    app_ctx.env = {
        "APME_EAP_OPENSHIFT_API_URL": "https://api.example.test:6443",
        "APME_EAP_CLUSTER_DOMAIN": "apps.example.test",
        "APME_EAP_AAP_HOST": "https://aap.apps.example.test",
        "APME_EAP_AAP_PASSWORD": "redacted-password",  # pragma: allowlist secret
    }


def _cached_venv(app_ctx) -> None:
    root = Path(__file__).resolve().parents[2] / "addons" / "apme-eap"
    venv = app_ctx.paths.addon_dir("apme-eap") / "venv"
    (venv / "bin").mkdir(parents=True)
    (venv / "bin" / "python").write_text("", encoding="utf-8")
    (venv / ".requirements.sha256").write_text(
        hashlib.sha256((root / "requirements.txt").read_bytes()).hexdigest() + "\n",
        encoding="utf-8",
    )
    (venv / ".collections.sha256").write_text(
        hashlib.sha256((root / "requirements.yml").read_bytes()).hexdigest() + "\n",
        encoding="utf-8",
    )


def _namespace_missing(app_ctx) -> None:
    app_ctx.runner.fail(["kubectl", "get", "namespace", "apme"], stderr="NotFound")


def _registry_ready(app_ctx) -> None:
    app_ctx.runner.ok(["kubectl", "get", "deployment", "registry"])
    app_ctx.runner.ok(["kubectl", "wait", "--for=condition=available", "deployment/registry"])


def test_apme_eap_is_a_public_native_addon() -> None:
    addon = get("apme-eap")

    assert addon.name == "apme-eap"
    assert addon.kind == "native"
    assert addon.public is True
    assert addon.needs_cluster is True
    assert "apme-eap" in names()
    assert needs_cluster("apme-eap") is True


def test_missing_registry_is_bootstrapped_before_apme(app_ctx) -> None:
    app_ctx.runner.fail(
        ["kubectl", "get", "deployment", "registry"],
        stderr="NotFound",
    )
    app_ctx.runner.ok(["kubectl", "apply", "-f", "-"])
    app_ctx.runner.ok(["kubectl", "wait", "--for=condition=available", "deployment/registry"])

    apme_eap._ensure_registry(app_ctx, apme_eap._addon_root())

    apply = next(
        call for call in app_ctx.runner.calls if call.argv[:3] == ("kubectl", "apply", "-f")
    )
    assert "aap-demo-registry" in (apply.input or "")
    assert app_ctx.runner.index_of(["kubectl", "apply"]) < app_ctx.runner.index_of(
        ["kubectl", "wait"]
    )


def test_enable_runs_packaged_playbook_and_records_state(app_ctx, monkeypatch) -> None:
    _env(app_ctx)
    monkeypatch.setattr(
        "aap_demo.addons.apme_eap.shutil.which",
        lambda name: f"/usr/bin/{name}",
    )
    _cached_venv(app_ctx)
    _registry_ready(app_ctx)
    _namespace_missing(app_ctx)
    app_ctx.runner.ok(["~ansible-playbook$"], stdout="completed\n")
    app_ctx.runner.ok(["kubectl", "label", "namespace", "apme"])

    assert get("apme-eap").enable(app_ctx, argparse.Namespace(addon="apme-eap")) == 0

    call = next(call for call in app_ctx.runner.calls if call.argv[0].endswith("/ansible-playbook"))
    assert call.argv[0].endswith("/ansible-playbook")
    assert "playbooks/deploy_apme_portal.yml" in call.argv[1]
    assert call.env["K8S_AUTH_KUBECONFIG"] == str(app_ctx.kubeconfig)
    temp_root = tempfile.gettempdir()
    assert call.env["ANSIBLE_LOCAL_TEMP"].startswith(temp_root)
    assert call.env["ANSIBLE_REMOTE_TEMP"].startswith(temp_root)
    assert app_ctx.runner.index_of(["kubectl", "wait"]) < app_ctx.runner.index_of(
        ["~ansible-playbook$"]
    )
    assert call.cwd.endswith("addons/apme-eap")
    assert app_ctx.config.get("addons.enabled") == ["apme-eap"]
    assert not (app_ctx.paths.addon_dir("apme-eap") / "vars.yml").exists()
    assert "redacted-password" not in app_ctx.console.stdout


def test_failed_enable_does_not_record_state(app_ctx, monkeypatch) -> None:
    _env(app_ctx)
    monkeypatch.setattr(
        "aap_demo.addons.apme_eap.shutil.which",
        lambda name: f"/usr/bin/{name}",
    )
    _cached_venv(app_ctx)
    _registry_ready(app_ctx)
    _namespace_missing(app_ctx)
    app_ctx.runner.fail(["~ansible-playbook$"], stderr="playbook failed")
    app_ctx.runner.ok(["kubectl", "delete", "namespace", "apme"])

    with pytest.raises(AddonError, match="enable apme-eap failed"):
        get("apme-eap").enable(app_ctx, argparse.Namespace(addon="apme-eap"))

    assert app_ctx.config.get("addons.enabled") == []


def test_failed_first_enable_removes_partial_namespace(app_ctx, monkeypatch) -> None:
    _env(app_ctx)
    monkeypatch.setattr(
        "aap_demo.addons.apme_eap.shutil.which",
        lambda name: f"/usr/bin/{name}",
    )
    _cached_venv(app_ctx)
    _registry_ready(app_ctx)
    _namespace_missing(app_ctx)
    app_ctx.runner.fail(["~ansible-playbook$"], stderr="playbook failed")
    app_ctx.runner.ok(["kubectl", "delete", "namespace", "apme"])

    with pytest.raises(AddonError, match="enable apme-eap failed"):
        get("apme-eap").enable(app_ctx, argparse.Namespace(addon="apme-eap"))

    assert app_ctx.runner.called(["kubectl", "delete", "namespace", "apme"])
    assert app_ctx.config.get("addons.enabled") == []


def test_fresh_enable_bootstraps_the_dedicated_venv(app_ctx, monkeypatch) -> None:
    _env(app_ctx)
    monkeypatch.setattr(
        "aap_demo.addons.apme_eap.shutil.which",
        lambda name: f"/usr/bin/{name}",
    )
    venv_dir = app_ctx.paths.addon_dir("apme-eap") / "venv"

    def create_venv(args):
        (venv_dir / "bin").mkdir(parents=True)
        (venv_dir / "bin" / "python").write_text("", encoding="utf-8")
        return CompletedCommand(argv=tuple(args), returncode=0)

    app_ctx.runner.register(["python3", "-m", "venv"], create_venv)
    app_ctx.runner.ok([str(venv_dir / "bin" / "python"), "-m", "pip"])
    app_ctx.runner.ok([str(venv_dir / "bin" / "ansible-galaxy"), "collection"])

    assert apme_eap._ensure_venv(app_ctx, apme_eap._addon_root()) == venv_dir / "bin" / "python"
    assert (venv_dir / ".requirements.sha256").is_file()
    assert (venv_dir / ".collections.sha256").is_file()


def test_apme_helm_bootstrap_selects_architecture_specific_client() -> None:
    root = Path(__file__).resolve().parents[2]
    defaults = (
        root
        / "addons"
        / "apme-eap"
        / "playbooks"
        / "roles"
        / "apme_helm_bootstrap"
        / "defaults"
        / "main.yml"
    ).read_text(encoding="utf-8")

    assert "apme_helm_bootstrap_platform: >-" in defaults
    assert "apme_helm_bootstrap_arch: >-" in defaults
    assert "apme_helm_bootstrap_platform ~ '-' ~ apme_helm_bootstrap_arch" in defaults
    assert "aarch64" in defaults
    assert "linux-amd64.tar.gz" not in defaults


def test_crc_portal_url_and_custom_aap_secret_are_discovered(app_ctx) -> None:
    app_ctx.env = {
        "APME_EAP_OPENSHIFT_API_URL": "https://api.crc.testing:6443",
        "APME_EAP_CLUSTER_DOMAIN": "crc.testing",
        "APME_EAP_AAP_NAMESPACE": "custom-aap",
        "APME_EAP_AAP_CR_NAME": "demo",
    }
    app_ctx.runner.ok(
        ["kubectl", "get", "route", "-n", "custom-aap"],
        stdout="aap.apps.crc.testing",
    )
    app_ctx.runner.ok(
        ["kubectl", "get", "secret", "demo-admin-password"],
        stdout=json.dumps({"data": {"password": "c2VjcmV0"}}),
    )

    values = apme_eap._discover_vars(app_ctx)

    assert values["aap_host_url"] == "http://aap.apps.crc.testing"
    assert values["aap_password"] == "secret"  # pragma: allowlist secret
    assert values["openshift_validate_certs"] is True


def test_cluster_domain_falls_back_to_aap_route_on_microshift(app_ctx) -> None:
    app_ctx.env = {
        "APME_EAP_OPENSHIFT_API_URL": "https://api.example.test:6443",
        "APME_EAP_AAP_HOST": "https://aap-aap-operator.apps.example.test",
        "APME_EAP_AAP_PASSWORD": "password",  # pragma: allowlist secret
    }
    app_ctx.runner.fail(
        ["kubectl", "get", "route", "-n", "openshift-console"],
        stderr='namespaces "openshift-console" not found',
    )

    values = apme_eap._discover_vars(app_ctx)

    assert values["openshift_cluster_domain"] == "apps.example.test"


def test_user_overrides_survive_and_run_vars_are_ephemeral(app_ctx) -> None:
    _env(app_ctx)
    user_vars = app_ctx.paths.addon_dir("apme-eap") / "vars.yml"
    user_vars.parent.mkdir(parents=True)
    user_vars.write_text("custom_setting: preserved\n", encoding="utf-8")

    path = apme_eap._write_run_vars(app_ctx, {"aap_password": "secret"})
    assert path.stat().st_mode & 0o777 == 0o600
    values = yaml.safe_load(path.read_text(encoding="utf-8"))
    assert values == {
        "aap_password": "secret",  # pragma: allowlist secret
        "custom_setting": "preserved",
    }
    path.unlink()
    assert user_vars.read_text(encoding="utf-8") == "custom_setting: preserved\n"


def test_disable_removes_owned_namespace_and_state(app_ctx) -> None:
    state_dir = app_ctx.paths.addon_dir("apme-eap")
    state_dir.mkdir(parents=True)
    (state_dir / "vars.yml").write_text("custom: true\n", encoding="utf-8")
    app_ctx.config.set("addons.enabled", ["apme-eap", "fleet"])
    app_ctx.runner.ok(
        ["kubectl", "get", "namespace", "apme"],
        stdout=json.dumps(
            {"metadata": {"labels": {"app.kubernetes.io/managed-by": "aap-demo-apme-eap"}}}
        ),
    )
    app_ctx.runner.ok(["kubectl", "delete", "namespace", "apme"])

    assert get("apme-eap").disable(app_ctx, argparse.Namespace(addon="apme-eap")) == 0

    assert app_ctx.runner.called(["kubectl", "delete", "namespace", "apme"])
    assert app_ctx.config.get("addons.enabled") == ["fleet"]
    assert (state_dir / "vars.yml").is_file()


def test_disable_refuses_unowned_namespace(app_ctx) -> None:
    app_ctx.runner.ok(
        ["kubectl", "get", "namespace", "apme"],
        stdout=json.dumps({"metadata": {"labels": {"owner": "someone-else"}}}),
    )

    with pytest.raises(AddonError, match="unowned namespace"):
        get("apme-eap").disable(app_ctx, argparse.Namespace(addon="apme-eap"))

    assert not app_ctx.runner.called(["kubectl", "delete", "namespace", "apme"])


def test_status_requires_ready_deployments(app_ctx) -> None:
    app_ctx.runner.ok(
        ["kubectl", "get", "namespace", "apme"],
        stdout=json.dumps(
            {"metadata": {"labels": {"app.kubernetes.io/managed-by": "aap-demo-apme-eap"}}}
        ),
    )
    app_ctx.runner.ok(
        ["kubectl", "get", "deployments", "-n", "apme"],
        stdout=json.dumps({"items": [{"status": {"availableReplicas": 0}}]}),
    )

    assert get("apme-eap").status(app_ctx, argparse.Namespace()) == 1
