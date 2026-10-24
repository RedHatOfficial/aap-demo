"""Live gateway URL. Not the hub route string from ``aap.route_host_for``."""

from __future__ import annotations

import json

from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError


def aap_namespace(ctx: AppContext) -> str:
    return str(ctx.config.get("core.namespace") or "aap-operator")


def gateway_url(ctx: AppContext) -> str:
    namespace = aap_namespace(ctx)
    pods = _operator_gateway_pods(ctx, namespace)
    if not pods:
        raise AddonError(
            "gateway deployment not found",
            hint=f"kubectl get deploy -n {namespace}",
        )
    host = _route_for_pods(ctx, namespace, pods)
    if not host:
        raise AddonError(
            "gateway route not found",
            hint=f"kubectl get route -n {namespace}",
        )
    return f"https://{host}"


def _operator_gateway_pods(ctx: AppContext, namespace: str) -> set:
    """Pods in the ReplicaSet chain owned by the AAP gateway deployment."""
    deployments = {
        name
        for name, item in _named(ctx, "deploy", namespace)
        if _controller_owner(item, "AnsibleAutomationPlatform")
        and _match_labels(item).get("app.kubernetes.io/component") == "aap-gateway"
        and _match_labels(item).get("app.kubernetes.io/managed-by") == "aap-operator"
    }
    if not deployments:
        return set()
    replica_sets = {
        name
        for name, item in _named(ctx, "rs", namespace)
        if _controller_owner(item, "Deployment") in deployments
    }
    return {
        name
        for name, item in _named(ctx, "pods", namespace)
        if _controller_owner(item, "ReplicaSet") in replica_sets and _ready(item)
    }


def _route_for_pods(ctx: AppContext, namespace: str, pods: set) -> str:
    services = set()
    for name, item in _named(ctx, "svc", namespace):
        selector = _service_selector(item)
        if selector.get("app.kubernetes.io/component") != "aap-gateway":
            continue
        if selector.get("app.kubernetes.io/managed-by") != "aap-operator":
            continue
        endpoints = _endpoint_pods(ctx, namespace, name)
        if endpoints and endpoints <= pods:
            services.add(name)
    if not services:
        return ""
    for item in _items(ctx, "route", namespace):
        spec = item.get("spec") if isinstance(item.get("spec"), dict) else {}
        target = spec.get("to") if isinstance(spec.get("to"), dict) else {}
        if str(target.get("name") or "") not in services:
            continue
        host = str(spec.get("host") or "").strip()
        if host:
            return host
    return ""


def _endpoint_pods(ctx: AppContext, namespace: str, service: str) -> set:
    result = ctx.runner.run(["kubectl", "get", "endpoints", service, "-n", namespace, "-o", "json"])
    if not result.ok:
        raise AddonError(
            "could not read gateway endpoints",
            hint=(result.stderr or result.stdout or "").strip() or None,
        )
    if not (result.stdout or "").strip():
        return set()
    try:
        document = json.loads(result.stdout)
    except json.JSONDecodeError:
        return set()
    names = set()
    for subset in document.get("subsets") or []:
        if not isinstance(subset, dict):
            continue
        for address in subset.get("addresses") or []:
            if not isinstance(address, dict):
                continue
            target = address.get("targetRef") if isinstance(address.get("targetRef"), dict) else {}
            name = str(target.get("name") or "")
            if target.get("kind") != "Pod" or not name:
                return set()
            names.add(name)
    return names


def _named(ctx: AppContext, kind: str, namespace: str):
    for item in _items(ctx, kind, namespace):
        meta = item.get("metadata") if isinstance(item.get("metadata"), dict) else {}
        name = str(meta.get("name") or "")
        if name:
            yield name, item


def _controller_owner(item: dict, kind: str) -> str:
    meta = item.get("metadata") if isinstance(item.get("metadata"), dict) else {}
    refs = meta.get("ownerReferences")
    if not isinstance(refs, list):
        return ""
    for ref in refs:
        if (
            isinstance(ref, dict)
            and ref.get("kind") == kind
            and ref.get("name")
            and (
                ref.get("controller") is True
                # AAP 2.7 gateway Deployments may omit this optional field
                # while still being owned by the AnsibleAutomationPlatform CR.
                or (kind == "AnsibleAutomationPlatform" and "controller" not in ref)
            )
        ):
            return str(ref["name"])
    return ""


def _match_labels(item: dict) -> dict:
    spec = item.get("spec") if isinstance(item.get("spec"), dict) else {}
    selector = spec.get("selector") if isinstance(spec.get("selector"), dict) else {}
    labels = selector.get("matchLabels") if isinstance(selector.get("matchLabels"), dict) else {}
    return labels


def _service_selector(item: dict) -> dict:
    spec = item.get("spec") if isinstance(item.get("spec"), dict) else {}
    selector = spec.get("selector") if isinstance(spec.get("selector"), dict) else {}
    return selector


def _ready(item: dict) -> bool:
    meta = item.get("metadata") if isinstance(item.get("metadata"), dict) else {}
    if meta.get("deletionTimestamp"):
        return False
    status = item.get("status") if isinstance(item.get("status"), dict) else {}
    if status.get("phase") != "Running":
        return False
    conditions = status.get("conditions")
    if not isinstance(conditions, list):
        return False
    return any(
        isinstance(condition, dict)
        and condition.get("type") == "Ready"
        and condition.get("status") == "True"
        for condition in conditions
    )


def _items(ctx: AppContext, kind: str, namespace: str) -> list:
    result = ctx.runner.run(["kubectl", "get", kind, "-n", namespace, "-o", "json"])
    if not result.ok:
        raise AddonError(
            f"could not list {kind} in {namespace}",
            hint=(result.stderr or result.stdout or "").strip() or None,
        )
    if not (result.stdout or "").strip():
        return []
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return []
    items = payload.get("items") if isinstance(payload, dict) else None
    if not isinstance(items, list):
        return []
    return [item for item in items if isinstance(item, dict)]
