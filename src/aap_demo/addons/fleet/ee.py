"""The execution environment already running in the cluster.

Fleet playbooks run there, so the laptop does not need ansible-core
or the Galaxy collections.
"""

from __future__ import annotations

import json

from aap_demo.addons.fleet.gateway import aap_namespace
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError


def discover_image(ctx: AppContext) -> str:
    """Return the ee-supported image ref from a running pod."""
    namespace = aap_namespace(ctx)
    result = ctx.runner.run(["kubectl", "get", "pods", "-n", namespace, "-o", "json"])
    if not result.ok:
        raise AddonError(
            "could not list pods to find the execution environment",
            hint=f"kubectl get pods -n {namespace}",
        )
    image = _ee_image(result.stdout or "")
    if not image:
        raise AddonError(
            "no ee-supported image is running in the cluster",
            hint="Deploy AAP, then run aap-demo enable fleet again.",
        )
    return image


def _ee_image(payload: str) -> str:
    try:
        document = json.loads(payload or "{}")
    except json.JSONDecodeError:
        return ""
    items = document.get("items") if isinstance(document, dict) else None
    if not isinstance(items, list):
        return ""
    for item in items:
        if not isinstance(item, dict):
            continue
        spec = item.get("spec") if isinstance(item.get("spec"), dict) else {}
        containers = spec.get("containers")
        if not isinstance(containers, list):
            continue
        for container in containers:
            if not isinstance(container, dict):
                continue
            if _trusted_ee(container):
                return str(container.get("image") or "")
    return ""


def _trusted_ee(container: dict) -> bool:
    """The controller EE, from Red Hat's registry, and no other image."""
    name = str(container.get("name") or "")
    image = str(container.get("image") or "")
    return (
        name == "aap-controller-ee"
        and image.startswith("registry.redhat.io/")
        and "/ee-supported-rhel" in image
    )
