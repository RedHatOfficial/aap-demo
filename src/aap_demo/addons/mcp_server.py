"""Native V2 lifecycle for the AAP AnsibleMCPServer resource."""

from __future__ import annotations

import argparse
import base64
import json
import time

import yaml

from aap_demo.addons.base import AddonKind
from aap_demo.addons.common.state import enabled_names, set_enabled_names
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError
from aap_demo.core.output import is_structured, render


class McpServerAddon:
    name = "mcp-server"
    kind: AddonKind = "native"
    public = True
    needs_cluster = True

    def enable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        del args
        _cluster(ctx)
        aap_host = _route(ctx, "aap") or f"aap-{ctx.namespace}.apps.127.0.0.1.nip.io"
        domain = aap_host.split(".", 1)[1] if "." in aap_host else "apps.127.0.0.1.nip.io"
        mcp_host = f"aap-mcp-{ctx.namespace}.{domain}"
        public_base = _public_base(ctx, aap_host)
        manifest = _manifest(ctx.namespace, aap_host, mcp_host, public_base)
        result = ctx.runner.run(["kubectl", "apply", "-f", "-"], input=manifest)
        if not result.ok:
            raise AddonError(
                "could not apply MCP server resource", hint=result.stderr.strip() or None
            )
        for _ in range(18):
            if ctx.runner.run(
                ["kubectl", "get", "deployment", "aap-mcp-server", "-n", ctx.namespace]
            ).ok:
                break
            time.sleep(10)
        else:
            raise AddonError("MCP server deployment was not created by the operator")
        rollout = ctx.runner.run(
            [
                "kubectl",
                "rollout",
                "status",
                "deployment/aap-mcp-server",
                "-n",
                ctx.namespace,
                "--timeout=600s",
            ]
        )
        if not rollout.ok:
            raise AddonError(
                "MCP server rollout did not complete", hint=rollout.stderr.strip() or None
            )
        _apply_ingress_ca(ctx)
        _remember(ctx)
        _say(ctx, "MCP Server deployed", endpoint=f"https://{mcp_host}/mcp")
        return 0

    def disable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        del args
        for argv in (
            [
                "kubectl",
                "delete",
                "ansiblemcpserver",
                "aap-mcp-server",
                "-n",
                ctx.namespace,
                "--ignore-not-found",
            ],
            [
                "kubectl",
                "delete",
                "configmap",
                "aap-ingress-ca",
                "-n",
                ctx.namespace,
                "--ignore-not-found",
            ],
        ):
            result = ctx.runner.run(argv)
            if not result.ok:
                raise AddonError(
                    "could not remove MCP server resources", hint=result.stderr.strip() or None
                )
        _forget(ctx)
        _say(ctx, "MCP Server removed")
        return 0


def _cluster(ctx: AppContext) -> None:
    result = ctx.runner.run(["kubectl", "cluster-info"])
    if not result.ok:
        raise AddonError("kubectl is not connected to a cluster")


def _route(ctx: AppContext, name: str) -> str:
    result = ctx.runner.run(
        ["kubectl", "get", "route", name, "-n", ctx.namespace, "-o", "jsonpath={.spec.host}"]
    )
    return result.stdout.strip() if result.ok else ""


def _public_base(ctx: AppContext, aap_host: str) -> str:
    result = ctx.runner.run(
        [
            "kubectl",
            "get",
            "ingresses.config/cluster",
            "-o",
            "jsonpath={.spec.domain}",
            "--request-timeout=5s",
        ]
    )
    if not result.ok or not result.stdout.strip():
        return f"http://aap.{ctx.namespace}.svc.cluster.local"
    return f"https://{aap_host}"


def _manifest(namespace: str, aap_host: str, mcp_host: str, public_base: str) -> str:
    document = {
        "apiVersion": "mcpserver.ansible.com/v1alpha1",
        "kind": "AnsibleMCPServer",
        "metadata": {
            "name": "aap-mcp-server",
            "namespace": namespace,
            "labels": {
                "app.kubernetes.io/name": "aap-mcp-server",
                "app.kubernetes.io/part-of": "aap",
                "app.kubernetes.io/managed-by": "aap-operator",
            },
        },
        "spec": {
            "public_base_url": public_base,
            "allow_write_operations": True,
            "hostname": mcp_host,
            "ingress_type": "Route",
            "route_tls_termination_mechanism": "Edge",
            "route_host": mcp_host,
            "service_type": "ClusterIP",
            "api": {
                "replicas": 1,
                "resource_requirements": {
                    "requests": {"cpu": "500m", "memory": "512Mi"},
                    "limits": {"cpu": "1000m", "memory": "1Gi"},
                },
            },
            "image_pull_policy": "IfNotPresent",
            "image_pull_secrets": ["redhat-operators-pull-secret"],
            "no_log": True,
        },
    }
    return yaml.safe_dump(document, sort_keys=False)


def _apply_ingress_ca(ctx: AppContext) -> None:
    result = ctx.runner.run(
        [
            "kubectl",
            "get",
            "secret",
            "router-certs-default",
            "-n",
            "openshift-ingress",
            "-o",
            "json",
        ]
    )
    if not result.ok:
        raise AddonError(
            "could not read the ingress certificate", hint=result.stderr.strip() or None
        )
    try:
        encoded = (json.loads(result.stdout or "{}").get("data") or {}).get("tls.crt", "")
        chain = base64.b64decode(encoded).decode()
    except (ValueError, UnicodeError, json.JSONDecodeError) as exc:
        raise AddonError("could not decode the ingress certificate") from exc
    certs = chain.split("-----END CERTIFICATE-----")
    ca = next(
        (part + "-----END CERTIFICATE-----" for part in certs[1:] if "BEGIN CERTIFICATE" in part),
        chain,
    )
    manifest = yaml.safe_dump(
        {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {"name": "aap-ingress-ca", "namespace": ctx.namespace},
            "data": {"ca.crt": ca},
        },
        sort_keys=False,
    )
    applied = ctx.runner.run(["kubectl", "apply", "-f", "-"], input=manifest)
    if not applied.ok:
        raise AddonError(
            "could not apply the ingress CA ConfigMap", hint=applied.stderr.strip() or None
        )
    patch = json.dumps(
        [
            {
                "op": "add",
                "path": "/spec/template/spec/volumes/-",
                "value": {"name": "ingress-ca", "configMap": {"name": "aap-ingress-ca"}},
            },
            {
                "op": "add",
                "path": "/spec/template/spec/containers/0/volumeMounts/-",
                "value": {
                    "name": "ingress-ca",
                    "mountPath": "/etc/ssl/ingress-ca",
                    "readOnly": True,
                },
            },
            {
                "op": "add",
                "path": "/spec/template/spec/containers/0/env/-",
                "value": {"name": "NODE_EXTRA_CA_CERTS", "value": "/etc/ssl/ingress-ca/ca.crt"},
            },
        ]
    )
    patched = ctx.runner.run(
        [
            "kubectl",
            "patch",
            "deployment",
            "aap-mcp-server",
            "-n",
            ctx.namespace,
            "--type=json",
            "-p",
            patch,
        ]
    )
    if not patched.ok and "already exists" not in patched.stderr.lower():
        raise AddonError("could not configure MCP ingress CA", hint=patched.stderr.strip() or None)


def _remember(ctx: AppContext) -> None:
    names = enabled_names(ctx)
    if "mcp-server" not in names:
        names.append("mcp-server")
    set_enabled_names(ctx, names, save=True)


def _forget(ctx: AppContext) -> None:
    set_enabled_names(ctx, [name for name in enabled_names(ctx) if name != "mcp-server"], save=True)


def _say(ctx: AppContext, message: str, **fields: object) -> None:
    if is_structured(ctx.output):
        render(ctx.console, {"message": message, **fields}, output=ctx.output)
    else:
        ctx.console.out(message)
        for key, value in fields.items():
            ctx.console.out(f"  {key.replace('_', ' ').title()}: {value}")
