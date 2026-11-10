"""Live gateway URL. Not the hub route string from ``aap.route_host_for``."""

from __future__ import annotations

import json
from typing import Any, Dict, cast

from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError


def _as_dict(value: Any) -> Dict[str, Any]:
    if isinstance(value, dict):
        return cast(Dict[str, Any], value)
    return {}


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


def _operator_gateway_pods(ctx: AppContext, namespace: str) -> dict:
    """Ready gateway pods, keyed by name to their API UID.

    More than one matching deployment fails closed. A second object that
    only claims the platform UID must not become an alternate gateway.
    """
    platforms = dict(_named(ctx, "aap", namespace))
    deploy_items = dict(_named(ctx, "deploy", namespace))
    deployments = {
        name: item
        for name, item in deploy_items.items()
        if _linked(item, platforms, "AnsibleAutomationPlatform")
        and _match_labels(item).get("app.kubernetes.io/component") == "aap-gateway"
        and _match_labels(item).get("app.kubernetes.io/managed-by") == "aap-operator"
    }
    if len(deployments) != 1:
        return {}
    deploy_name, deploy = next(iter(deployments.items()))
    expected = _match_labels(deploy)
    replica_sets = dict(_named(ctx, "rs", namespace))
    owned_sets = {
        name
        for name, item in replica_sets.items()
        if name.startswith(f"{deploy_name}-")
        and _linked(item, deploy_items, "Deployment")
        and str(_owner_ref(item, "Deployment").get("name") or "") == deploy_name
    }
    pods = {}
    for name, item in _named(ctx, "pods", namespace):
        meta = _as_dict(item.get("metadata"))
        uid = str(meta.get("uid") or "")
        replica_set = str(_owner_ref(item, "ReplicaSet").get("name") or "")
        labels = _as_dict(meta.get("labels"))
        if not uid or not name.startswith(f"{replica_set}-"):
            continue
        if replica_set not in owned_sets or not _linked(item, replica_sets, "ReplicaSet"):
            continue
        if any(labels.get(key) != value for key, value in expected.items()):
            continue
        if _ready(item):
            pods[name] = uid
    return pods


def _route_for_pods(ctx: AppContext, namespace: str, pods: dict) -> str:
    services = set()
    for name, item in _named(ctx, "svc", namespace):
        selector = _service_selector(item)
        if selector.get("app.kubernetes.io/component") != "aap-gateway":
            continue
        if selector.get("app.kubernetes.io/managed-by") != "aap-operator":
            continue
        endpoints = _endpoint_pods(ctx, namespace, name)
        if not endpoints or not set(endpoints) <= set(pods):
            continue
        if any(endpoints[pod] != pods[pod] for pod in endpoints):
            continue
        services.add(name)
    # The operator creates more than one service for the gateway (aap and aap-api).
    # All of them reach only the ready gateway pods, so the single route decides.
    if not services:
        return ""
    hosts = []
    for item in _items(ctx, "route", namespace):
        spec = _as_dict(item.get("spec"))
        target = _as_dict(spec.get("to"))
        if str(target.get("name") or "") not in services:
            continue
        host = str(spec.get("host") or "").strip()
        if host:
            hosts.append(host)
    if len(hosts) != 1:
        return ""
    return hosts[0]


def _endpoint_pods(ctx: AppContext, namespace: str, service: str) -> dict:
    """Pod name to UID. An address without a Pod UID rejects the whole set."""
    result = ctx.runner.run(["kubectl", "get", "endpoints", service, "-n", namespace, "-o", "json"])
    if not result.ok:
        raise AddonError(
            "could not read gateway endpoints",
            hint=(result.stderr or result.stdout or "").strip() or None,
        )
    if not (result.stdout or "").strip():
        return {}
    try:
        document = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {}
    names: dict = {}
    for subset in document.get("subsets") or []:
        if not isinstance(subset, dict):
            continue
        for address in subset.get("addresses") or []:
            if not isinstance(address, dict):
                continue
            target = _as_dict(address.get("targetRef"))
            name = str(target.get("name") or "")
            uid = str(target.get("uid") or "")
            if target.get("kind") != "Pod" or not name or not uid:
                return {}
            names[name] = uid
    return names


def _named(ctx: AppContext, kind: str, namespace: str):
    for item in _items(ctx, kind, namespace):
        meta = _as_dict(item.get("metadata"))
        name = str(meta.get("name") or "")
        if name:
            yield name, item


def _owner_ref(item: dict, kind: str) -> dict:
    meta = _as_dict(item.get("metadata"))
    refs = meta.get("ownerReferences")
    if not isinstance(refs, list):
        return {}
    for ref in refs:
        if not isinstance(ref, dict) or ref.get("kind") != kind or not ref.get("name"):
            continue
        if ref.get("controller") is True or (
            kind == "AnsibleAutomationPlatform" and "controller" not in ref
        ):
            return ref
    return {}


def _linked(child: dict, parents: dict, kind: str) -> bool:
    """True when the owner reference names that object and carries its UID."""
    ref = _owner_ref(child, kind)
    parent = parents.get(str(ref.get("name") or ""))
    ref_uid = str(ref.get("uid") or "")
    if not isinstance(parent, dict) or not ref_uid:
        return False
    meta = _as_dict(parent.get("metadata"))
    return ref_uid == str((meta or {}).get("uid") or "")


def _match_labels(item: dict) -> dict:
    spec = _as_dict(item.get("spec"))
    selector = _as_dict(spec.get("selector"))
    labels = _as_dict(selector.get("matchLabels"))
    return labels


def _service_selector(item: dict) -> dict:
    spec = _as_dict(item.get("spec"))
    selector = _as_dict(spec.get("selector"))
    return selector


def _ready(item: dict) -> bool:
    meta = _as_dict(item.get("metadata"))
    if meta.get("deletionTimestamp"):
        return False
    status = _as_dict(item.get("status"))
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
