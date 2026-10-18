"""Live gateway URL. Not the hub route string from ``aap.route_host_for``."""

from __future__ import annotations

import json

from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError


def aap_namespace(ctx: AppContext) -> str:
    return str(ctx.config.get("core.namespace") or "aap-operator")


def gateway_url(ctx: AppContext) -> str:
    namespace = aap_namespace(ctx)
    host = _route_fronting_gateway(ctx, namespace)
    if not host:
        raise AddonError(
            "gateway route not found",
            hint=f"kubectl get route -n {namespace}",
        )
    return f"https://{host}"


def _route_fronting_gateway(ctx: AppContext, namespace: str) -> str:
    """Use a route that targets the operator-owned gateway service."""
    services = _items(ctx, "svc", namespace)
    owned: list[str] = []
    selected: list[str] = []
    for item in services:
        name = _gateway_service_name(item)
        if not name:
            continue
        if _owned_by_aap(item):
            owned.append(name)
        else:
            selected.append(name)
    names = set(owned or selected)
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


def _gateway_service_name(service: dict) -> str:
    spec = service.get("spec") if isinstance(service.get("spec"), dict) else {}
    selector = spec.get("selector") if isinstance(spec.get("selector"), dict) else {}
    if selector.get("app.kubernetes.io/component") != "aap-gateway":
        return ""
    meta = service.get("metadata") if isinstance(service.get("metadata"), dict) else {}
    return str(meta.get("name") or "")


def _owned_by_aap(service: dict) -> bool:
    meta = service.get("metadata") if isinstance(service.get("metadata"), dict) else {}
    refs = meta.get("ownerReferences")
    if not isinstance(refs, list):
        return False
    return any(
        isinstance(ref, dict) and ref.get("kind") == "AnsibleAutomationPlatform" for ref in refs
    )


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
