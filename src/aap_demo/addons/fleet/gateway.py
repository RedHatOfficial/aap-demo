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
        host = _route_fronting_gateway(ctx, namespace)
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


def _route_fronting_gateway(ctx: AppContext, namespace: str) -> str:
    """AAP 2.6 publishes the gateway on the platform route, not ``*-gateway``."""
    services = _items(ctx, "svc", namespace)
    names = set()
    for item in services:
        spec = item.get("spec") if isinstance(item.get("spec"), dict) else {}
        selector = spec.get("selector") if isinstance(spec.get("selector"), dict) else {}
        if selector.get("app.kubernetes.io/component") == "aap-gateway":
            meta = item.get("metadata") if isinstance(item.get("metadata"), dict) else {}
            if meta.get("name"):
                names.add(str(meta["name"]))
    if not names:
        return ""
    for item in _items(ctx, "route", namespace):
        spec = item.get("spec") if isinstance(item.get("spec"), dict) else {}
        target = spec.get("to") if isinstance(spec.get("to"), dict) else {}
        if str(target.get("name") or "") not in names:
            continue
        host = str(spec.get("host") or "").strip()
        if host:
            return host
    return ""


def _items(ctx: AppContext, kind: str, namespace: str) -> list:
    result = ctx.runner.run(["kubectl", "get", kind, "-n", namespace, "-o", "json"])
    if not result.ok or not (result.stdout or "").strip():
        return []
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return []
    items = payload.get("items") if isinstance(payload, dict) else None
    if not isinstance(items, list):
        return []
    return [item for item in items if isinstance(item, dict)]
