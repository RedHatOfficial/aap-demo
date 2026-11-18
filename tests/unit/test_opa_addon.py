"""The OPA addon uses the native v2 boundary."""

from __future__ import annotations

import argparse
from pathlib import Path

import pytest

from aap_demo.addons import get
from aap_demo.addons import opa as opa_mod
from aap_demo.core.errors import AddonError


def _args() -> argparse.Namespace:
    return argparse.Namespace(addon="opa", addon_args=[])


def _stub_flow(monkeypatch: pytest.MonkeyPatch, *, bootstrap=None) -> list:
    jobs = []
    monkeypatch.setattr("aap_demo.addons.opa._route_host", lambda ctx: "opa.apps.example.test")
    monkeypatch.setattr("aap_demo.addons.opa._ensure_owned", lambda ctx: None)
    monkeypatch.setattr("aap_demo.addons.opa._apply_resources", lambda ctx, documents: None)
    monkeypatch.setattr("aap_demo.addons.opa._wait_ready", lambda ctx: None)
    monkeypatch.setattr("aap_demo.addons.opa._delete_resources", lambda ctx: None)
    monkeypatch.setattr(
        "aap_demo.addons.opa._run_bootstrap",
        bootstrap or (lambda ctx, options, state: jobs.append((options, state))),
    )
    return jobs


def test_opa_is_native_and_public() -> None:
    addon = get("opa")
    assert (addon.kind, addon.public, addon.needs_cluster) == ("native", True, True)


def test_enable_records_state_only_after_bootstrap(app_ctx, monkeypatch) -> None:
    jobs = _stub_flow(monkeypatch)
    assert get("opa").enable(app_ctx, _args()) == 0
    assert app_ctx.config.get("addons.enabled") == ["opa"]
    assert jobs and jobs[0][1] == "present"


def test_second_enable_keeps_one_state_entry(app_ctx, monkeypatch) -> None:
    _stub_flow(monkeypatch)
    get("opa").enable(app_ctx, _args())
    get("opa").enable(app_ctx, _args())
    assert app_ctx.config.get("addons.enabled") == ["opa"]


def test_bootstrap_failure_keeps_state_disabled(app_ctx, monkeypatch) -> None:
    def fail(_ctx, _options, _state):
        raise AddonError("bootstrap failed", hint="job log")

    _stub_flow(monkeypatch, bootstrap=fail)
    with pytest.raises(AddonError, match="bootstrap failed"):
        get("opa").enable(app_ctx, _args())
    assert app_ctx.config.get("addons.enabled") == []


def test_disable_refuses_unowned_service(app_ctx, monkeypatch) -> None:
    monkeypatch.setattr("aap_demo.addons.opa._route_host", lambda ctx: "opa.apps.example.test")
    app_ctx.runner.ok(
        ["kubectl", "get", "deployment", "opa"],
        stdout='{"metadata":{"labels":{"app":"opa","app.kubernetes.io/managed-by":"other"}}}',
    )
    with pytest.raises(AddonError, match="unowned OPA resource"):
        get("opa").disable(app_ctx, _args())


def test_password_is_absent_from_output_and_error(app_ctx, monkeypatch) -> None:
    password = "super-secret-password"  # pragma: allowlist secret

    def fail(_ctx, _options, _state):
        raise AddonError("bootstrap failed", hint="job log")

    _stub_flow(monkeypatch, bootstrap=fail)
    monkeypatch.setattr("aap_demo.addons.opa.aap_mod.admin_password", lambda ctx, ns: password)
    with pytest.raises(AddonError) as excinfo:
        get("opa").enable(app_ctx, _args())
    output = app_ctx.console.stdout + app_ctx.console.stderr
    assert password not in output
    assert password not in str(excinfo.value)


def test_bootstrap_job_keeps_password_in_secret_backed_extra_vars(app_ctx, monkeypatch) -> None:
    password = "super-secret-password"  # pragma: allowlist secret
    monkeypatch.setattr("aap_demo.addons.opa.gateway.gateway_url", lambda ctx: "https://aap.apps.test")
    monkeypatch.setattr("aap_demo.addons.opa.aap_mod.admin_password", lambda ctx, ns: password)
    monkeypatch.setattr(
        "aap_demo.addons.opa.ee.discover_image",
        lambda ctx, addon: (
            "registry.redhat.io/ansible-automation-platform-25/"
            "ee-supported-rhel8:latest"
        ),
    )
    job = opa_mod._bootstrap_job(app_ctx, opa_mod.DEFAULTS, "present")
    assert job.extra_vars["aap_password"] == password
    assert job.playbook == "bootstrap.yml"
    assert set(job.files) == {
        "bootstrap.yml",
        "load-policies.yml",
        "test-policies.yml",
        "clear-policies.yml",
        "demo-policy.yml",
    }


def test_packaged_opa_playbooks_are_in_the_checkout() -> None:
    root = Path(__file__).resolve().parents[2]
    assert (root / "addons/opa/playbooks/bootstrap.yml").is_file()
