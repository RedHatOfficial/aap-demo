"""Run one fleet playbook as a Job in the cluster execution environment."""

from __future__ import annotations

import uuid
from pathlib import Path
from typing import Any, Dict, List
from urllib.parse import urlparse

import yaml

from aap_demo.addons.fleet.ee import discover_image
from aap_demo.addons.fleet.gateway import aap_namespace
from aap_demo.addons.fleet.resources import read_text
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError
from aap_demo.exec import kubectl

RUNNER_ACCOUNT = "aap-demo-fleet-runner"
_PLAYBOOK_ROOT = "/opt/fleet/playbooks"
_EXTRA_ROOT = "/opt/fleet/extra"


def run_playbook(ctx: AppContext, playbook: Path, extra: Dict[str, Any]) -> None:
    """Apply the playbook with the cluster's ee-supported image, then delete the Job."""
    image = discover_image(ctx)
    namespace = aap_namespace(ctx)
    _ensure_runner(ctx, namespace)
    name = f"aap-demo-fleet-{playbook.stem}-{uuid.uuid4().hex[:8]}"
    rewritten, pull_secret, ca_bundle = _rewrite_extra(extra)
    aliases = _aliases_for(ctx, rewritten)
    pull_name = _ee_pull_secret(ctx, namespace)
    ctx.console.progress(f"Running {playbook.name} in the execution environment")
    try:
        kubectl.apply_stdin(ctx.runner, _configmap(name, namespace, playbook, rewritten))
        kubectl.apply_stdin(
            ctx.runner, _extra_secret(name, namespace, rewritten, pull_secret, ca_bundle)
        )
        kubectl.apply_stdin(
            ctx.runner,
            _job(name, namespace, image, playbook.name, aliases, pull_name, bool(ca_bundle)),
        )
        waited = ctx.runner.run(
            [
                "kubectl",
                "wait",
                "--for=condition=complete",
                f"job/{name}",
                "-n",
                namespace,
                "--timeout=600s",
            ]
        )
        if not waited.ok:
            logs = ctx.runner.run(["kubectl", "logs", f"job/{name}", "-n", namespace])
            detail = (logs.stdout or logs.stderr or waited.stderr or "").strip()
            raise AddonError(
                f"playbook failed: {playbook.name}",
                hint=detail[-2000:] or None,
            )
    finally:
        ctx.runner.run(
            [
                "kubectl",
                "delete",
                "job",
                name,
                "configmap",
                name,
                "secret",
                name,
                "-n",
                namespace,
                "--ignore-not-found",
            ]
        )


def _ensure_runner(ctx: AppContext, namespace: str) -> None:
    """Replace any old cluster-admin binding with a role that only runs fleet."""
    ctx.runner.run(
        ["kubectl", "delete", "clusterrolebinding", RUNNER_ACCOUNT, "--ignore-not-found"]
    )
    account = {
        "apiVersion": "v1",
        "kind": "ServiceAccount",
        "metadata": {"name": RUNNER_ACCOUNT, "namespace": namespace},
    }
    role = {
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "ClusterRole",
        "metadata": {"name": RUNNER_ACCOUNT},
        "rules": [
            {
                "apiGroups": [""],
                "resources": ["namespaces"],
                "verbs": ["get", "create", "update", "patch", "delete"],
            },
            {
                "apiGroups": [""],
                "resources": [
                    "secrets",
                    "configmaps",
                    "services",
                    "serviceaccounts",
                    "persistentvolumeclaims",
                    "pods",
                ],
                "verbs": ["get", "list", "watch", "create", "update", "patch", "delete"],
            },
            {
                "apiGroups": ["apps"],
                "resources": ["deployments", "deployments/scale"],
                "verbs": ["get", "list", "watch", "create", "update", "patch", "delete"],
            },
            {
                "apiGroups": ["rbac.authorization.k8s.io"],
                "resources": ["rolebindings"],
                "verbs": ["get", "list", "create", "update", "patch", "delete"],
            },
            {
                "apiGroups": ["rbac.authorization.k8s.io"],
                "resources": ["clusterroles"],
                "resourceNames": ["system:openshift:scc:anyuid"],
                "verbs": ["bind"],
            },
        ],
    }
    binding = {
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "ClusterRoleBinding",
        "metadata": {"name": RUNNER_ACCOUNT},
        "roleRef": {
            "apiGroup": "rbac.authorization.k8s.io",
            "kind": "ClusterRole",
            "name": RUNNER_ACCOUNT,
        },
        "subjects": [
            {"kind": "ServiceAccount", "name": RUNNER_ACCOUNT, "namespace": namespace},
        ],
    }
    kubectl.apply_stdin(ctx.runner, yaml.safe_dump_all([account, role, binding], sort_keys=False))


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


def _ee_pull_secret(ctx: AppContext, namespace: str) -> str:
    """Use a docker config already in the AAP namespace, when one exists."""
    result = ctx.runner.run(
        [
            "kubectl",
            "get",
            "secrets",
            "-n",
            namespace,
            "-o",
            "jsonpath={.items[?(@.type=='kubernetes.io/dockerconfigjson')].metadata.name}",
        ]
    )
    if not result.ok:
        return ""
    names = (result.stdout or "").split()
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
        "serviceAccountName": RUNNER_ACCOUNT,
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
