"""Native V2 execution for the APME Early Access addon."""

from __future__ import annotations

import argparse
import base64
import json
import shutil
from pathlib import Path
from typing import Any, Dict

import yaml

import aap_demo
from aap_demo.addons.base import AddonKind
from aap_demo.addons.common.state import enabled_names, set_enabled_names
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError, PrerequisiteError
from aap_demo.core.output import is_structured, render

NAME = "apme-eap"
NAMESPACE = "apme"
_TOOLS = ("ansible-playbook", "kubectl")


def _addon_root() -> Path:
    package = Path(aap_demo.__file__).resolve().parent
    checkout = package.parents[1]
    checkout_root = checkout / "addons" / NAME
    if (checkout / "pyproject.toml").is_file() and (checkout_root / "defaults.yml").is_file():
        return checkout_root
    bundled_root = package / "bundled_addons" / NAME
    if (bundled_root / "defaults.yml").is_file():
        return bundled_root
    raise AddonError("APME addon files are not included in this aap-demo installation")


def _state_dir(ctx: AppContext) -> Path:
    return ctx.paths.addon_dir(NAME)


def _vars_path(ctx: AppContext) -> Path:
    return _state_dir(ctx) / "vars.yml"


def _require_tools() -> None:
    missing = [tool for tool in _TOOLS if shutil.which(tool) is None]
    if missing:
        raise PrerequisiteError(
            "apme-eap requires " + ", ".join(missing),
            hint="Install the missing tools and run aap-demo enable apme-eap again.",
        )


def _env_or_discover(ctx: AppContext, env_name: str, command: list[str]) -> str:
    value = str(ctx.env.get(env_name, "") or "").strip()
    if value:
        return value
    result = ctx.runner.run(command)
    if not result.ok or not result.stdout.strip():
        raise AddonError(
            f"could not discover {env_name}",
            hint=(result.stderr or result.stdout).strip() or None,
        )
    return result.stdout.strip()


def _discover_vars(ctx: AppContext) -> Dict[str, Any]:
    api_url = _env_or_discover(
        ctx,
        "APME_EAP_OPENSHIFT_API_URL",
        ["kubectl", "config", "view", "--minify", "-o", "jsonpath={.clusters[0].cluster.server}"],
    )
    aap_route = _env_or_discover(
        ctx,
        "APME_EAP_AAP_HOST",
        ["kubectl", "get", "route", "-n", "aap-operator", "-o", "jsonpath={.items[0].spec.host}"],
    )
    if not aap_route.startswith("http"):
        aap_route = "https://" + aap_route
    domain = _env_or_discover(
        ctx,
        "APME_EAP_CLUSTER_DOMAIN",
        [
            "kubectl",
            "get",
            "route",
            "-n",
            "openshift-console",
            "console",
            "-o",
            "jsonpath={.spec.host}",
        ],
    )
    if domain.startswith("console-openshift-console."):
        domain = domain.removeprefix("console-openshift-console.")
    password = str(ctx.env.get("APME_EAP_AAP_PASSWORD", "") or "")
    if not password:
        result = ctx.runner.run(
            [
                "kubectl",
                "get",
                "secret",
                "aap-admin-password",
                "-n",
                ctx.namespace,
                "-o",
                "json",
            ]
        )
        if not result.ok:
            raise AddonError(
                "could not read the AAP admin password Secret",
                hint=(result.stderr or result.stdout).strip() or None,
            )
        try:
            data = json.loads(result.stdout)["data"]
            password = base64.b64decode(data["password"]).decode("utf-8")
        except (KeyError, TypeError, ValueError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise AddonError("AAP admin password Secret has no usable password") from exc
    return {
        "openshift_api_url": api_url,
        "openshift_project_name": NAMESPACE,
        "openshift_cluster_domain": domain,
        "openshift_validate_certs": False,
        "aap_host": aap_route,
        "aap_host_url": aap_route,
        "aap_username": "admin",
        "aap_password": password,
        "oci_registry": f"registry.{domain}/apme",
        "oci_registry_internal": "registry.aap-demo-registry.svc.cluster.local:5000/apme",
    }


def _write_vars(ctx: AppContext) -> Path:
    path = _vars_path(ctx)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(_discover_vars(ctx), sort_keys=False), encoding="utf-8")
    path.chmod(0o600)
    return path


def _say(ctx: AppContext, message: str, **fields: object) -> None:
    if is_structured(ctx.output):
        render(ctx.console, {"message": message, **fields}, output=ctx.output)
    else:
        ctx.console.out(message)


class ApmeEapAddon:
    name = NAME
    kind: AddonKind = "native"
    public = True
    needs_cluster = True

    def enable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        del args
        _require_tools()
        root = _addon_root()
        if not (root / "playbooks" / "deploy_apme_portal.yml").is_file():
            raise AddonError("APME addon playbooks are not included in this installation")
        vars_path = _write_vars(ctx)
        env = ctx.kube_env()
        env["K8S_AUTH_KUBECONFIG"] = str(ctx.kubeconfig)
        result = ctx.runner.run(
            [
                "ansible-playbook",
                str(root / "playbooks" / "deploy_apme_portal.yml"),
                "-e",
                f"@{root / 'defaults.yml'}",
                "-e",
                f"@{vars_path}",
            ],
            env=env,
            cwd=str(root),
            sink=ctx.console.log_sink(),
        )
        if not result.ok:
            raise AddonError(
                "enable apme-eap failed",
                hint=(result.stderr or result.stdout).strip() or None,
            )
        names = enabled_names(ctx)
        if NAME not in names:
            names.append(NAME)
        set_enabled_names(ctx, names, save=True)
        _say(ctx, "APME enabled", namespace=NAMESPACE)
        return 0

    def disable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        purge = "--purge-creds" in list(getattr(args, "addon_args", None) or [])
        result = ctx.runner.run(
            ["kubectl", "delete", "namespace", NAMESPACE, "--ignore-not-found=true"]
        )
        if not result.ok:
            raise AddonError(
                "could not remove apme-eap namespace",
                hint=(result.stderr or result.stdout).strip() or None,
            )
        names = [name for name in enabled_names(ctx) if name != NAME]
        set_enabled_names(ctx, names, save=True)
        state_dir = _state_dir(ctx)
        if purge and state_dir.exists():
            shutil.rmtree(state_dir)
        elif _vars_path(ctx).exists():
            _vars_path(ctx).unlink()
        if state_dir.exists() and not any(state_dir.iterdir()):
            state_dir.rmdir()
        _say(ctx, "APME disabled", namespace=NAMESPACE)
        return 0

    def destroy(self, ctx: AppContext, args: argparse.Namespace) -> int:
        return self.disable(ctx, args)

    def status(self, ctx: AppContext, args: argparse.Namespace) -> int:
        del args
        result = ctx.runner.run(["kubectl", "get", "namespace", NAMESPACE])
        ready = result.ok
        _say(ctx, "APME status", namespace=NAMESPACE, readiness="present" if ready else "absent")
        return 0 if ready else 1
