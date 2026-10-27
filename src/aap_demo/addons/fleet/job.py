"""Run one fleet playbook as a Job in the cluster execution environment."""

from __future__ import annotations

import hashlib
import json
import secrets
import uuid
from pathlib import Path
from typing import Any, Dict, List
from urllib.parse import urlparse

import yaml

from aap_demo.addons.fleet.ee import discover_image
from aap_demo.addons.fleet.gateway import aap_namespace
from aap_demo.addons.fleet.resources import read_text
from aap_demo.addons.fleet.state import (
    namespace_token_for,
    namespace_uid_for,
    remember_namespace_token,
    remember_namespace_uid,
)
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError
from aap_demo.exec import kubectl

RUNNER_ACCOUNT = "aap-demo-fleet-runner"
FLEET_LABEL = "aap-demo/fleet"
TOKEN_ANNOTATION = "aap-demo/fleet-token"
FLEET_SCC = "aap-demo-fleet"
FLEET_SCC_ROLE = "system:openshift:scc:aap-demo-fleet"
FLEET_SCC_BINDING = "fleet-ssh-scc"
_PLAYBOOK_ROOT = "/opt/fleet/playbooks"
_JOB_TIMEOUT_SECONDS = 600
_EXTRA_ROOT = "/opt/fleet/extra"
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
    image = discover_image(ctx)
    fleet_ns = str(extra.get("namespace") or "fleet")
    job_ns = runner_namespace(fleet_ns)
    present = str(extra.get("state") or "present") != "absent"
    scope = str(extra.get("scope") or "all")
    _retire_cluster_rights(ctx, aap_namespace(ctx))
    # Create when missing so Controller cleanup still runs after the namespace is gone.
    _prepare_namespace(ctx, fleet_ns, create=True, bind_scc=present or scope == "node")
    name = f"aap-demo-fleet-{playbook.stem}-{uuid.uuid4().hex[:8]}"
    pull_name = f"{name}-pull"
    purpose = _playbook_purpose(playbook)
    ctx.console.progress(f"Submitting Fleet job: {purpose}")
    playbook_error: AddonError | None = None
    try:
        _grant_runner_mounts(ctx, fleet_ns, job_ns, name, pull_name)
        rewritten, pull_secret, ca_bundle = _rewrite_extra(extra)
        used_pull = _stage_pull_secret(ctx, aap_namespace(ctx), job_ns, pull_name)
        aliases = _aliases_for(ctx, rewritten)
        _apply_checked(ctx, _configmap(name, job_ns, playbook, rewritten))
        _apply_checked(ctx, _extra_secret(name, job_ns, rewritten, pull_secret, ca_bundle))
        _apply_checked(
            ctx,
            _job(name, job_ns, image, playbook.name, aliases, used_pull, bool(ca_bundle)),
        )
        ctx.console.progress(
            f"Fleet job submitted to {job_ns}: {purpose}; waiting up to "
            f"{_JOB_TIMEOUT_SECONDS // 60} minutes for completion"
        )
        waited = ctx.runner.run(
            [
                "kubectl",
                "wait",
                "--for=condition=complete",
                f"job/{name}",
                "-n",
                job_ns,
                f"--timeout={_JOB_TIMEOUT_SECONDS}s",
            ]
        )
        if not waited.ok:
            logs = ctx.runner.run(["kubectl", "logs", f"job/{name}", "-n", job_ns])
            detail = (logs.stdout or logs.stderr or waited.stderr or "").strip()
            playbook_error = AddonError(
                f"playbook failed: {playbook.name}",
                hint=detail[-2000:] or None,
            )
    finally:
        deleted = ctx.runner.run(
            [
                "kubectl",
                "delete",
                "-n",
                job_ns,
                "--ignore-not-found",
                f"job/{name}",
                f"configmap/{name}",
                f"secret/{name}",
                f"secret/{pull_name}",
                f"serviceaccount/{name}",
                f"role/{name}",
                f"rolebinding/{name}",
            ]
        )
        binding = ctx.runner.run(
            [
                "kubectl",
                "delete",
                "rolebinding",
                name,
                "-n",
                fleet_ns,
                "--ignore-not-found",
            ]
        )
    cleanup_hint = "\n".join(
        part
        for part in (
            (deleted.stderr or deleted.stdout or "").strip() if not deleted.ok else "",
            (binding.stderr or binding.stdout or "").strip() if not binding.ok else "",
        )
        if part
    )
    if playbook_error is not None:
        if cleanup_hint:
            hint = "\n".join(part for part in (playbook_error.hint, cleanup_hint) if part)
            playbook_error = AddonError(playbook_error.message, hint=hint or None)
        raise playbook_error
    if cleanup_hint:
        raise AddonError("could not delete the fleet playbook secret", hint=cleanup_hint)


def _playbook_purpose(playbook: Path) -> str:
    try:
        return _PLAYBOOK_PURPOSES[playbook.name]
    except KeyError as exc:
        raise AddonError(f"unsupported fleet playbook: {playbook.name}") from exc


def _apply_checked(ctx: AppContext, manifest: str) -> None:
    applied = kubectl.apply_stdin(ctx.runner, manifest)
    if not applied.ok:
        raise AddonError(
            "could not apply the fleet playbook job",
            hint=(applied.stderr or applied.stdout or "").strip() or None,
        )


def _retire_cluster_rights(ctx: AppContext, aap_ns: str) -> None:
    """Drop the old cluster-scoped runner when it is still our binding."""
    binding = _read("clusterrolebinding", RUNNER_ACCOUNT, ctx)
    if binding is None:
        _delete_our_clusterrole(ctx)
        _delete_our_account(ctx, aap_ns)
        return
    role_ref = binding.get("roleRef") if isinstance(binding.get("roleRef"), dict) else {}
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
    argv = ["kubectl", "get", kind, name]
    if namespace:
        argv.extend(["-n", namespace])
    argv.extend(["-o", "json"])
    result = ctx.runner.run(argv)
    if not result.ok:
        detail = result.stderr or result.stdout or ""
        if _missing(detail):
            return None
        raise AddonError(
            f"could not read {kind} {name}",
            hint=detail.strip() or None,
        )
    try:
        document = json.loads(result.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise AddonError(f"could not read {kind} {name}", hint=str(exc)) from exc
    return document if isinstance(document, dict) else None


def _delete_ok(
    ctx: AppContext, argv: list, *, message: str = "could not remove the old fleet runner role"
) -> None:
    deleted = ctx.runner.run(argv)
    if not deleted.ok:
        raise AddonError(
            message,
            hint=(deleted.stderr or deleted.stdout or "").strip() or None,
        )


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
        if not _missing(existing.stderr or existing.stdout or ""):
            raise AddonError(
                f"could not read namespace {namespace}",
                hint=(existing.stderr or existing.stdout or "").strip() or None,
            )
        if not create:
            return None
        token = stored or secrets.token_hex(16)
        remember_namespace_token(ctx, token)
        return token
    return _require_owned(namespace, existing.stdout or "", stored, namespace_uid_for(ctx, uid_key))


def _missing(detail: str) -> bool:
    text = detail.lower()
    return "notfound" in text or "not found" in text


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


def _grant_runner_mounts(
    ctx: AppContext, fleet_ns: str, job_ns: str, name: str, pull_name: str
) -> None:
    """A ServiceAccount that exists only for this Job and can read only its mounts."""
    documents = [
        {
            "apiVersion": "v1",
            "kind": "ServiceAccount",
            "metadata": {"name": name, "namespace": job_ns},
            "automountServiceAccountToken": False,
        },
        {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "Role",
            "metadata": {"name": name, "namespace": job_ns},
            "rules": [
                {
                    "apiGroups": [""],
                    "resources": ["secrets", "configmaps"],
                    "resourceNames": [name, pull_name],
                    "verbs": ["get"],
                }
            ],
        },
        _role_binding(job_ns, job_ns, name=name, subject_name=name, role_name=name),
        _role_binding(
            fleet_ns,
            job_ns,
            name=name,
            subject_name=name,
            role_name=RUNNER_ACCOUNT,
        ),
    ]
    _apply_checked(ctx, yaml.safe_dump_all(documents, sort_keys=False))


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


def _role_binding(
    namespace: str,
    subject_namespace: str,
    *,
    name: str,
    subject_name: str,
    role_name: str,
) -> Dict[str, Any]:
    return {
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "RoleBinding",
        "metadata": {"name": name, "namespace": namespace},
        "roleRef": {
            "apiGroup": "rbac.authorization.k8s.io",
            "kind": "Role",
            "name": role_name,
        },
        "subjects": [
            {"kind": "ServiceAccount", "name": subject_name, "namespace": subject_namespace}
        ],
    }


def _node_account(namespace: str) -> Dict[str, Any]:
    return {
        "apiVersion": "v1",
        "kind": "ServiceAccount",
        "metadata": {"name": "fleet-node", "namespace": namespace},
        "automountServiceAccountToken": False,
    }


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
        "seLinuxContext": {"type": "MustRunAs"},
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
        if _missing(detail):
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
    meta = document.get("metadata") if isinstance(document.get("metadata"), dict) else {}
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


def _stage_pull_secret(ctx: AppContext, source_ns: str, dest_ns: str, secret_name: str) -> str:
    """Copy the EE pull secret into the runner namespace so this Job can use it."""
    name = _ee_pull_secret(ctx, source_ns)
    if not name:
        return ""
    result = ctx.runner.run(["kubectl", "get", "secret", name, "-n", source_ns, "-o", "json"])
    if not result.ok or not (result.stdout or "").strip():
        return ""
    try:
        document = json.loads(result.stdout)
    except json.JSONDecodeError:
        return ""
    data = document.get("data") if isinstance(document, dict) else None
    docker = (data or {}).get(".dockerconfigjson") if isinstance(data, dict) else None
    if not docker:
        return ""
    body = {
        "apiVersion": "v1",
        "kind": "Secret",
        "type": "kubernetes.io/dockerconfigjson",
        "metadata": {"name": secret_name, "namespace": dest_ns},
        "data": {".dockerconfigjson": docker},
    }
    _apply_checked(ctx, yaml.safe_dump(body, sort_keys=False))
    return secret_name


def _ee_pull_secret(ctx: AppContext, namespace: str) -> str:
    """Use a docker config already in the AAP namespace, when one exists."""
    result = ctx.runner.run(["kubectl", "get", "secrets", "-n", namespace, "-o", "json"])
    if not result.ok or not (result.stdout or "").strip():
        return ""
    try:
        document = json.loads(result.stdout)
    except json.JSONDecodeError:
        return ""
    names = []
    for item in document.get("items") or []:
        if not isinstance(item, dict) or item.get("type") != "kubernetes.io/dockerconfigjson":
            continue
        meta = item.get("metadata") if isinstance(item.get("metadata"), dict) else {}
        if meta.get("name"):
            names.append(str(meta["name"]))
    if "redhat-operators-pull-secret" in names:
        return "redhat-operators-pull-secret"
    return names[0] if names else ""


def _configmap(name: str, namespace: str, playbook: Path, extra: Dict[str, Any]) -> str:
    data = {playbook.name: read_text(f"playbooks/{playbook.name}")}
    if extra.get("entrypoint_path"):
        data["entrypoint.sh"] = read_text("entrypoint.sh")
    body = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {"name": name, "namespace": namespace},
        "data": data,
    }
    return yaml.safe_dump(body, sort_keys=False)


def _extra_secret(
    name: str,
    namespace: str,
    extra: Dict[str, Any],
    pull_secret: str,
    ca_bundle: str,
) -> str:
    string_data = {"extra-vars.yml": yaml.safe_dump(extra, sort_keys=False)}
    if pull_secret:
        string_data["pull-secret.json"] = pull_secret
    if ca_bundle:
        string_data["ca.crt"] = ca_bundle
    body = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": name, "namespace": namespace},
        "stringData": string_data,
    }
    return yaml.safe_dump(body, sort_keys=False)


def _job(
    name: str,
    namespace: str,
    image: str,
    playbook_name: str,
    aliases: List[Dict[str, Any]],
    pull_secret_name: str,
    use_ca: bool,
) -> str:
    container: Dict[str, Any] = {
        "name": "ansible",
        "image": image,
        "imagePullPolicy": "IfNotPresent",
        "command": [
            "/usr/local/bin/ansible-playbook",
            f"{_PLAYBOOK_ROOT}/{playbook_name}",
            "-e",
            f"@{_EXTRA_ROOT}/extra-vars.yml",
        ],
        "volumeMounts": [
            {"name": "playbooks", "mountPath": _PLAYBOOK_ROOT},
            {"name": "extra", "mountPath": _EXTRA_ROOT, "readOnly": True},
        ],
    }
    if use_ca:
        container["env"] = [
            {"name": "REQUESTS_CA_BUNDLE", "value": f"{_EXTRA_ROOT}/ca.crt"},
            {"name": "SSL_CERT_FILE", "value": f"{_EXTRA_ROOT}/ca.crt"},
        ]
    pod: Dict[str, Any] = {
        "restartPolicy": "Never",
        "serviceAccountName": name,
        "automountServiceAccountToken": True,
        "containers": [container],
        "volumes": [
            {"name": "playbooks", "configMap": {"name": name}},
            {"name": "extra", "secret": {"secretName": name}},
        ],
    }
    if pull_secret_name:
        pod["imagePullSecrets"] = [{"name": pull_secret_name}]
    if aliases:
        pod["hostAliases"] = aliases
    body = {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {"name": name, "namespace": namespace},
        "spec": {
            "backoffLimit": 0,
            "ttlSecondsAfterFinished": 600,
            "template": {"spec": pod},
        },
    }
    return yaml.safe_dump(body, sort_keys=False)


def _aliases_for(ctx: AppContext, extra: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Point the public route name at the in-cluster router.

    aap-demo routes use ``127.0.0.1.nip.io``. Inside a pod that address is
    the pod itself, so the Job would miss the gateway without this alias.
    """
    host = _route_host(str(extra.get("aap_hostname") or ""))
    if not host:
        return []
    result = ctx.runner.run(
        [
            "kubectl",
            "get",
            "svc",
            "router-default",
            "-n",
            "openshift-ingress",
            "-o",
            "jsonpath={.spec.clusterIP}",
        ]
    )
    ip = result.stdout.strip() if result.ok else ""
    if not ip:
        raise AddonError(
            "could not find the ingress router",
            hint="kubectl get svc router-default -n openshift-ingress",
        )
    return [{"ip": ip, "hostnames": [host]}]


def _route_host(url: str) -> str:
    if not url:
        return ""
    parsed = urlparse(url if "://" in url else f"https://{url}")
    return parsed.hostname or ""
