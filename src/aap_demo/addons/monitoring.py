"""Native, low-resource AAP monitoring addon.

The first release uses standalone Prometheus/Grafana and json-exporter. The exporter
queries the AAP Gateway's controller API with the existing admin Secret; Prometheus
never talks directly to the controller or Metrics Service.
"""

from __future__ import annotations

import argparse
import base64
import json
import secrets
from typing import Any, Dict, List

from aap_demo.addons.base import AddonKind
from aap_demo.addons.common import kube
from aap_demo.addons.common.state import enabled_names, set_enabled_names
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError
from aap_demo.exec import kubectl

NAME = "monitoring"
NAMESPACE = "aap-monitoring"
STATE_PASSWORD = "grafana-admin-password"  # pragma: allowlist secret
PROMETHEUS_IMAGE = (
    "quay.io/prometheus/prometheus:v3.16.0@sha256:"
    "9332054523223e2ddc18d8101799d54a4a8d823b030c53216f063a6c117773cd"  # pragma: allowlist secret
)
JSON_EXPORTER_IMAGE = (
    "quay.io/prometheuscommunity/json-exporter:v0.8.0@sha256:"
    "3aad20d41a0b31dfaaf7ab1a091440e92a82a61ef68b76750eac0ad50a983652"  # pragma: allowlist secret
)
GRAFANA_IMAGE = (
    "docker.io/grafana/grafana:13.3.1@sha256:"
    "0615ec4fbd4072004b7d86b46ded63013a74b7d6eb1119273dd89e8fa25c13cf"  # pragma: allowlist secret
)


def _doc(kind: str, name: str, *, labels: Dict[str, str] | None = None, **body: Any) -> dict:
    metadata: Dict[str, Any] = {"name": name, "namespace": NAMESPACE}
    if labels:
        metadata["labels"] = labels
    return {"apiVersion": body.pop("apiVersion", "v1"), "kind": kind, "metadata": metadata, **body}


def _manifest(documents: List[dict]) -> str:
    return "\n---\n".join(json.dumps(document, sort_keys=True) for document in documents)


def _labels(component: str) -> Dict[str, str]:
    return {
        "app.kubernetes.io/managed-by": "aap-demo-monitoring",
        "app.kubernetes.io/name": component,
    }


def _dashboard() -> dict:
    return {
        "id": None,
        "uid": "aap-overview",
        "title": "AAP Platform Overview",
        "schemaVersion": 39,
        "version": 1,
        "refresh": "30s",
        "panels": [
            {
                "id": 1,
                "type": "stat",
                "title": "AAP jobs in history",
                "gridPos": {"h": 5, "w": 8, "x": 0, "y": 0},
                "targets": [{"expr": "aap_jobs_total", "refId": "A"}],
            },
            {
                "id": 2,
                "type": "timeseries",
                "title": "Prometheus scrape health",
                "gridPos": {"h": 8, "w": 16, "x": 8, "y": 0},
                "targets": [{"expr": 'up{job="aap-monitoring-adapter"}', "refId": "A"}],
            },
        ],
        "templating": {"list": []},
        "time": {"from": "now-6h", "to": "now"},
    }


def _documents(password: str, aap_password: str, aap_namespace: str) -> List[dict]:
    ownership = {"app.kubernetes.io/managed-by": "aap-demo-monitoring"}
    prometheus_config = {
        "global": {"scrape_interval": "30s"},
        "scrape_configs": [
            {
                "job_name": "aap-monitoring-adapter",
                "metrics_path": "/probe",
                "params": {
                    "module": ["aap_jobs"],
                    "target": [
                        f"http://aap.{aap_namespace}.svc.cluster.local/api/controller/v2/jobs/?page_size=1"
                    ],
                },
                "static_configs": [
                    {"targets": ["json-exporter.aap-monitoring.svc.cluster.local:7979"]}
                ],
            },
            {"job_name": "prometheus", "static_configs": [{"targets": ["localhost:9090"]}]},
        ],
    }
    exporter_config = {
        "modules": {
            "aap_jobs": {
                "http_client_config": {
                    "basic_auth": {
                        "username": "admin",
                        "password_file": "/etc/aap-monitoring/aap-password",
                    }
                },
                "metrics": [
                    {
                        "name": "aap_jobs_total",
                        "path": "{ .count }",
                        "help": "Number of jobs returned by the AAP controller API.",
                    }
                ],
            }
        }
    }
    return [
        _doc(
            "Namespace",
            NAMESPACE,
            apiVersion="v1",
            metadata={"name": NAMESPACE, "labels": ownership},
        ),
        _doc(
            "Secret",
            "grafana-admin",
            type="Opaque",
            stringData={"admin-user": "admin", "admin-password": password},
        ),
        _doc(
            "Secret",
            "aap-gateway-credentials",
            type="Opaque",
            stringData={"password": aap_password},
        ),
        _doc(
            "ConfigMap",
            "prometheus-config",
            data={"prometheus.yml": json.dumps(prometheus_config, sort_keys=True)},
        ),
        _doc(
            "ConfigMap",
            "json-exporter-config",
            data={"config.yml": json.dumps(exporter_config, sort_keys=True)},
        ),
        _doc(
            "ConfigMap",
            "grafana-dashboard",
            data={"aap-overview.json": json.dumps(_dashboard(), sort_keys=True)},
        ),
        _doc(
            "ConfigMap",
            "grafana-provisioning",
            data={
                "datasources.yaml": (
                    "apiVersion: 1\ndatasources:\n"
                    "- name: Prometheus\n  type: prometheus\n"
                    "  access: proxy\n  url: http://prometheus:9090\n"
                    "  isDefault: true\n"
                ),
                "dashboards.yaml": (
                    "apiVersion: 1\nproviders:\n"
                    "- name: aap-demo\n  type: file\n  updateIntervalSeconds: 30\n"
                    "  options:\n    path: /var/lib/grafana/dashboards\n"
                ),
            },
        ),
        _doc(
            "PersistentVolumeClaim",
            "prometheus-data",
            spec={"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "2Gi"}}},
        ),
        _deployment(
            "prometheus",
            PROMETHEUS_IMAGE,
            ["--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.retention.time=24h"],
        ),
        _deployment(
            "json-exporter", JSON_EXPORTER_IMAGE, ["--config.file=/etc/json-exporter/config.yml"]
        ),
        _deployment("grafana", GRAFANA_IMAGE, []),
        _doc(
            "Service",
            "prometheus",
            spec={"selector": _labels("prometheus"), "ports": [{"name": "http", "port": 9090}]},
        ),
        _doc(
            "Service",
            "json-exporter",
            spec={"selector": _labels("json-exporter"), "ports": [{"name": "http", "port": 7979}]},
        ),
        _doc(
            "Service",
            "grafana",
            spec={"selector": _labels("grafana"), "ports": [{"name": "http", "port": 3000}]},
        ),
        _doc(
            "Route",
            "grafana",
            apiVersion="route.openshift.io/v1",
            spec={
                "to": {"kind": "Service", "name": "grafana"},
                "port": {"targetPort": "http"},
                "tls": {"termination": "edge"},
            },
        ),
    ]


def _deployment(name: str, image: str, command: List[str]) -> dict:
    volumes: List[Dict[str, Any]] = []
    mounts: List[Dict[str, Any]] = []
    if name == "prometheus":
        volumes = [
            {"name": "config", "configMap": {"name": "prometheus-config"}},
            {"name": "data", "persistentVolumeClaim": {"claimName": "prometheus-data"}},
        ]
        mounts = [
            {"name": "config", "mountPath": "/etc/prometheus"},
            {"name": "data", "mountPath": "/prometheus"},
        ]
    elif name == "json-exporter":
        volumes = [
            {"name": "config", "configMap": {"name": "json-exporter-config"}},
            {
                "name": "password",
                "secret": {
                    "secretName": "aap-gateway-credentials",  # pragma: allowlist secret
                    "items": [{"key": "password", "path": "aap-password"}],
                },
            },
        ]
        mounts = [
            {"name": "config", "mountPath": "/etc/json-exporter"},
            {"name": "password", "mountPath": "/etc/aap-monitoring", "readOnly": True},
        ]
    else:
        volumes = [
            {"name": "dashboard", "configMap": {"name": "grafana-dashboard"}},
            {"name": "provisioning", "configMap": {"name": "grafana-provisioning"}},
            {  # pragma: allowlist secret
                "name": "credentials",
                "secret": {"secretName": "grafana-admin"},  # pragma: allowlist secret
            },
        ]
        mounts = [
            {
                "name": "dashboard",
                "mountPath": "/var/lib/grafana/dashboards/aap-overview.json",
                "subPath": "aap-overview.json",
            },
            {
                "name": "provisioning",
                "mountPath": "/etc/grafana/provisioning/datasources/datasources.yaml",
                "subPath": "datasources.yaml",
            },
            {
                "name": "provisioning",
                "mountPath": "/etc/grafana/provisioning/dashboards/dashboards.yaml",
                "subPath": "dashboards.yaml",
            },
        ]
    env = []
    if name == "grafana":
        env = [
            {
                "name": "GF_SECURITY_ADMIN_USER",
                "valueFrom": {"secretKeyRef": {"name": "grafana-admin", "key": "admin-user"}},
            },
            {
                "name": "GF_SECURITY_ADMIN_PASSWORD",
                "valueFrom": {"secretKeyRef": {"name": "grafana-admin", "key": "admin-password"}},
            },
        ]
    container = {
        "name": name,
        "image": image,
        "args": command,
        "ports": [
            {
                "name": "http",
                "containerPort": {"prometheus": 9090, "json-exporter": 7979, "grafana": 3000}[name],
            }
        ],
        "resources": {
            "requests": {"cpu": "50m", "memory": "128Mi"},
            "limits": {"cpu": "500m", "memory": "512Mi"},
        },
        "volumeMounts": mounts,
        "env": env,
    }
    return _doc(
        "Deployment",
        name,
        apiVersion="apps/v1",
        labels=_labels(name),
        spec={
            "replicas": 1,
            "selector": {"matchLabels": _labels(name)},
            "template": {
                "metadata": {"labels": _labels(name)},
                "spec": {
                    "automountServiceAccountToken": False,
                    "containers": [container],
                    "volumes": volumes,
                },
            },
        },
    )


def _wait_for_readiness(ctx: AppContext) -> None:
    for name in ("prometheus", "json-exporter", "grafana"):
        result = kubectl.run(
            ctx.runner,
            "wait",
            f"deployment/{name}",
            "--for=condition=Available",
            "--timeout=180s",
            "-n",
            NAMESPACE,
        )
        if result.ok:
            continue
        diagnostics = kubectl.run(ctx.runner, "get", "pods", "-n", NAMESPACE, "-o", "wide")
        detail = diagnostics.stdout or diagnostics.stderr or ""
        raise AddonError(
            f"monitoring deployment {name!r} did not become ready",
            hint=detail.strip() or (result.stderr or result.stdout or "").strip() or None,
        )


class MonitoringAddon:
    name = NAME
    kind: AddonKind = "native"
    public = True
    needs_cluster = True

    def enable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        actions = list(getattr(args, "addon_args", None) or [])
        if actions and actions[0] == "populate":
            raise AddonError(
                "monitoring populate is not available until the Gateway data contract is validated"
            )
        if actions:
            raise AddonError(f"unsupported monitoring action: {actions[0]}")
        state_dir = ctx.paths.addon_dir(NAME)
        state_dir.mkdir(parents=True, exist_ok=True)
        password_path = state_dir / STATE_PASSWORD
        password = (
            password_path.read_text(encoding="utf-8").strip()
            if password_path.exists()
            else secrets.token_urlsafe(24)
        )
        if not password_path.exists():
            password_path.write_text(password + "\n", encoding="utf-8")
            password_path.chmod(0o600)
        aap_password = _aap_password(ctx)
        kube.apply_or_raise(
            ctx,
            _manifest(_documents(password, aap_password, ctx.namespace)),
            message="could not install monitoring addon",
        )
        _wait_for_readiness(ctx)
        names = enabled_names(ctx)
        if NAME not in names:
            names.append(NAME)
        set_enabled_names(ctx, names, save=True)
        _say(ctx, "Monitoring enabled", namespace=NAMESPACE)
        return 0

    def disable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        del args
        namespace = kube.read_object(ctx, "namespace", NAMESPACE)
        if namespace is not None:
            labels = namespace.get("metadata", {}).get("labels", {})
            if labels.get("app.kubernetes.io/managed-by") != "aap-demo-monitoring":
                raise AddonError(
                    f"refusing to delete unowned namespace {NAMESPACE!r}",
                    hint="The namespace is not labeled as managed by the monitoring addon.",
                )
        result = kubectl.delete(ctx.runner, "namespace", NAMESPACE, "--ignore-not-found")
        if not result.ok:
            raise AddonError(
                "could not remove monitoring addon",
                hint=(result.stderr or result.stdout or "").strip(),
            )
        set_enabled_names(ctx, [name for name in enabled_names(ctx) if name != NAME], save=True)
        state_dir = ctx.paths.addon_dir(NAME)
        if state_dir.exists():
            for child in state_dir.iterdir():
                if child.is_file():
                    child.unlink()
            state_dir.rmdir()
        _say(ctx, "Monitoring disabled", namespace=NAMESPACE)
        return 0

    def status(self, ctx: AppContext, args: argparse.Namespace) -> int:
        del args
        namespace = kube.read_object(ctx, "namespace", NAMESPACE)
        deployment_states = {}
        if namespace:
            for name in ("prometheus", "json-exporter", "grafana"):
                deployment = kube.read_object(ctx, "deployment", name, namespace=NAMESPACE)
                status = deployment.get("status", {}) if deployment else {}
                deployment_states[name] = bool(status.get("availableReplicas", 0) >= 1)
        ready = bool(namespace) and all(deployment_states.values())
        route = kubectl.jsonpath(
            ctx.runner, "route", "grafana", "-n", NAMESPACE, path="{.spec.host}"
        )
        _say(
            ctx,
            "Monitoring status",
            namespace=NAMESPACE,
            readiness="ready" if ready else "not-ready",
            grafana_route=route or None,
            prometheus_endpoint=f"http://prometheus.{NAMESPACE}.svc.cluster.local:9090",
            credential_file=str(ctx.paths.addon_dir(NAME) / STATE_PASSWORD),
        )
        return 0 if ready else 1


def _say(ctx: AppContext, message: str, **fields: object) -> None:
    if ctx.output in ("json", "yaml"):
        from aap_demo.core.output import render

        render(ctx.console, {"message": message, **fields}, output=ctx.output)
    else:
        ctx.console.out(message)
        for key, value in fields.items():
            if value:
                ctx.console.out(f"{key}: {value}")


def _aap_password(ctx: AppContext) -> str:
    """Copy the existing AAP password into the addon namespace Secret."""
    result = ctx.runner.run(
        [
            "kubectl",
            "get",
            "secret",
            "aap-admin-password",
            "-n",
            ctx.namespace,
            "-o",
            "json",
        ]
    )
    if not result.ok:
        raise AddonError(
            "could not read the AAP admin password Secret",
            hint=(result.stderr or result.stdout or "").strip() or None,
        )
    try:
        document = json.loads(result.stdout or "{}")
        encoded = document["data"]["password"]
        return base64.b64decode(encoded).decode("utf-8")
    except (KeyError, TypeError, ValueError, UnicodeDecodeError) as exc:
        raise AddonError("AAP admin password Secret has no usable password") from exc
