"""Live gateway URL. Not the hub route string from ``aap.route_host_for``."""

from __future__ import annotations

import json

from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError


def aap_namespace(ctx: AppContext) -> str:
    return str(ctx.config.get("core.namespace") or "aap-operator")


def gateway_url(ctx: AppContext) -> str:
    namespace = aap_namespace(ctx)
    listed = ctx.runner.run(
        [
            "kubectl",
            "get",
            "route",
            "-n",
            namespace,
            "-l",
            "app.kubernetes.io/name=gateway",
            "-o",
            "jsonpath={.items[0].spec.host}",
        ]
    )
    host = listed.stdout.strip() if listed.ok else ""
    if not host:
        host = _route_named_gateway(ctx, namespace)
    if not host:
        raise AddonError(
            "gateway route not found",
            hint=f"kubectl get route -n {namespace}",
        )
    return f"https://{host}"


def _route_named_gateway(ctx: AppContext, namespace: str) -> str:
    result = ctx.runner.run(["kubectl", "get", "route", "-n", namespace, "-o", "json"])
    if not result.ok or not (result.stdout or "").strip():
        return ""
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return ""
    items = payload.get("items") if isinstance(payload, dict) else None
    if not isinstance(items, list):
        return ""
    for item in items:
        if not isinstance(item, dict):
            continue
        meta = item.get("metadata") if isinstance(item.get("metadata"), dict) else {}
        name = str(meta.get("name") or "")
        if not name.endswith("-gateway"):
            continue
        spec = item.get("spec") if isinstance(item.get("spec"), dict) else {}
        host = str(spec.get("host") or "").strip()
        if host:
            return host
    return ""
