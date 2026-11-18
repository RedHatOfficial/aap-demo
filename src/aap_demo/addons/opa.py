"""Native Python v2 addon for AAP Policy as Code with Open Policy Agent."""

from __future__ import annotations

import argparse
from typing import Any, Dict, Mapping

import yaml

from aap_demo.addons.base import AddonKind
from aap_demo.addons.common import ee, gateway, kube, playbook_job
from aap_demo.addons.common.state import enabled_names, options_for, save_options_for
from aap_demo.addons.opa_playbooks import playbook_files
from aap_demo.addons.opa_resources import owned, resource_documents, resource_names
from aap_demo.cluster import aap as aap_mod
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError

DEFAULTS = {
    "opa_version": "1.20.2",
    "opa_repo": "https://github.com/ansible/example-opa-policy-for-aap",
    "opa_manifest_ref": "8dad3022d5",
    "aap_demo_repo": "https://github.com/RedHatOfficial/aap-demo.git",
    "aap_demo_branch": "main",
}
ENV_NAMES = {
    "opa_version": "OPA_VERSION",
    "opa_repo": "OPA_REPO",
    "opa_manifest_ref": "OPA_MANIFEST_REF",
    "aap_demo_repo": "AAP_DEMO_REPO",
    "aap_demo_branch": "AAP_DEMO_BRANCH",
}
POLICY_PLAYBOOKS = {
    "load": "load-policies.yml",
    "test": "test-policies.yml",
    "clear": "clear-policies.yml",
    "demo": "demo-policy.yml",
}


class OpaAddon:
    name = "opa"
    kind: AddonKind = "native"
    public = True
    needs_cluster = True

    def enable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        del args
        options = _options(ctx)
        route_host = _route_host(ctx)
        _ensure_owned(ctx)
        was_enabled = self.name in enabled_names(ctx)
        applied = False
        try:
            documents = resource_documents(ctx.namespace, options["opa_version"], route_host)
            _apply_resources(ctx, documents)
            applied = True
            _wait_ready(ctx)
            _run_bootstrap(ctx, options, "present")
        except Exception:
            if applied and not was_enabled:
                try:
                    _run_bootstrap(ctx, options, "absent")
                except Exception:
                    pass
                try:
                    _delete_resources(ctx)
                except Exception:
                    pass
            raise
        save_options_for(ctx, self.name, options)
        _remember_enabled(ctx)
        _say(
            ctx,
            "OPA addon enabled successfully",
            service=f"http://opa.{ctx.namespace}.svc.cluster.local:8181",
            route=f"https://{route_host}",
        )
        return 0

    def disable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        del args
        options = _options(ctx)
        _ensure_owned(ctx)
        _run_bootstrap(ctx, options, "absent")
        _delete_resources(ctx)
        _forget_enabled(ctx)
        _say(ctx, "OPA addon disabled successfully")
        return 0


def _options(ctx: AppContext) -> Dict[str, str]:
    saved = options_for(ctx, "opa")
    values: Dict[str, str] = {}
    for key, default in DEFAULTS.items():
        value = saved.get(key) or ctx.env.get(ENV_NAMES[key]) or default
        values[key] = str(value)
    return values


def _route_host(ctx: AppContext) -> str:
    result = ctx.runner.run(
        ["kubectl", "get", "route", "aap", "-n", ctx.namespace, "-o", "jsonpath={.spec.host}"]
    )
    if not result.ok or not result.stdout.strip():
        raise AddonError(
            "could not find the AAP route",
            hint=f"kubectl get route aap -n {ctx.namespace}",
        )
    host = result.stdout.strip()
    parts = host.split(".", 1)
    return f"opa.{parts[1]}" if len(parts) == 2 else f"opa-{ctx.namespace}.{host}"


def _ensure_owned(ctx: AppContext) -> None:
    for resource in resource_names():
        kind, name = resource.split("/", 1)
        document = kube.read_object(ctx, kind, name, namespace=ctx.namespace)
        if document is not None and not owned(document):
            raise AddonError(
                "refusing to use unowned OPA resource",
                hint=f"kubectl get {kind} {name} -n {ctx.namespace} -o yaml",
            )


def _apply_resources(ctx: AppContext, documents: list[dict]) -> None:
    manifest = yaml.safe_dump_all(documents, sort_keys=False)
    kube.apply_or_raise(ctx, manifest, message="could not apply OPA resources")


def _wait_ready(ctx: AppContext) -> None:
    result = ctx.runner.run(
        [
            "kubectl",
            "rollout",
            "status",
            "deployment/opa",
            "-n",
            ctx.namespace,
            "--timeout=120s",
        ]
    )
    if result.ok:
        return
    raise AddonError(
        "OPA deployment failed to become ready",
        hint=(
            f"{result.stderr or result.stdout or 'kubectl rollout failed'}\n"
            f"kubectl get pods -n {ctx.namespace} -l app=opa\n"
            f"kubectl logs -n {ctx.namespace} -l app=opa"
        ),
    )


def _delete_resources(ctx: AppContext) -> None:
    failures = []
    for resource in resource_names():
        kind, name = resource.split("/", 1)
        result = ctx.runner.run(
            ["kubectl", "delete", kind, name, "-n", ctx.namespace, "--ignore-not-found"]
        )
        if not result.ok:
            failures.append(result.stderr or result.stdout or resource)
    if failures:
        raise AddonError("could not delete OPA resources", hint="\n".join(failures))


def _run_bootstrap(ctx: AppContext, options: Mapping[str, str], state: str) -> None:
    job = _bootstrap_job(ctx, options, state)
    playbook_job.run(ctx, job)


def _bootstrap_job(
    ctx: AppContext, options: Mapping[str, str], state: str
) -> playbook_job.PlaybookJob:
    gateway_url = gateway.gateway_url(ctx)
    password = aap_mod.admin_password(ctx, gateway.aap_namespace(ctx))
    if not password:
        raise AddonError(
            "AAP admin password was empty",
            hint=f"kubectl get secrets -n {gateway.aap_namespace(ctx)}",
        )
    files = playbook_files()
    extra_vars: Dict[str, Any] = {
        "gateway_url": gateway_url,
        "aap_hostname": gateway_url,
        "aap_username": "admin",
        "aap_password": password,
        "opa_server": f"http://opa.{ctx.namespace}.svc.cluster.local:8181",
        "opa_repo": options["opa_repo"],
        "opa_ref": options["opa_manifest_ref"],
        "aap_demo_repo": options["aap_demo_repo"],
        "aap_demo_branch": options["aap_demo_branch"],
        "namespace": ctx.namespace,
        "state": state,
        "policy_playbooks": POLICY_PLAYBOOKS,
    }
    return playbook_job.PlaybookJob(
        label="OPA",
        name="aap-demo-opa-bootstrap",
        namespace=ctx.namespace,
        image=ee.discover_image(ctx, addon="opa"),
        playbook="bootstrap.yml",
        purpose="configuring AAP Policy as Code",
        files=files,
        extra_vars=extra_vars,
        mount_root="/opt/aap-demo-opa",
        pull_secret_source=ctx.namespace,
    )


def _remember_enabled(ctx: AppContext) -> None:
    names = enabled_names(ctx)
    if "opa" not in names:
        names.append("opa")
    ctx.config.set("addons.enabled", names)
    ctx.config.save()


def _forget_enabled(ctx: AppContext) -> None:
    ctx.config.set("addons.enabled", [name for name in enabled_names(ctx) if name != "opa"])
    ctx.config.save()


def _say(ctx: AppContext, message: str, **fields: object) -> None:
    if ctx.output in ("json", "yaml"):
        from aap_demo.core.output import render

        render(ctx.console, {"message": message, **fields}, output=ctx.output)
        return
    ctx.console.out(message)
    for key, value in fields.items():
        ctx.console.out(f"  {key.replace('_', ' ').title()}: {value}")
