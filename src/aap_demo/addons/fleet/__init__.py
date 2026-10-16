"""Fleet addon: mock Linux nodes as pods, registered in AAP."""

from __future__ import annotations

import json

from aap_demo.addons.fleet import images, runner, sshkey
from aap_demo.addons.fleet.ee import discover_image
from aap_demo.addons.fleet.state import (
    enabled_names,
    fleet_options,
    namespace_for,
    nodes_of,
    require_os,
    require_pull_secret,
    save_options,
    set_enabled,
)
from aap_demo.core.context import AppContext
from aap_demo.core.errors import UsageError


class FleetAddon:
    name = "fleet"

    def enable(self, ctx: AppContext, args) -> int:
        discover_image(ctx)
        no_import = bool(getattr(args, "no_import", False))
        private, public = sshkey.load_or_create(ctx)
        fleet = fleet_options(ctx)
        nodes = nodes_of(ctx) or [dict(node) for node in images.DEFAULT_NODES]
        fleet["namespace"] = namespace_for(ctx)
        fleet["nodes"] = nodes
        fleet["import"] = not no_import
        require_pull_secret(ctx, nodes)
        set_enabled(ctx, True)
        save_options(ctx, fleet)
        runner.provision(ctx, nodes, public_key=public, state="present", scope="all")
        if not no_import:
            runner.import_nodes(ctx, nodes, private_key=private, state="present")
        ctx.console.out(f"Fleet enabled in namespace {fleet['namespace']}")
        return 0

    def disable(self, ctx: AppContext, args) -> int:
        """Stop the pods. The namespace and the AAP inventory stay."""
        del args
        discover_image(ctx)
        _private, public = sshkey.load_or_create(ctx)
        nodes = nodes_of(ctx)
        if not nodes:
            ctx.console.out("Fleet has no nodes to stop")
            return 0
        runner.provision(ctx, nodes, public_key=public, state="present", scope="all", replicas=0)
        ctx.console.out("Fleet pods stopped")
        return 0

    def destroy(self, ctx: AppContext, args) -> int:
        """Delete Controller objects, then the fleet namespace."""
        del args
        discover_image(ctx)
        private, public = sshkey.load_or_create(ctx)
        nodes = nodes_of(ctx)
        if nodes:
            runner.import_nodes(
                ctx, nodes, private_key=private, state="absent", manage_inventory=True
            )
        runner.provision(ctx, nodes, public_key=public, state="absent", scope="all")
        fleet = fleet_options(ctx)
        fleet["nodes"] = []
        set_enabled(ctx, False)
        save_options(ctx, fleet)
        ctx.console.out("Fleet destroyed")
        return 0

    def list(self, ctx: AppContext, args) -> int:
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
        ctx.console.out(f"{'NAME':<16} {'OS':<8} READY")
        if not result.ok:
            ctx.console.err((result.stderr or "kubectl get pods failed").strip())
            return result.returncode or 1
        for name, os_id, ready in _pod_rows(result.stdout or ""):
            ctx.console.out(f"{name:<16} {os_id:<8} {ready}")
        return 0

    def add(self, ctx: AppContext, args) -> int:
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
        require_pull_secret(ctx, [nodes[-1]])
        private, public = sshkey.load_or_create(ctx)
        fleet = fleet_options(ctx)
        fleet["nodes"] = nodes
        save_options(ctx, fleet)
        runner.provision(ctx, nodes, public_key=public, state="present", scope="all")
        if fleet.get("import", True) is not False:
            runner.import_nodes(ctx, nodes, private_key=private, state="present")
        ctx.console.out(f"Added {name}")
        return 0

    def remove(self, ctx: AppContext, args) -> int:
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
        ctx.console.out(f"Removed {name}")
        return 0


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
