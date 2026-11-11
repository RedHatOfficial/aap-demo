"""Identify healthy Kubernetes-native Fleet targets for product demos."""

from __future__ import annotations

import json
from typing import Any, Dict, List

from aap_demo.addons.fleet.state import namespace_for
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError


def select_fleet_host(pods: List[Dict[str, Any]]) -> str:
    """Choose a ready RHEL-compatible Fleet host in stable name order."""
    eligible = []
    for pod in pods:
        metadata = pod.get("metadata") or {}
        labels = metadata.get("labels") or {}
        status = pod.get("status") or {}
        os_id = str(labels.get("aap-demo/os") or "").lower()
        name = labels.get("app.kubernetes.io/instance")
        if (
            labels.get("app.kubernetes.io/name") != "fleet-node"
            or not name
            or not (os_id.startswith("rhel") or os_id.startswith("ubi"))
            or metadata.get("deletionTimestamp")
            or status.get("phase") != "Running"
            or not any(
                condition.get("type") == "Ready" and condition.get("status") == "True"
                for condition in status.get("conditions") or []
            )
        ):
            continue
        eligible.append((0 if os_id.startswith("rhel") else 1, str(name)))
    if not eligible:
        raise AddonError(
            "no suitable ready Fleet pod found",
            hint="Enable Fleet and ensure a RHEL or UBI Fleet pod is ready, then retry.",
        )
    return min(eligible)[1]


def discover_fleet_host(ctx: AppContext) -> str:
    """Read Fleet pods in the configured namespace and select a target."""
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
        raise AddonError("could not inspect Fleet pods", hint=(result.stderr or "").strip() or None)
    try:
        document = json.loads(result.stdout or "{}")
        items = document.get("items", [])
        if not isinstance(items, list):
            raise ValueError("pod list has no items array")
    except (ValueError, AttributeError) as exc:
        raise AddonError("could not inspect Fleet pods", hint=str(exc)) from exc
    services_result = ctx.runner.run(["kubectl", "get", "services", "-n", namespace, "-o", "json"])
    if not services_result.ok:
        raise AddonError(
            "could not inspect Fleet services", hint=(services_result.stderr or "").strip() or None
        )
    try:
        services = json.loads(services_result.stdout or "{}").get("items", [])
        if not isinstance(services, list):
            raise ValueError("service list has no items array")
    except (ValueError, AttributeError) as exc:
        raise AddonError("could not inspect Fleet services", hint=str(exc)) from exc

    def has_ssh_service(pod: Dict[str, Any]) -> bool:
        labels = (pod.get("metadata") or {}).get("labels") or {}
        name = labels.get("app.kubernetes.io/instance")
        for service in services:
            spec = service.get("spec") or {}
            selector = spec.get("selector") or {}
            ports = spec.get("ports") or []
            if (
                name
                and (service.get("metadata") or {}).get("name") == name
                and selector
                and all(labels.get(key) == value for key, value in selector.items())
                and any(
                    port.get("port") == 22 and port.get("protocol", "TCP") == "TCP"
                    for port in ports
                )
            ):
                return True
        return False

    return select_fleet_host([pod for pod in items if has_ssh_service(pod)])
