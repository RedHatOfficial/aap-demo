"""Native V2 lifecycle for the AAP AnsibleMCPServer resource."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import time
from pathlib import Path

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
        token = _generate_token(ctx, aap_host)
        if token:
            _configure_claude(ctx, mcp_host, token)
        _remember(ctx)
        _say(ctx, "MCP Server deployed", endpoint=f"https://{mcp_host}/mcp")
        return 0

    def disable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        del args
        result = ctx.runner.run(
            [
                "kubectl",
                "delete",
                "ansiblemcpserver",
                "aap-mcp-server",
                "-n",
                ctx.namespace,
                "--ignore-not-found",
            ]
        )
        if not result.ok:
            raise AddonError(
                "could not remove MCP server resources", hint=result.stderr.strip() or None
            )
        owned = ctx.runner.run(
            ["kubectl", "get", "configmap", "aap-ingress-ca", "-n", ctx.namespace, "-o", "json"]
        )
        if owned.ok and _owned_configmap(owned.stdout):
            result = ctx.runner.run(
                [
                    "kubectl",
                    "delete",
                    "configmap",
                    "aap-ingress-ca",
                    "-n",
                    ctx.namespace,
                    "--ignore-not-found",
                ]
            )
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
    except (ValueError, UnicodeError, json.JSONDecodeError, binascii.Error) as exc:
        raise AddonError("could not decode the ingress certificate") from exc
    if "-----BEGIN CERTIFICATE-----" not in chain:
        raise AddonError("could not decode the ingress certificate")
    certs = chain.split("-----END CERTIFICATE-----")
    ca = next(
        (part + "-----END CERTIFICATE-----" for part in certs[1:] if "BEGIN CERTIFICATE" in part),
        chain,
    )
    manifest = yaml.safe_dump(
        {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": "aap-ingress-ca",
                "namespace": ctx.namespace,
                "labels": {
                    "app.kubernetes.io/managed-by": "aap-demo",
                    "app.kubernetes.io/name": "mcp-server",
                },
            },
            "data": {"ca.crt": ca},
        },
        sort_keys=False,
    )
    applied = ctx.runner.run(["kubectl", "apply", "-f", "-"], input=manifest)
    if not applied.ok:
        raise AddonError(
            "could not apply the ingress CA ConfigMap", hint=applied.stderr.strip() or None
        )
    deployment = ctx.runner.run(
        ["kubectl", "get", "deployment", "aap-mcp-server", "-n", ctx.namespace, "-o", "json"]
    )
    if not deployment.ok:
        raise AddonError(
            "could not inspect MCP server deployment", hint=deployment.stderr.strip() or None
        )
    try:
        pod_spec = json.loads(deployment.stdout)["spec"]["template"]["spec"]
    except (KeyError, TypeError, json.JSONDecodeError) as exc:
        raise AddonError("could not inspect MCP server deployment") from exc
    operations = []
    if not any(item.get("name") == "ingress-ca" for item in pod_spec.get("volumes", [])):
        operations.append(
            {
                "op": "add",
                "path": "/spec/template/spec/volumes/-",
                "value": {"name": "ingress-ca", "configMap": {"name": "aap-ingress-ca"}},
            }
        )
    container = (pod_spec.get("containers") or [{}])[0]
    if not any(item.get("name") == "ingress-ca" for item in container.get("volumeMounts", [])):
        operations.append(
            {
                "op": "add",
                "path": "/spec/template/spec/containers/0/volumeMounts/-",
                "value": {
                    "name": "ingress-ca",
                    "mountPath": "/etc/ssl/ingress-ca",
                    "readOnly": True,
                },
            }
        )
    if not any(item.get("name") == "NODE_EXTRA_CA_CERTS" for item in container.get("env", [])):
        operations.append(
            {
                "op": "add",
                "path": "/spec/template/spec/containers/0/env/-",
                "value": {"name": "NODE_EXTRA_CA_CERTS", "value": "/etc/ssl/ingress-ca/ca.crt"},
            }
        )
    if operations:
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
                json.dumps(operations),
            ]
        )
        if not patched.ok:
            current = ctx.runner.run(
                [
                    "kubectl",
                    "get",
                    "deployment",
                    "aap-mcp-server",
                    "-n",
                    ctx.namespace,
                    "-o",
                    "json",
                ]
            )
            if not current.ok or not _deployment_has_ingress_ca(current.stdout):
                raise AddonError(
                    "could not configure MCP ingress CA", hint=patched.stderr.strip() or None
                )
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


def _owned_configmap(payload: str) -> bool:
    try:
        labels = json.loads(payload).get("metadata", {}).get("labels", {})
    except (TypeError, json.JSONDecodeError):
        return False
    return (
        labels.get("app.kubernetes.io/managed-by") == "aap-demo"
        and labels.get("app.kubernetes.io/name") == "mcp-server"
    )


def _deployment_has_ingress_ca(payload: str) -> bool:
    try:
        pod_spec = json.loads(payload)["spec"]["template"]["spec"]
        container = (pod_spec.get("containers") or [{}])[0]
    except (KeyError, TypeError, json.JSONDecodeError):
        return False
    return (
        any(item.get("name") == "ingress-ca" for item in pod_spec.get("volumes", []))
        and any(item.get("name") == "ingress-ca" for item in container.get("volumeMounts", []))
        and any(item.get("name") == "NODE_EXTRA_CA_CERTS" for item in container.get("env", []))
    )


def _generate_token(ctx: AppContext, aap_host: str) -> str | None:
    password = ctx.runner.run(
        [
            "kubectl",
            "get",
            "secret",
            "aap-admin-password",
            "-n",
            ctx.namespace,
            "-o",
            "jsonpath={.data.password}",
        ]
    )
    if not password.ok or not password.stdout.strip():
        return None
    try:
        admin_password = base64.b64decode(password.stdout.strip(), validate=True).decode()
    except (binascii.Error, UnicodeError):
        return None
    token_request = '{"description":"claude-mcp","scope":"write"}'
    curl_config = (
        f"url = {_curl_config_value(f'https://{aap_host}/api/gateway/v1/tokens/')}\n"
        f"user = {_curl_config_value(f'admin:{admin_password}')}\n"
        "request = POST\n"
        f"header = {_curl_config_value('Content-Type: application/json')}\n"
        f"data = {_curl_config_value(token_request)}\n"
        "insecure\n"
    )
    response = ctx.runner.run(
        [
            "curl",
            "--silent",
            "--show-error",
            "--fail",
            "--max-time",
            "30",
            "--config",
            "-",
        ],
        input=curl_config,
    )
    if not response.ok:
        return None
    try:
        token = json.loads(response.stdout).get("token")
    except (TypeError, json.JSONDecodeError):
        return None
    return token if isinstance(token, str) and token else None


def _curl_config_value(value: str) -> str:
    """Quote one value for curl's double-quoted config-file syntax."""
    return json.dumps(value)


def _configure_claude(ctx: AppContext, mcp_host: str, token: str) -> None:
    if not ctx.runner.run(["claude", "--version"]).ok:
        return
    ctx.runner.run(["claude", "mcp", "remove", "aap-demo", "--scope", "user"])
    env = None
    ca_path = ctx.paths.config_dir / "crc-ingress-ca.crt"
    if isinstance(ca_path, Path) and ca_path.exists():
        env = {"NODE_EXTRA_CA_CERTS": str(ca_path)}
    ctx.runner.run(
        [
            "claude",
            "mcp",
            "add",
            "aap-demo",
            f"https://{mcp_host}/mcp",
            "--transport",
            "http",
            "--scope",
            "user",
            "--header",
            f"Authorization: Bearer {token}",
        ],
        env=env,
    )


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
