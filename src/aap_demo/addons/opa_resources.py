"""Desired Kubernetes resources owned by the native OPA addon."""

from __future__ import annotations

import re
from typing import Any, Dict, List

OWNER = "aap-demo-opa"
PART_OF = "aap-demo"
_VERSION = re.compile(r"^[A-Za-z0-9._-]+$")
_NAMES = ("deployment/opa", "service/opa", "route/opa")


def resource_names() -> tuple[str, ...]:
    """Return the kubectl resource names owned by OPA."""
    return _NAMES


def resource_documents(namespace: str, opa_version: str, route_host: str) -> List[Dict[str, Any]]:
    """Build the OPA Deployment, Service, and OpenShift Route."""
    if not opa_version or not _VERSION.fullmatch(opa_version):
        raise ValueError("OPA version must contain only image-tag-safe characters")
    labels = {
        "app": "opa",
        "app.kubernetes.io/name": "opa",
        "app.kubernetes.io/managed-by": OWNER,
        "app.kubernetes.io/part-of": PART_OF,
    }
    pod_labels = {"app": "opa", "app.kubernetes.io/name": "opa"}
    return [
        {
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {"name": "opa", "namespace": namespace, "labels": labels},
            "spec": {
                "replicas": 1,
                "selector": {"matchLabels": {"app": "opa"}},
                "template": {
                    "metadata": {"labels": pod_labels},
                    "spec": {
                        "automountServiceAccountToken": False,
                        "containers": [
                            {
                                "name": "opa",
                                "image": f"openpolicyagent/opa:{opa_version}",
                                "imagePullPolicy": "IfNotPresent",
                                "args": ["run", "--server", "--addr", "0.0.0.0:8181"],
                                "ports": [{"name": "http", "containerPort": 8181}],
                                "readinessProbe": {
                                    "httpGet": {"path": "/health", "port": "http"},
                                    "periodSeconds": 5,
                                    "failureThreshold": 12,
                                },
                                "securityContext": {
                                    "allowPrivilegeEscalation": False,
                                    "capabilities": {"drop": ["ALL"]},
                                    "runAsNonRoot": True,
                                    "seccompProfile": {"type": "RuntimeDefault"},
                                },
                            }
                        ],
                    },
                },
            },
        },
        {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {"name": "opa", "namespace": namespace, "labels": labels},
            "spec": {
                "selector": {"app": "opa"},
                "ports": [{"name": "http", "port": 8181, "targetPort": "http"}],
            },
        },
        {
            "apiVersion": "route.openshift.io/v1",
            "kind": "Route",
            "metadata": {"name": "opa", "namespace": namespace, "labels": labels},
            "spec": {
                "host": route_host,
                "to": {"kind": "Service", "name": "opa"},
                "port": {"targetPort": "http"},
                "tls": {"termination": "edge", "insecureEdgeTerminationPolicy": "Redirect"},
            },
        },
    ]


def owned(document: Dict[str, Any]) -> bool:
    """Return whether a live object has the native OPA ownership identity."""
    metadata = document.get("metadata") or {}
    labels = metadata.get("labels") or {}
    return (
        labels.get("app") == "opa"
        and labels.get("app.kubernetes.io/managed-by") == OWNER
        and labels.get("app.kubernetes.io/part-of") == PART_OF
    )
