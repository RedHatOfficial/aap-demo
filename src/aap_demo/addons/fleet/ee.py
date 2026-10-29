"""The execution environment already running in the cluster.

Fleet playbooks run there, so the laptop does not need ansible-core
or the Galaxy collections.
"""

from __future__ import annotations

import json
from typing import Any, Dict, cast

from aap_demo.addons.fleet.gateway import aap_namespace
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError


def _as_dict(value: Any) -> Dict[str, Any]:
    if isinstance(value, dict):
        return cast(Dict[str, Any], value)
    return {}


def discover_image(ctx: AppContext) -> str:
    """Return the ee-supported image ref from the controller task pod."""
    namespace = aap_namespace(ctx)
    pods = ctx.runner.run(["kubectl", "get", "pods", "-n", namespace, "-o", "json"])
    if not pods.ok:
        raise AddonError(
            "could not list pods to find the execution environment",
            hint=f"kubectl get pods -n {namespace}",
        )
    if not _has_trusted_container(pods.stdout or ""):
        raise AddonError(
            "no ee-supported image is running in the cluster",
            hint="Deploy AAP, then run aap-demo enable fleet again.",
        )
    replica_sets = ctx.runner.run(["kubectl", "get", "rs", "-n", namespace, "-o", "json"])
    deployments = ctx.runner.run(["kubectl", "get", "deploy", "-n", namespace, "-o", "json"])
    controllers = ctx.runner.run(
        ["kubectl", "get", "automationcontroller", "-n", namespace, "-o", "json"]
    )
    platforms = ctx.runner.run(["kubectl", "get", "aap", "-n", namespace, "-o", "json"])
    image = _ee_image(
        pods.stdout or "",
        replica_sets.stdout if replica_sets.ok else "",
        deployments.stdout if deployments.ok else "",
        controllers.stdout if controllers.ok else "",
        platforms.stdout if platforms.ok else "",
    )
    if not image:
        raise AddonError(
            "no ee-supported image is running in the cluster",
            hint="Deploy AAP, then run aap-demo enable fleet again.",
        )
    return image


def _ee_image(
    pods_payload: str,
    replica_sets_payload: str = "",
    deployments_payload: str = "",
    controllers_payload: str = "",
    platforms_payload: str = "",
) -> str:
    """Image from the operator's ``{controller}-task`` deployment only.

    A second object that merely claims the controller's UID is ignored.
    Two trusted deployments with different images fail closed.
    """
    images = []
    platforms = {_name(item): item for item in _items(platforms_payload)}
    deployments = {_name(item): item for item in _items(deployments_payload)}
    replica_sets = {_name(item): item for item in _items(replica_sets_payload)}
    for controller in _items(controllers_payload):
        if not _linked(controller, platforms, "AnsibleAutomationPlatform"):
            continue
        controller_name = _name(controller)
        deploy_name = f"{controller_name}-task"
        deploy = deployments.get(deploy_name)
        if not isinstance(deploy, dict):
            continue
        if not _linked(deploy, {controller_name: controller}, "AutomationController"):
            continue
        template_image = _template_ee(deploy)
        if not template_image:
            continue
        trusted_sets = {
            name
            for name, item in replica_sets.items()
            if name.startswith(f"{deploy_name}-")
            and _linked(item, {deploy_name: deploy}, "Deployment")
        }
        for pod in _items(pods_payload):
            pod_name = _name(pod)
            replica_set = str(_owner_ref(pod, "ReplicaSet").get("name") or "")
            if not pod_name.startswith(f"{replica_set}-"):
                continue
            if replica_set not in trusted_sets or not _linked(pod, replica_sets, "ReplicaSet"):
                continue
            if not _running(pod) or _pod_ee(pod) != template_image:
                continue
            images.append(template_image)
    unique = list(dict.fromkeys(images))
    if len(unique) != 1:
        return ""
    return unique[0]


def _has_trusted_container(payload: str) -> bool:
    for item in _items(payload):
        if not _running(item):
            continue
        spec = _as_dict(item.get("spec"))
        containers = spec.get("containers")
        if not isinstance(containers, list):
            continue
        if any(isinstance(container, dict) and _trusted_ee(container) for container in containers):
            return True
    return False


def _template_ee(deploy: dict) -> str:
    spec = _as_dict(deploy.get("spec"))
    template = _as_dict(spec.get("template"))
    pod_spec = _as_dict(template.get("spec"))
    return _container_ee(pod_spec.get("containers"))


def _pod_ee(pod: dict) -> str:
    spec = _as_dict(pod.get("spec"))
    return _container_ee(spec.get("containers"))


def _container_ee(containers: object) -> str:
    if not isinstance(containers, list):
        return ""
    for container in containers:
        if isinstance(container, dict) and _trusted_ee(container):
            return str(container.get("image") or "")
    return ""


def _items(payload: str) -> list:
    try:
        document = json.loads(payload or "{}")
    except json.JSONDecodeError:
        return []
    items = document.get("items") if isinstance(document, dict) else None
    if not isinstance(items, list):
        return []
    return [item for item in items if isinstance(item, dict)]


def _name(item: dict) -> str:
    meta = _as_dict(item.get("metadata"))
    return str((meta or {}).get("name") or "")


def _owner_ref(item: dict, kind: str) -> dict:
    meta = _as_dict(item.get("metadata"))
    refs = meta.get("ownerReferences")
    if not isinstance(refs, list):
        return {}
    for ref in refs:
        if not isinstance(ref, dict) or ref.get("kind") != kind or not ref.get("name"):
            continue
        optional = kind in {"AutomationController", "AnsibleAutomationPlatform"}
        if ref.get("controller") is True or (optional and "controller" not in ref):
            return ref
    return {}


def _linked(child: dict, parents: dict, kind: str) -> bool:
    ref = _owner_ref(child, kind)
    parent = parents.get(str(ref.get("name") or ""))
    ref_uid = str(ref.get("uid") or "")
    if not isinstance(parent, dict) or not ref_uid:
        return False
    meta = _as_dict(parent.get("metadata"))
    return ref_uid == str((meta or {}).get("uid") or "")


def _running(pod: dict) -> bool:
    meta = _as_dict(pod.get("metadata"))
    if meta.get("deletionTimestamp"):
        return False
    status = _as_dict(pod.get("status"))
    if status.get("phase") != "Running":
        return False
    conditions = status.get("conditions")
    if not isinstance(conditions, list):
        return False
    return any(
        isinstance(item, dict) and item.get("type") == "Ready" and item.get("status") == "True"
        for item in conditions
    )


def _trusted_ee(container: dict) -> bool:
    """The controller EE, from Red Hat's registry, and no other image."""
    name = str(container.get("name") or "")
    image = str(container.get("image") or "")
    return (
        name == "aap-controller-ee"
        and image.startswith("registry.redhat.io/")
        and "/ee-supported-rhel" in image
    )
