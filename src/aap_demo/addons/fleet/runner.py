"""Build extra-vars and run the fleet playbooks through the command runner."""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Any, Dict, List

import yaml

from aap_demo.addons.fleet import images, resources
from aap_demo.core.context import AppContext
from aap_demo.core.errors import PrerequisiteError


def ansible_playbook() -> str:
    binary = shutil.which("ansible-playbook")
    if not binary:
        raise PrerequisiteError(
            "ansible-playbook is required for the fleet addon.\n"
            "pip install ansible-core\n"
            f"ansible-galaxy collection install -r {resources.requirements()}",
        )
    return binary


def run_playbook(
    ctx: AppContext,
    playbook: Path,
    extra: Dict[str, Any],
) -> None:
    """Write extra-vars mode 0600, run the playbook, then delete the file."""
    directory = ctx.paths.addon_dir("fleet")
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "extra-vars.yml"
    text = yaml.safe_dump(extra, sort_keys=False)
    try:
        path.write_text(text, encoding="utf-8")
        os.chmod(path, 0o600)
        binary = ansible_playbook()
        env = dict(ctx.env)
        env["KUBECONFIG"] = str(ctx.paths.kubeconfig)
        env.pop("ANSIBLE_CONFIG", None)
        result = ctx.runner.run(
            [binary, str(playbook), "-e", f"@{path}"],
            env=env,
            capture=False,
        )
        if not result.ok:
            from aap_demo.core.errors import AddonError

            raise AddonError(
                f"playbook failed: {playbook.name}",
                hint=(result.stderr or result.stdout or "").strip() or None,
            )
    finally:
        path.unlink(missing_ok=True)


def base_vars(
    ctx: AppContext,
    nodes: List[Dict[str, str]],
    *,
    state: str,
    scope: str,
    public_key: str,
) -> Dict[str, Any]:
    from aap_demo.addons.fleet.state import namespace_for

    pull = ""
    secret = ctx.paths.pull_secret
    if secret.is_file() and any(node["os"] == "ubi9" for node in nodes):
        pull = str(secret)
    return {
        "namespace": namespace_for(ctx),
        "nodes": nodes,
        "images": dict(images.IMAGES),
        "ssh_public_key": public_key,
        "state": state,
        "scope": scope,
        "pull_secret_path": pull,
        "entrypoint_path": str(resources.entrypoint()),
    }


def import_vars(
    ctx: AppContext,
    nodes: List[Dict[str, str]],
    *,
    state: str,
    private_key: str,
    manage_inventory: bool,
) -> Dict[str, Any]:
    from aap_demo.addons.fleet import gateway
    from aap_demo.addons.fleet.state import fleet_options, namespace_for
    from aap_demo.cluster import aap as aap_mod
    from aap_demo.core.errors import AddonError

    options = fleet_options(ctx)
    hostname = gateway.gateway_url(ctx)
    password = aap_mod.admin_password(ctx, gateway.aap_namespace(ctx))
    if not hostname:
        raise AddonError("gateway hostname was empty", hint="kubectl get route")
    if not password:
        raise AddonError(
            "admin password was empty",
            hint="kubectl get secret -n " + gateway.aap_namespace(ctx),
        )
    return {
        "namespace": namespace_for(ctx),
        "nodes": nodes,
        "state": state,
        "manage_inventory": manage_inventory,
        "ssh_private_key": private_key,
        "aap_hostname": hostname,
        "aap_username": "admin",
        "aap_password": password,
        "aap_validate_certs": False,
        "scm_url": str(options.get("scm_url") or images.SCM_URL),
        "scm_branch": str(options.get("scm_branch") or images.SCM_BRANCH),
        "inventory_name": images.INVENTORY,
        "credential_name": images.CREDENTIAL,
        "project_name": images.PROJECT,
        "job_template_name": images.JOB_TEMPLATE,
        "import_enabled": True,
    }


def provision(
    ctx: AppContext,
    nodes: List[Dict[str, str]],
    *,
    public_key: str,
    state: str = "present",
    scope: str = "all",
    replicas: int = 1,
) -> None:
    extra = base_vars(ctx, nodes, state=state, scope=scope, public_key=public_key)
    extra["replicas"] = replicas
    run_playbook(ctx, resources.playbook("provision.yml"), extra)


def import_nodes(
    ctx: AppContext,
    nodes: List[Dict[str, str]],
    *,
    private_key: str,
    state: str = "present",
    manage_inventory: bool = True,
) -> None:
    run_playbook(
        ctx,
        resources.playbook("import.yml"),
        import_vars(
            ctx,
            nodes,
            state=state,
            private_key=private_key,
            manage_inventory=manage_inventory,
        ),
    )
