"""Run one playbook as a Kubernetes Job in the cluster's execution environment.

The caller owns the namespace the Job runs in and any rights the playbook needs
elsewhere. This module creates what one run needs, waits for the result, and
deletes everything it created, success or not:

- a ServiceAccount that exists only for this Job, with a Role that can read only
  the Job's own ConfigMap and Secret
- RoleBindings in other namespaces, for each ``grants`` entry
- the ConfigMap with the playbook files, and a Secret with the extra vars and
  any secret files
- a copy of the AAP namespace's image pull secret, when there is one
- the Job, with a host alias so the public route name reaches the in-cluster router
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Dict, List, Sequence, Tuple
from urllib.parse import urlparse

import yaml

from aap_demo.addons.common.kube import apply_or_raise, as_dict, output_of
from aap_demo.core import waiting
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError

JOB_TIMEOUT_SECONDS = 600
JOB_POLL_SECONDS = 5


@dataclass(frozen=True)
class PlaybookJob:
    """One playbook run. ``label`` names the addon in progress and error text."""

    label: str
    name: str
    namespace: str
    image: str
    playbook: str
    purpose: str
    files: Dict[str, str]
    extra_vars: Dict[str, Any]
    mount_root: str
    secret_files: Dict[str, str] = field(default_factory=dict)
    use_ca: bool = False
    #: (namespace, Role name) pairs the Job's account is bound to.
    grants: Sequence[Tuple[str, str]] = ()
    #: Namespace whose dockerconfigjson secret the Job pulls the EE with.
    pull_secret_source: str = ""

    @property
    def playbook_root(self) -> str:
        return f"{self.mount_root}/playbooks"

    @property
    def extra_root(self) -> str:
        return f"{self.mount_root}/extra"

    @property
    def pull_name(self) -> str:
        return f"{self.name}-pull"


def run(ctx: AppContext, job: PlaybookJob) -> None:
    """Run the Job to completion, then delete what it created. Raise on failure."""
    label = job.label.lower()
    ctx.console.progress(f"Submitting {job.label} job: {job.purpose}")
    playbook_error: AddonError | None = None
    try:
        _grant_mounts(ctx, job)
        used_pull = (
            _stage_pull_secret(ctx, job, job.pull_secret_source) if job.pull_secret_source else ""
        )
        aliases = _aliases_for(ctx, job.extra_vars)
        message = f"could not apply the {label} playbook job"
        apply_or_raise(ctx, _configmap(job), message=message)
        apply_or_raise(ctx, _secret(job), message=message)
        apply_or_raise(ctx, _job(job, aliases, used_pull), message=message)
        ctx.console.progress(
            f"{job.label} job submitted to {job.namespace}: {job.purpose}; waiting up to "
            f"{JOB_TIMEOUT_SECONDS // 60} minutes for completion"
        )
        if not job_succeeded(ctx, job.name, job.namespace, description=f"{job.label} job"):
            logs = ctx.runner.run(["kubectl", "logs", f"job/{job.name}", "-n", job.namespace])
            detail = (logs.stdout or logs.stderr or "").strip()
            playbook_error = AddonError(
                f"playbook failed: {job.playbook}",
                hint=detail[-2000:] or None,
            )
    finally:
        results = [
            ctx.runner.run(
                [
                    "kubectl",
                    "delete",
                    "-n",
                    job.namespace,
                    "--ignore-not-found",
                    f"job/{job.name}",
                    f"configmap/{job.name}",
                    f"secret/{job.name}",
                    f"secret/{job.pull_name}",
                    f"serviceaccount/{job.name}",
                    f"role/{job.name}",
                    f"rolebinding/{job.name}",
                ]
            )
        ]
        for namespace, _role in job.grants:
            results.append(
                ctx.runner.run(
                    [
                        "kubectl",
                        "delete",
                        "rolebinding",
                        job.name,
                        "-n",
                        namespace,
                        "--ignore-not-found",
                    ]
                )
            )
    cleanup_hint = "\n".join(
        part for part in (output_of(result) for result in results if not result.ok) if part
    )
    if playbook_error is not None:
        if cleanup_hint:
            hint = "\n".join(part for part in (playbook_error.hint, cleanup_hint) if part)
            playbook_error = AddonError(playbook_error.message, hint=hint or None)
        raise playbook_error
    if cleanup_hint:
        raise AddonError(f"could not delete the {label} playbook secret", hint=cleanup_hint)


def job_succeeded(ctx: AppContext, name: str, namespace: str, *, description: str = "job") -> bool:
    """Stop at the Job's result. ``kubectl wait`` sits out its timeout on a failed Job."""
    outcome = {"status": ""}

    def finished(_n: int) -> bool:
        read = ctx.runner.run(["kubectl", "get", "job", name, "-n", namespace, "-o", "json"])
        try:
            status = as_dict(json.loads(read.stdout or "{}").get("status"))
        except json.JSONDecodeError:
            return False
        for condition in status.get("conditions") or []:
            if isinstance(condition, dict) and condition.get("status") == "True":
                if condition.get("type") in ("Complete", "Failed"):
                    outcome["status"] = str(condition["type"])
                    return True
        return False

    waiting.wait_for(
        finished,
        timeout=JOB_TIMEOUT_SECONDS,
        interval=JOB_POLL_SECONDS,
        description=f"{description} {name}",
    )
    return outcome["status"] == "Complete"


def role_binding(
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


def _grant_mounts(ctx: AppContext, job: PlaybookJob) -> None:
    """A ServiceAccount that exists only for this Job and can read only its mounts."""
    documents: List[Dict[str, Any]] = [
        {
            "apiVersion": "v1",
            "kind": "ServiceAccount",
            "metadata": {"name": job.name, "namespace": job.namespace},
            "automountServiceAccountToken": False,
        },
        {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "Role",
            "metadata": {"name": job.name, "namespace": job.namespace},
            "rules": [
                {
                    "apiGroups": [""],
                    "resources": ["secrets", "configmaps"],
                    "resourceNames": [job.name, job.pull_name],
                    "verbs": ["get"],
                }
            ],
        },
        role_binding(
            job.namespace, job.namespace, name=job.name, subject_name=job.name, role_name=job.name
        ),
    ]
    for namespace, role in job.grants:
        documents.append(
            role_binding(
                namespace, job.namespace, name=job.name, subject_name=job.name, role_name=role
            )
        )
    apply_or_raise(
        ctx,
        yaml.safe_dump_all(documents, sort_keys=False),
        message=f"could not apply the {job.label.lower()} playbook job",
    )


def _stage_pull_secret(ctx: AppContext, job: PlaybookJob, source_ns: str) -> str:
    """Copy the EE pull secret into the Job's namespace so the Job can use it."""
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
        "metadata": {"name": job.pull_name, "namespace": job.namespace},
        "data": {".dockerconfigjson": docker},
    }
    apply_or_raise(
        ctx,
        yaml.safe_dump(body, sort_keys=False),
        message=f"could not apply the {job.label.lower()} playbook job",
    )
    return job.pull_name


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
        meta = as_dict(item.get("metadata"))
        if meta.get("name"):
            names.append(str(meta["name"]))
    if "redhat-operators-pull-secret" in names:
        return "redhat-operators-pull-secret"
    return names[0] if names else ""


def _configmap(job: PlaybookJob) -> str:
    body = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {"name": job.name, "namespace": job.namespace},
        "data": dict(job.files),
    }
    return yaml.safe_dump(body, sort_keys=False)


def _secret(job: PlaybookJob) -> str:
    string_data = {"extra-vars.yml": yaml.safe_dump(job.extra_vars, sort_keys=False)}
    string_data.update(job.secret_files)
    body = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": job.name, "namespace": job.namespace},
        "stringData": string_data,
    }
    return yaml.safe_dump(body, sort_keys=False)


def _job(job: PlaybookJob, aliases: List[Dict[str, Any]], pull_secret_name: str) -> str:
    container: Dict[str, Any] = {
        "name": "ansible",
        "image": job.image,
        "imagePullPolicy": "IfNotPresent",
        "command": [
            "/usr/local/bin/ansible-playbook",
            f"{job.playbook_root}/{job.playbook}",
            "-e",
            f"@{job.extra_root}/extra-vars.yml",
        ],
        "volumeMounts": [
            {"name": "playbooks", "mountPath": job.playbook_root},
            {"name": "extra", "mountPath": job.extra_root, "readOnly": True},
        ],
    }
    if job.use_ca:
        container["env"] = [
            {"name": "REQUESTS_CA_BUNDLE", "value": f"{job.extra_root}/ca.crt"},
            {"name": "SSL_CERT_FILE", "value": f"{job.extra_root}/ca.crt"},
        ]
    pod: Dict[str, Any] = {
        "restartPolicy": "Never",
        "serviceAccountName": job.name,
        "automountServiceAccountToken": True,
        "containers": [container],
        "volumes": [
            {"name": "playbooks", "configMap": {"name": job.name}},
            {"name": "extra", "secret": {"secretName": job.name}},
        ],
    }
    if pull_secret_name:
        pod["imagePullSecrets"] = [{"name": pull_secret_name}]
    if aliases:
        pod["hostAliases"] = aliases
    body = {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {"name": job.name, "namespace": job.namespace},
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
