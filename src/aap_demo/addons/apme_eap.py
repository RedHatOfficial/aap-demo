"""Native V2 execution for the APME Early Access addon."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, Mapping

import yaml

import aap_demo
from aap_demo.addons.base import AddonKind
from aap_demo.addons.common import kube
from aap_demo.addons.common.state import enabled_names, set_enabled_names
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError, PrerequisiteError
from aap_demo.core.output import is_structured, render

NAME = "apme-eap"
NAMESPACE = "apme"
_TOOLS = ("python3", "kubectl")
_OWNER_LABEL = "app.kubernetes.io/managed-by"
_OWNER_VALUE = "aap-demo-apme-eap"


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


def _user_vars_path(ctx: AppContext) -> Path:
    return _state_dir(ctx) / "vars.yml"


def _venv_dir(ctx: AppContext) -> Path:
    return _state_dir(ctx) / "venv"


def _venv_python(ctx: AppContext) -> Path:
    if sys.platform == "win32":
        return _venv_dir(ctx) / "Scripts" / "python.exe"
    return _venv_dir(ctx) / "bin" / "python"


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


def _hash_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _ensure_venv(ctx: AppContext, root: Path) -> Path:
    state_dir = _state_dir(ctx)
    state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    state_dir.chmod(0o700)
    venv_dir = _venv_dir(ctx)
    python = _venv_python(ctx)
    if not python.is_file():
        result = ctx.runner.run(["python3", "-m", "venv", str(venv_dir)])
        if not result.ok:
            raise AddonError(
                "could not create the APME Python environment",
                hint=(result.stderr or result.stdout).strip() or None,
            )
    if not python.is_file():
        raise AddonError("APME Python environment was not created")
    requirements = root / "requirements.txt"
    requirements_hash = _hash_file(requirements)
    requirements_stamp = venv_dir / ".requirements.sha256"
    installed_requirements = (
        requirements_stamp.read_text(encoding="utf-8").strip()
        if requirements_stamp.exists()
        else ""
    )
    if installed_requirements != requirements_hash:
        result = ctx.runner.run(
            [str(python), "-m", "pip", "install", "--quiet", "-r", str(requirements)]
        )
        if not result.ok:
            raise AddonError(
                "could not install APME Python requirements",
                hint=(result.stderr or result.stdout).strip() or None,
            )
        requirements_stamp.write_text(requirements_hash + "\n", encoding="utf-8")
    collections = root / "requirements.yml"
    collections_hash = _hash_file(collections)
    collections_stamp = venv_dir / ".collections.sha256"
    installed_collections = (
        collections_stamp.read_text(encoding="utf-8").strip() if collections_stamp.exists() else ""
    )
    if installed_collections != collections_hash:
        galaxy = python.parent / (
            "ansible-galaxy.exe" if sys.platform == "win32" else "ansible-galaxy"
        )
        result = ctx.runner.run(
            [
                str(galaxy),
                "collection",
                "install",
                "-r",
                str(collections),
            ]
        )
        if not result.ok:
            raise AddonError(
                "could not install APME Ansible collections",
                hint=(result.stderr or result.stdout).strip() or None,
            )
        collections_stamp.write_text(collections_hash + "\n", encoding="utf-8")
    return python


def _aap_namespace(ctx: AppContext) -> str:
    return str(ctx.env.get("APME_EAP_AAP_NAMESPACE") or ctx.namespace)


def _discover_vars(ctx: AppContext) -> Dict[str, Any]:
    aap_namespace = _aap_namespace(ctx)
    api_url = _env_or_discover(
        ctx,
        "APME_EAP_OPENSHIFT_API_URL",
        ["kubectl", "config", "view", "--minify", "-o", "jsonpath={.clusters[0].cluster.server}"],
    )
    aap_route = _env_or_discover(
        ctx,
        "APME_EAP_AAP_HOST",
        ["kubectl", "get", "route", "-n", aap_namespace, "-o", "jsonpath={.items[0].spec.host}"],
    )
    if not aap_route.startswith("http"):
        aap_route = "https://" + aap_route
    domain = str(ctx.env.get("APME_EAP_CLUSTER_DOMAIN", "") or "").strip()
    if not domain:
        console = ctx.runner.run(
            [
                "kubectl",
                "get",
                "route",
                "-n",
                "openshift-console",
                "console",
                "-o",
                "jsonpath={.spec.host}",
            ]
        )
        if console.ok and console.stdout.strip():
            domain = console.stdout.strip()
        else:
            route_host = aap_route.removeprefix("https://").removeprefix("http://")
            if "." not in route_host:
                raise AddonError(
                    "could not discover APME_EAP_CLUSTER_DOMAIN",
                    hint=(console.stderr or console.stdout).strip() or None,
                )
            domain = route_host.split(".", 1)[1]
    if domain.startswith("console-openshift-console."):
        domain = domain.removeprefix("console-openshift-console.")
    password = str(ctx.env.get("APME_EAP_AAP_PASSWORD", "") or "")
    if not password:
        aap_cr = _env_or_discover(
            ctx,
            "APME_EAP_AAP_CR_NAME",
            [
                "kubectl",
                "get",
                "aap",
                "-n",
                aap_namespace,
                "-o",
                "jsonpath={.items[0].metadata.name}",
            ],
        )
        result = ctx.runner.run(
            [
                "kubectl",
                "get",
                "secret",
                f"{aap_cr}-admin-password",
                "-n",
                aap_namespace,
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
        "openshift_validate_certs": str(ctx.env.get("APME_EAP_VALIDATE_CERTS", "true")).lower()
        not in {"0", "false", "no"},
        "aap_host": aap_route,
        "aap_host_url": _portal_host_url(aap_route, domain),
        "aap_username": "admin",
        "aap_password": password,
        "oci_registry": f"registry.{domain}/apme",
        "oci_registry_internal": "registry.aap-demo-registry.svc.cluster.local:5000/apme",
    }


def _portal_host_url(aap_host: str, cluster_domain: str) -> str:
    host = aap_host.removeprefix("https://").removeprefix("http://").rstrip("/")
    if cluster_domain == "crc.testing" or cluster_domain.endswith(".crc.testing"):
        return f"http://{host}"
    return aap_host.rstrip("/")


def _load_user_vars(ctx: AppContext) -> Dict[str, Any]:
    path = _user_vars_path(ctx)
    if not path.exists():
        return {}
    try:
        value = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError) as exc:
        raise AddonError("could not read the APME vars file", hint=str(exc)) from exc
    if not isinstance(value, dict):
        raise AddonError("the APME vars file must contain a YAML mapping")
    return value


def _write_run_vars(ctx: AppContext, generated: Mapping[str, Any]) -> Path:
    state_dir = _state_dir(ctx)
    state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    state_dir.chmod(0o700)
    merged = dict(generated)
    merged.update(_load_user_vars(ctx))
    fd, raw_path = tempfile.mkstemp(prefix=".run-vars.", suffix=".yml", dir=state_dir)
    path = Path(raw_path)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", closefd=True) as handle:
            handle.write(yaml.safe_dump(merged, sort_keys=False))
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    return path


def _namespace_owned(ctx: AppContext) -> bool:
    namespace = kube.read_object(ctx, "namespace", NAMESPACE)
    if namespace is None:
        return False
    labels = namespace.get("metadata", {}).get("labels", {})
    return labels.get(_OWNER_LABEL) == _OWNER_VALUE


def _claim_namespace(ctx: AppContext) -> None:
    namespace = kube.read_object(ctx, "namespace", NAMESPACE)
    if namespace is not None and not _namespace_owned(ctx):
        raise AddonError(
            f"refusing to use unowned namespace {NAMESPACE!r}",
            hint="Choose another APME namespace or remove the existing namespace first.",
        )


def _label_namespace(ctx: AppContext) -> None:
    result = ctx.runner.run(
        [
            "kubectl",
            "label",
            "namespace",
            NAMESPACE,
            f"{_OWNER_LABEL}={_OWNER_VALUE}",
            "--overwrite",
        ]
    )
    if not result.ok:
        raise AddonError(
            "could not mark the APME namespace as addon-owned",
            hint=(result.stderr or result.stdout).strip() or None,
        )


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
        _claim_namespace(ctx)
        ansible_python = _ensure_venv(ctx, root)
        vars_path = _write_run_vars(ctx, _discover_vars(ctx))
        env = ctx.kube_env()
        env["K8S_AUTH_KUBECONFIG"] = str(ctx.kubeconfig)
        try:
            result = ctx.runner.run(
                [
                    str(ansible_python.parent / "ansible-playbook"),
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
        finally:
            vars_path.unlink(missing_ok=True)
        if not result.ok:
            raise AddonError(
                "enable apme-eap failed",
                hint=(result.stderr or result.stdout).strip() or None,
            )
        _label_namespace(ctx)
        names = enabled_names(ctx)
        if NAME not in names:
            names.append(NAME)
        set_enabled_names(ctx, names, save=True)
        _say(ctx, "APME enabled", namespace=NAMESPACE)
        return 0

    def disable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        del args
        namespace = kube.read_object(ctx, "namespace", NAMESPACE)
        if namespace is not None and not _namespace_owned(ctx):
            raise AddonError(
                f"refusing to delete unowned namespace {NAMESPACE!r}",
                hint="The namespace is not labeled as managed by the APME addon.",
            )
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
        _say(ctx, "APME disabled", namespace=NAMESPACE)
        return 0

    def destroy(self, ctx: AppContext, args: argparse.Namespace) -> int:
        return self.disable(ctx, args)

    def status(self, ctx: AppContext, args: argparse.Namespace) -> int:
        del args
        namespace = kube.read_object(ctx, "namespace", NAMESPACE)
        if namespace is None:
            _say(ctx, "APME status", namespace=NAMESPACE, readiness="absent")
            return 1
        result = ctx.runner.run(["kubectl", "get", "deployments", "-n", NAMESPACE, "-o", "json"])
        deployments = []
        if result.ok:
            try:
                deployments = json.loads(result.stdout or "{}").get("items", [])
            except json.JSONDecodeError:
                deployments = []
        ready = bool(deployments) and all(
            int(item.get("status", {}).get("availableReplicas", 0) or 0) > 0 for item in deployments
        )
        _say(ctx, "APME status", namespace=NAMESPACE, readiness="ready" if ready else "not-ready")
        return 0 if ready else 1
