"""Fleet's side of running a playbook: the namespaces it owns, node RBAC, and its SCC.

The Job itself runs through :mod:`aap_demo.addons.common.playbook_job`.
"""

from __future__ import annotations

import hashlib
import json
import secrets
import uuid
from pathlib import Path
from typing import Any, Dict, List

import yaml

from aap_demo.addons.common import playbook_job
from aap_demo.addons.common.ee import discover_image
from aap_demo.addons.common.gateway import aap_namespace
from aap_demo.addons.common.kube import (
    apply_or_raise,
    as_dict,
    is_missing,
    read_object,
    run_or_raise,
)
from aap_demo.addons.fleet.resources import read_text
from aap_demo.addons.fleet.state import (
    forget_namespace_uid,
    namespace_token_for,
    namespace_uid_for,
    remember_namespace_token,
    remember_namespace_uid,
)
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError

RUNNER_ACCOUNT = "aap-demo-fleet-runner"
FLEET_LABEL = "aap-demo/fleet"
TOKEN_ANNOTATION = "aap-demo/fleet-token"
FLEET_SCC = "aap-demo-fleet"
FLEET_SCC_ROLE = "system:openshift:scc:aap-demo-fleet"
FLEET_SCC_BINDING = "fleet-ssh-scc"
_MOUNT_ROOT = "/opt/fleet"
_PLAYBOOK_ROOT = f"{_MOUNT_ROOT}/playbooks"
_EXTRA_ROOT = f"{_MOUNT_ROOT}/extra"
_APPLY_ERROR = "could not apply the fleet playbook job"
_PLAYBOOK_PURPOSES = {
    "provision.yml": "creating/updating Fleet node pods and persistent storage",
    "import.yml": "registering Fleet nodes in AAP inventory and creating the ping job template",
}


def runner_namespace(fleet_ns: str) -> str:
    """Jobs and credentials stay out of the namespace that runs the nodes."""
    candidate = f"{fleet_ns}-runner"
    if len(candidate) <= 63:
        return candidate
    digest = hashlib.sha256(fleet_ns.encode()).hexdigest()[:8]
    return f"fleet-runner-{digest}"


def run_playbook(ctx: AppContext, playbook: Path, extra: Dict[str, Any]) -> None:
    """Apply the playbook with the cluster's ee-supported image, then delete the Job."""
    image = discover_image(ctx, addon="fleet")
    fleet_ns = str(extra.get("namespace") or "fleet")
    job_ns = runner_namespace(fleet_ns)
    present = str(extra.get("state") or "present") != "absent"
    scope = str(extra.get("scope") or "all")
    _retire_cluster_rights(ctx, aap_namespace(ctx))
    # Create when missing so Controller cleanup still runs after the namespace is gone.
    _prepare_namespace(ctx, fleet_ns, create=True, bind_scc=present or scope == "node")
    purpose = _playbook_purpose(playbook)
    rewritten, pull_secret, ca_bundle = _rewrite_extra(extra)
    files = {playbook.name: read_text(f"playbooks/{playbook.name}")}
    if rewritten.get("entrypoint_path"):
        files["entrypoint.sh"] = read_text("entrypoint.sh")
    secret_files = {}
    if pull_secret:
        secret_files["pull-secret.json"] = pull_secret
    if ca_bundle:
        secret_files["ca.crt"] = ca_bundle
    playbook_job.run(
        ctx,
        playbook_job.PlaybookJob(
            label="Fleet",
            name=f"aap-demo-fleet-{playbook.stem}-{uuid.uuid4().hex[:8]}",
            namespace=job_ns,
            image=image,
            playbook=playbook.name,
            purpose=purpose,
            files=files,
            extra_vars=rewritten,
            mount_root=_MOUNT_ROOT,
            secret_files=secret_files,
            use_ca=bool(ca_bundle),
            grants=((fleet_ns, RUNNER_ACCOUNT),),
            pull_secret_source=aap_namespace(ctx),
        ),
    )


def _playbook_purpose(playbook: Path) -> str:
    try:
        return _PLAYBOOK_PURPOSES[playbook.name]
    except KeyError as exc:
        raise AddonError(f"unsupported fleet playbook: {playbook.name}") from exc


def _apply_checked(ctx: AppContext, manifest: str) -> None:
    apply_or_raise(ctx, manifest, message=_APPLY_ERROR)


def _retire_cluster_rights(ctx: AppContext, aap_ns: str) -> None:
    """Drop the old cluster-scoped runner when it is still our binding."""
    binding = _read("clusterrolebinding", RUNNER_ACCOUNT, ctx)
    if binding is None:
        _delete_our_clusterrole(ctx)
        _delete_our_account(ctx, aap_ns)
        return
    role_ref = as_dict(binding.get("roleRef"))
    if role_ref.get("name") not in {"cluster-admin", RUNNER_ACCOUNT}:
        return
    _delete_ok(
        ctx,
        ["kubectl", "delete", "clusterrolebinding", RUNNER_ACCOUNT, "--ignore-not-found"],
    )
    _delete_our_clusterrole(ctx)
    _delete_our_account(ctx, aap_ns)


def _delete_our_clusterrole(ctx: AppContext) -> None:
    if _read("clusterrole", RUNNER_ACCOUNT, ctx) is None:
        return
    _delete_ok(ctx, ["kubectl", "delete", "clusterrole", RUNNER_ACCOUNT, "--ignore-not-found"])


def _delete_our_account(ctx: AppContext, namespace: str) -> None:
    if _read("serviceaccount", RUNNER_ACCOUNT, ctx, namespace=namespace) is None:
        return
    _delete_ok(
        ctx,
        [
            "kubectl",
            "delete",
            "serviceaccount",
            RUNNER_ACCOUNT,
            "-n",
            namespace,
            "--ignore-not-found",
        ],
    )


def _read(kind: str, name: str, ctx: AppContext, *, namespace: str = "") -> dict | None:
    return read_object(ctx, kind, name, namespace=namespace)


def _delete_ok(
    ctx: AppContext, argv: list, *, message: str = "could not remove the old fleet runner role"
) -> None:
    run_or_raise(ctx, argv, message=message)


def _prepare_namespace(ctx: AppContext, namespace: str, *, create: bool, bind_scc: bool) -> bool:
    """Own the node namespace and the separate namespace that runs the Job."""
    token = _token_for(ctx, namespace, create=create, uid_key="namespace_uid")
    if token is None:
        return False
    job_ns = runner_namespace(namespace)
    if _token_for(ctx, job_ns, create=create, uid_key="runner_namespace_uid") is None:
        return False
    _apply_node_access(ctx, namespace, job_ns, token, bind_scc=bind_scc)
    _apply_runner_access(ctx, job_ns, token)
    _capture_uid(ctx, namespace, "namespace_uid")
    _capture_uid(ctx, job_ns, "runner_namespace_uid")
    return True


def _token_for(ctx: AppContext, namespace: str, *, create: bool, uid_key: str) -> str | None:
    stored = namespace_token_for(ctx)
    existing = ctx.runner.run(["kubectl", "get", "namespace", namespace, "-o", "json"])
    if not existing.ok:
        if not is_missing(existing.stderr or existing.stdout or ""):
            raise AddonError(
                f"could not read namespace {namespace}",
                hint=(existing.stderr or existing.stdout or "").strip() or None,
            )
        if not create:
            return None
        # Also covers a cluster deleted outside aap-demo, for example with crc delete.
        forget_namespace_uid(ctx, uid_key)
        token = stored or secrets.token_hex(16)
        remember_namespace_token(ctx, token)
        return token
    return _require_owned(namespace, existing.stdout or "", stored, namespace_uid_for(ctx, uid_key))


def _apply_node_access(
    ctx: AppContext, namespace: str, job_ns: str, token: str, *, bind_scc: bool
) -> None:
    """Namespace rights plus the narrowly scoped SCC required by Fleet sshd."""
    ctx.runner.run(
        [
            "kubectl",
            "delete",
            "rolebinding",
            RUNNER_ACCOUNT,
            "-n",
            namespace,
            "--ignore-not-found",
        ]
    )
    ctx.runner.run(
        [
            "kubectl",
            "delete",
            "rolebinding",
            RUNNER_ACCOUNT,
            "-n",
            job_ns,
            "--ignore-not-found",
        ]
    )
    documents: List[Dict[str, Any]] = [
        _namespace_body(namespace, token),
        _node_role(namespace),
    ]
    ctx.runner.run(
        [
            "kubectl",
            "delete",
            "rolebinding",
            "fleet-anyuid",
            "-n",
            namespace,
            "--ignore-not-found",
        ]
    )
    if bind_scc:
        documents.extend(
            [
                _node_account(namespace),
                _fleet_scc(),
                _fleet_scc_role(),
                _fleet_scc_binding(namespace),
            ]
        )
    else:
        ctx.runner.run(
            [
                "kubectl",
                "delete",
                "rolebinding",
                FLEET_SCC_BINDING,
                "-n",
                namespace,
                "--ignore-not-found",
            ]
        )
        _delete_ok(
            ctx,
            ["kubectl", "delete", "clusterrole", FLEET_SCC_ROLE, "--ignore-not-found"],
        )
        _delete_ok(
            ctx,
            ["kubectl", "delete", "scc", FLEET_SCC, "--ignore-not-found"],
        )
    _apply_checked(ctx, yaml.safe_dump_all(documents, sort_keys=False))


def _apply_runner_access(ctx: AppContext, job_ns: str, token: str) -> None:
    """Create the runner namespace. Each Job gets its own account."""
    _apply_checked(ctx, yaml.safe_dump(_namespace_body(job_ns, token), sort_keys=False))


def _namespace_body(namespace: str, token: str) -> Dict[str, Any]:
    return {
        "apiVersion": "v1",
        "kind": "Namespace",
        "metadata": {
            "name": namespace,
            "labels": {FLEET_LABEL: "true"},
            "annotations": {TOKEN_ANNOTATION: token},
        },
    }


def _node_role(namespace: str) -> Dict[str, Any]:
    return {
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "Role",
        "metadata": {"name": RUNNER_ACCOUNT, "namespace": namespace},
        "rules": [
            {
                "apiGroups": [""],
                "resources": ["secrets"],
                "verbs": ["create"],
            },
            {
                "apiGroups": [""],
                "resources": ["secrets"],
                "resourceNames": ["fleet-ssh", "pull-secret"],
                "verbs": ["get", "update", "patch", "delete"],
            },
            {
                "apiGroups": [""],
                "resources": [
                    "configmaps",
                    "services",
                    "serviceaccounts",
                    "persistentvolumeclaims",
                ],
                "verbs": ["get", "list", "watch", "create", "update", "patch", "delete"],
            },
            {
                "apiGroups": ["apps"],
                "resources": ["deployments", "deployments/scale"],
                "verbs": ["get", "list", "watch", "create", "update", "patch", "delete"],
            },
        ],
    }


def _node_account(namespace: str) -> Dict[str, Any]:
    return {
        "apiVersion": "v1",
        "kind": "ServiceAccount",
        "metadata": {"name": "fleet-node", "namespace": namespace},
        "automountServiceAccountToken": False,
    }


SELINUX_TYPE = "container_init_t"


def _fleet_scc() -> Dict[str, Any]:
    return {
        "apiVersion": "security.openshift.io/v1",
        "kind": "SecurityContextConstraints",
        "metadata": {"name": FLEET_SCC},
        "priority": 20,
        "allowHostDirVolumePlugin": False,
        "allowHostIPC": False,
        "allowHostNetwork": False,
        "allowHostPID": False,
        "allowHostPorts": False,
        "allowPrivilegedContainer": False,
        "allowedCapabilities": ["SYS_CHROOT", "AUDIT_WRITE"],
        "fsGroup": {"type": "RunAsAny"},
        "readOnlyRootFilesystem": False,
        "requiredDropCapabilities": ["MKNOD"],
        "runAsUser": {"type": "MustRunAs", "uid": 0},
        # container_init_t is container-selinux's type for a container whose
        # PID 1 is systemd. It may write its own cgroup, which container_t may
        # not, so the VM's container_manage_cgroup boolean stays off. The MCS
        # level still comes from the namespace.
        "seLinuxContext": {"type": "MustRunAs", "seLinuxOptions": {"type": SELINUX_TYPE}},
        "supplementalGroups": {"type": "RunAsAny"},
        "volumes": [
            "configMap",
            "downwardAPI",
            "emptyDir",
            "persistentVolumeClaim",
            "projected",
            "secret",
        ],
    }


def _fleet_scc_role() -> Dict[str, Any]:
    return {
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "ClusterRole",
        "metadata": {"name": FLEET_SCC_ROLE},
        "rules": [
            {
                "apiGroups": ["security.openshift.io"],
                "resources": ["securitycontextconstraints"],
                "resourceNames": [FLEET_SCC],
                "verbs": ["use"],
            }
        ],
    }


def _fleet_scc_binding(namespace: str) -> Dict[str, Any]:
    return {
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "RoleBinding",
        "metadata": {"name": FLEET_SCC_BINDING, "namespace": namespace},
        "roleRef": {
            "apiGroup": "rbac.authorization.k8s.io",
            "kind": "ClusterRole",
            "name": FLEET_SCC_ROLE,
        },
        "subjects": [{"kind": "ServiceAccount", "name": "fleet-node", "namespace": namespace}],
    }


def delete_fleet_scc(ctx: AppContext) -> None:
    """Remove the cluster-scoped SCC even when the playbook cannot run."""
    _delete_ok(
        ctx,
        ["kubectl", "delete", "clusterrole", FLEET_SCC_ROLE, "--ignore-not-found"],
        message="could not delete the fleet SCC role",
    )
    _delete_ok(
        ctx,
        ["kubectl", "delete", "scc", FLEET_SCC, "--ignore-not-found"],
        message="could not delete the fleet SCC",
    )


def delete_owned_namespace(ctx: AppContext, namespace: str, *, uid_key: str) -> None:
    """Delete a namespace only when its API UID matches this install."""
    existing = ctx.runner.run(["kubectl", "get", "namespace", namespace, "-o", "json"])
    if not existing.ok:
        detail = existing.stderr or existing.stdout or ""
        if is_missing(detail):
            return
        raise AddonError(
            f"could not read namespace {namespace}",
            hint=detail.strip() or None,
        )
    _require_owned(
        namespace,
        existing.stdout or "",
        namespace_token_for(ctx),
        namespace_uid_for(ctx, uid_key),
    )
    deleted = ctx.runner.run(["kubectl", "delete", "namespace", namespace])
    if not deleted.ok:
        raise AddonError(
            f"could not delete namespace {namespace}",
            hint=(deleted.stderr or deleted.stdout or "").strip() or None,
        )


def _require_owned(namespace: str, payload: str, token: str, uid: str = "") -> str:
    try:
        document = json.loads(payload or "{}")
    except json.JSONDecodeError as exc:
        raise AddonError(
            f"could not read namespace {namespace}",
            hint=str(exc),
        ) from exc
    meta = as_dict(document.get("metadata"))
    live_uid = str((meta or {}).get("uid") or "")
    if uid:
        if live_uid != uid:
            raise AddonError(
                f"refusing to use namespace {namespace}",
                hint="The namespace UID does not match this install.",
            )
        return token
    annotations = (meta or {}).get("annotations") or {}
    found = str(annotations.get(TOKEN_ANNOTATION) or "")
    if not token or found != token:
        raise AddonError(
            f"refusing to use namespace {namespace}",
            hint=(
                "Fleet did not create this namespace. "
                "Choose another namespace, or delete it yourself."
            ),
        )
    return token


def _capture_uid(ctx: AppContext, namespace: str, key: str) -> None:
    existing = ctx.runner.run(["kubectl", "get", "namespace", namespace, "-o", "json"])
    if not existing.ok or not (existing.stdout or "").strip():
        return
    try:
        document = json.loads(existing.stdout)
    except json.JSONDecodeError:
        return
    meta = document.get("metadata") if isinstance(document, dict) else {}
    uid = str((meta or {}).get("uid") or "")
    if not uid:
        return
    stored = namespace_uid_for(ctx, key)
    if stored and stored != uid:
        raise AddonError(
            f"refusing to use namespace {namespace}",
            hint="The namespace UID does not match this install.",
        )
    remember_namespace_uid(ctx, key, uid)


def _rewrite_extra(extra: Dict[str, Any]) -> tuple:
    rewritten = dict(extra)
    pull_secret = ""
    host_pull = str(rewritten.get("pull_secret_path") or "")
    if host_pull:
        path = Path(host_pull)
        if path.is_file():
            pull_secret = path.read_text(encoding="utf-8")
            rewritten["pull_secret_path"] = f"{_EXTRA_ROOT}/pull-secret.json"
        else:
            rewritten["pull_secret_path"] = ""
    ca_bundle = ""
    host_ca = str(rewritten.get("aap_ca_path") or "")
    if host_ca:
        ca_path = Path(host_ca)
        if ca_path.is_file():
            ca_bundle = ca_path.read_text(encoding="utf-8")
            rewritten["aap_ca_path"] = f"{_EXTRA_ROOT}/ca.crt"
        else:
            rewritten["aap_ca_path"] = ""
    if rewritten.get("entrypoint_path"):
        rewritten["entrypoint_path"] = f"{_PLAYBOOK_ROOT}/entrypoint.sh"
    return rewritten, pull_secret, ca_bundle
