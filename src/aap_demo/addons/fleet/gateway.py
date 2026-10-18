"""Live gateway URL. Not the hub route string from ``aap.route_host_for``."""

from __future__ import annotations

import json

from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError


def aap_namespace(ctx: AppContext) -> str:
    return str(ctx.config.get("core.namespace") or "aap-operator")


def gateway_url(ctx: AppContext) -> str:
    namespace = aap_namespace(ctx)
    service, host = _route_fronting_gateway(ctx, namespace)
    if not host or not service:
        raise AddonError(
            "gateway route not found",
            hint=f"kubectl get route -n {namespace}",
        )
    _require_operator_endpoints(ctx, namespace, service)
    return f"https://{host}"


def _route_fronting_gateway(ctx: AppContext, namespace: str) -> tuple:
    """Return the service and host for a route that selects only gateway pods."""
    names = set()
    for item in _items(ctx, "svc", namespace):
        name = _gateway_service_name(item)
        if name:
            names.add(name)
    if not names:
        return "", ""
    for item in _items(ctx, "route", namespace):
        spec = item.get("spec") if isinstance(item.get("spec"), dict) else {}
        target = spec.get("to") if isinstance(spec.get("to"), dict) else {}
        service = str(target.get("name") or "")
        if service not in names:
            continue
        host = str(spec.get("host") or "").strip()
        if host:
            return service, host
    return "", ""


def _require_operator_endpoints(ctx: AppContext, namespace: str, service: str) -> None:
    """Refuse the route when a gateway endpoint is not an operator ReplicaSet pod."""
    result = ctx.runner.run(["kubectl", "get", "endpoints", service, "-n", namespace, "-o", "json"])
    if not result.ok or not (result.stdout or "").strip():
        raise AddonError(
            "could not read gateway endpoints",
            hint=f"kubectl get endpoints {service} -n {namespace}",
        )
    try:
        document = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise AddonError("could not read gateway endpoints", hint=str(exc)) from exc
    pods = []
    for subset in document.get("subsets") or []:
        if not isinstance(subset, dict):
            continue
        for address in subset.get("addresses") or []:
            if not isinstance(address, dict):
                continue
            target = address.get("targetRef") if isinstance(address.get("targetRef"), dict) else {}
            name = str(target.get("name") or "")
            if target.get("kind") != "Pod" or not name:
                raise AddonError(
                    "refusing to use the gateway route",
                    hint="A gateway endpoint is not a pod.",
                )
            pods.append(name)
    if not pods:
        raise AddonError(
            "refusing to use the gateway route",
            hint="The gateway service has no ready pods.",
        )
    for name in pods:
        pod = ctx.runner.run(["kubectl", "get", "pod", name, "-n", namespace, "-o", "json"])
        if not pod.ok or not _replicaset_owned(pod.stdout or ""):
            raise AddonError(
                "refusing to use the gateway route",
                hint="A gateway endpoint is not owned by the operator.",
            )


def _replicaset_owned(payload: str) -> bool:
    try:
        document = json.loads(payload or "{}")
    except json.JSONDecodeError:
        return False
    meta = document.get("metadata") if isinstance(document, dict) else {}
    refs = (meta or {}).get("ownerReferences")
    if not isinstance(refs, list):
        return False
    return any(
        isinstance(ref, dict) and ref.get("kind") == "ReplicaSet" and ref.get("controller") is True
        for ref in refs
    )


def _gateway_service_name(service: dict) -> str:
    spec = service.get("spec") if isinstance(service.get("spec"), dict) else {}
    selector = spec.get("selector") if isinstance(spec.get("selector"), dict) else {}
    if selector != {"app.kubernetes.io/component": "aap-gateway"}:
        return ""
    meta = service.get("metadata") if isinstance(service.get("metadata"), dict) else {}
    return str(meta.get("name") or "")


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
