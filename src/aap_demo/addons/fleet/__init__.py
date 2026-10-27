"""Fleet addon: mock Linux nodes as pods, registered in AAP."""

from __future__ import annotations

import argparse
import json

from aap_demo.addons.fleet import images, runner, sshkey
from aap_demo.addons.fleet.ee import discover_image
from aap_demo.addons.fleet.job import delete_fleet_scc, delete_owned_namespace, runner_namespace
from aap_demo.addons.fleet.state import (
    enabled_names,
    fleet_options,
    namespace_for,
    nodes_of,
    require_os,
    save_options,
    set_enabled,
)
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError, AddonError, UsageError
from aap_demo.core.output import is_structured, render


class FleetAddon:
    name = "fleet"

    def enable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        discover_image(ctx)
        no_import = bool(getattr(args, "no_import", False))
        private, public = sshkey.load_or_create(ctx)
        fleet = fleet_options(ctx)
        nodes = nodes_of(ctx) or [dict(node) for node in images.DEFAULT_NODES]
        fleet["namespace"] = namespace_for(ctx)
        fleet["nodes"] = nodes
        # A later --no-import must not forget that Controller objects exist.
        if not (no_import and fleet.get("import") is True):
            fleet["import"] = not no_import
        runner.provision(ctx, nodes, public_key=public, state="present", scope="all")
        _commit_fleet(ctx, fleet)
        if not no_import:
            runner.import_nodes(ctx, nodes, private_key=private, state="present")
        set_enabled(ctx, True)
        _commit_fleet(ctx, fleet)
        _say(
            ctx,
            f"Fleet enabled in namespace {fleet['namespace']}",
            namespace=fleet["namespace"],
        )
        return 0

    def disable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        """Stop the pods. The namespace and the AAP inventory stay."""
        del args
        discover_image(ctx)
        _private, public = sshkey.load_or_create(ctx)
        nodes = nodes_of(ctx)
        if not nodes:
            _say(ctx, "Fleet has no nodes to stop")
            return 0
        runner.provision(ctx, nodes, public_key=public, state="present", scope="all", replicas=0)
        _say(ctx, "Fleet pods stopped", namespace=namespace_for(ctx))
        return 0

    def destroy(self, ctx: AppContext, args: argparse.Namespace) -> int:
        """Delete Controller objects, then the local Fleet resources."""
        del args
        cleanup_error: AapDemoError | None = None
        skipped = False
        try:
            private, public, skipped = _controller_cleanup_keys(ctx)
            nodes = nodes_of(ctx)
            imported = (
                "import" in fleet_options(ctx) and fleet_options(ctx).get("import") is not False
            )
            if private and public and imported:
                runner.import_nodes(
                    ctx, nodes, private_key=private, state="absent", manage_inventory=True
                )
            if public:
                runner.provision(ctx, nodes, public_key=public, state="absent", scope="all")
        except AapDemoError as exc:
            cleanup_error = exc
        _delete_local_fleet(ctx)
        if cleanup_error is not None:
            raise cleanup_error
        if skipped and not is_structured(ctx.output):
            ctx.console.out("Skipping Controller cleanup because AAP is not available")
        _say(
            ctx,
            "Fleet destroyed",
            controller_cleanup="skipped" if skipped else "removed",
        )
        return 0

    def list(self, ctx: AppContext, args: argparse.Namespace) -> int:
        del args
        namespace = namespace_for(ctx)
        result = ctx.runner.run(
            [
                "kubectl",
                "get",
                "pods",
                "-n",
                namespace,
                "-l",
                "app.kubernetes.io/name=fleet-node",
                "-o",
                "json",
            ]
        )
        if not result.ok:
            ctx.console.err((result.stderr or "kubectl get pods failed").strip())
            return result.returncode or 1
        rows = [
            {"name": name, "os": os_id, "ready": ready == "yes"}
            for name, os_id, ready in _pod_rows(result.stdout or "")
        ]
        if is_structured(ctx.output):
            render(ctx.console, rows, output=ctx.output)
            return 0
        ctx.console.out(f"{'NAME':<16} {'OS':<8} READY")
        for row in rows:
            mark = "yes" if row["ready"] else "no"
            ctx.console.out(f"{row['name']:<16} {row['os']:<8} {mark}")
        return 0

    def add(self, ctx: AppContext, args: argparse.Namespace) -> int:
        os_id = str(getattr(args, "os", "") or "")
        require_os(os_id)
        if "fleet" not in enabled_names(ctx):
            raise UsageError(
                "fleet is not enabled",
                hint="Run: aap-demo enable fleet",
            )
        name = str(getattr(args, "name", "") or f"fleet-{os_id}")
        nodes = nodes_of(ctx)
        if any(node["name"] == name for node in nodes):
            raise UsageError(
                f"node {name} already exists",
                hint="Pass --name to add another node with that OS.",
            )
        discover_image(ctx)
        nodes.append({"name": name, "os": os_id})
        private, public = sshkey.load_or_create(ctx)
        fleet = fleet_options(ctx)
        fleet["nodes"] = nodes
        runner.provision(ctx, nodes, public_key=public, state="present", scope="all")
        _commit_fleet(ctx, fleet)
        if fleet.get("import", True) is not False:
            runner.import_nodes(ctx, nodes, private_key=private, state="present")
        _commit_fleet(ctx, fleet)
        _say(ctx, f"Added {name}", name=name)
        return 0

    def remove(self, ctx: AppContext, args: argparse.Namespace) -> int:
        name = str(getattr(args, "name", "") or "")
        nodes = nodes_of(ctx)
        match = [node for node in nodes if node["name"] == name]
        if not match:
            raise UsageError(f"no fleet node named {name}")
        discover_image(ctx)
        private, public = sshkey.load_or_create(ctx)
        if fleet_options(ctx).get("import", True) is not False:
            runner.import_nodes(
                ctx,
                match,
                private_key=private,
                state="absent",
                manage_inventory=False,
            )
        runner.provision(ctx, match, public_key=public, state="absent", scope="node")
        fleet = fleet_options(ctx)
        fleet["nodes"] = [node for node in nodes if node["name"] != name]
        save_options(ctx, fleet)
        _say(ctx, f"Removed {name}", name=name)
        return 0


def _delete_local_fleet(ctx: AppContext) -> None:
    """Namespaces and the SCC, whether or not Controller cleanup ran."""
    namespace = namespace_for(ctx)
    delete_owned_namespace(ctx, namespace, uid_key="namespace_uid")
    delete_owned_namespace(ctx, runner_namespace(namespace), uid_key="runner_namespace_uid")
    delete_fleet_scc(ctx)
    fleet = fleet_options(ctx)
    fleet["nodes"] = []
    fleet.pop("namespace_token", None)
    fleet.pop("namespace_uid", None)
    fleet.pop("runner_namespace_uid", None)
    set_enabled(ctx, False)
    save_options(ctx, fleet)


def _say(ctx: AppContext, message: str, **fields: object) -> None:
    """Human text, or one JSON/YAML document when structured output is on."""
    if is_structured(ctx.output):
        render(ctx.console, {"message": message, **fields}, output=ctx.output)
        return
    ctx.console.out(message)


def _controller_cleanup_keys(ctx: AppContext) -> tuple:
    """Return the SSH key when AAP can run the cleanup playbooks."""
    try:
        discover_image(ctx)
    except AddonError as exc:
        ctx.console.err(exc.message)
        return "", "", True
    private, public = sshkey.load_or_create(ctx)
    return private, public, False


def _commit_fleet(ctx: AppContext, fleet: dict) -> None:
    """Persist options after the playbooks succeed, without dropping ownership."""
    current = fleet_options(ctx)
    for key in ("namespace_token", "namespace_uid", "runner_namespace_uid"):
        if current.get(key):
            fleet[key] = current[key]
    save_options(ctx, fleet)


def _pod_rows(payload: str) -> list:
    try:
        document = json.loads(payload or "{}")
    except json.JSONDecodeError:
        return []
    items = document.get("items") if isinstance(document, dict) else None
    if not isinstance(items, list):
        return []
    rows = []
    for item in items:
        if not isinstance(item, dict):
            continue
        meta = item.get("metadata") if isinstance(item.get("metadata"), dict) else {}
        labels = meta.get("labels") if isinstance(meta.get("labels"), dict) else {}
        name = str(labels.get("app.kubernetes.io/instance") or meta.get("name") or "")
        os_id = str(labels.get("aap-demo/os") or "")
        ready = "no"
        status = item.get("status") if isinstance(item.get("status"), dict) else {}
        for condition in status.get("conditions") or []:
            if (
                isinstance(condition, dict)
                and condition.get("type") == "Ready"
                and condition.get("status") == "True"
            ):
                ready = "yes"
        if name:
            rows.append((name, os_id, ready))
    return rows
