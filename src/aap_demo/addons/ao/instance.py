"""The AutomationOrchestrator instance and its access to local AAP. Ports addons/ao/deploy.sh."""

from __future__ import annotations

import json
import time
from typing import Callable, Dict, List, Optional, Tuple

from aap_demo.addons.ao import manifests
from aap_demo.addons.ao.olm import OPERATOR, PULL_SECRET, SUBSCRIPTION
from aap_demo.addons.ao.postgres import NAMESPACE
from aap_demo.addons.common.kube import as_dict, output_of
from aap_demo.cluster import coredns
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError, UsageError
from aap_demo.exec import kubectl

NAME = "automation-orchestrator"
SETTINGS = "automation-orchestrator-admin-settings"
NETWORK_POLICY = "automation-orchestrator-allow-aap"
DEFAULT_DOMAIN = "apps.127.0.0.1.nip.io"
OLLAMA_NAMESPACE = "aap-demo-ollama"
READY_TIMEOUT = 1200
READY_INTERVAL = 10
#: Workloads that call AAP and need the allow-list and hostAliases.
CALLERS = (
    "automation-orchestrator-backend",
    "automation-orchestrator-worker",
    "automation-orchestrator-background-worker",
)

Sleep = Callable[[float], None]
Clock = Callable[[], float]


def replica_count(ctx: AppContext) -> int:
    value = str(ctx.env.get("AO_LOW_RESOURCE", "") or "")
    if value in ("", "1", "true"):
        return 1
    if value in ("0", "false"):
        return 2
    raise UsageError("AO_LOW_RESOURCE must be unset, 0, false, 1, or true")


def cluster_domain(ctx: AppContext, aap_namespace: str) -> str:
    host = kubectl.jsonpath(ctx.runner, "route", "-n", aap_namespace, path="{.items[0].spec.host}")
    if "." in host:
        return host.split(".", 1)[1]
    return DEFAULT_DOMAIN


def ingress_host(ctx: AppContext, aap_namespace: str) -> str:
    return f"{NAME}.{cluster_domain(ctx, aap_namespace)}"


def apply(ctx: AppContext, *, host: str) -> None:
    ctx.console.info("Creating AutomationOrchestrator instance...")
    manifest = manifests.render(
        "automationorchestrator-cr.yaml",
        {
            "NAMESPACE": NAMESPACE,
            "INGRESS_HOST": host,
            "PULL_SECRET_NAME": str(ctx.env.get("AO_PULL_SECRET_NAME") or PULL_SECRET),
            "AO_REPLICA_COUNT": str(replica_count(ctx)),
        },
    )
    applied = kubectl.apply_stdin(ctx.runner, manifest)
    if not applied.ok:
        raise AddonError(
            "could not apply the AutomationOrchestrator CR", hint=output_of(applied) or None
        )


def _conditions(ctx: AppContext) -> Dict[str, Tuple[str, str]]:
    """Condition type -> (status, reason). Empty when the CR is missing."""
    result = kubectl.run(
        ctx.runner, "get", "automationorchestrator", NAME, "-n", NAMESPACE, "-o", "json"
    )
    if not result.ok:
        return {}
    try:
        status = as_dict(as_dict(json.loads(result.stdout or "{}")).get("status"))
    except json.JSONDecodeError:
        return {}
    out: Dict[str, Tuple[str, str]] = {}
    for condition in status.get("conditions") or []:
        condition = as_dict(condition)
        out[str(condition.get("type"))] = (
            str(condition.get("status") or ""),
            str(condition.get("reason") or ""),
        )
    return out


def route_host(ctx: AppContext) -> str:
    return kubectl.jsonpath(ctx.runner, "routes", "-n", NAMESPACE, path="{.items[0].spec.host}")


def _pods(ctx: AppContext) -> List[Tuple[str, str]]:
    """(name, STATUS column) for AO's pods."""
    listed = kubectl.run(ctx.runner, "get", "pods", "-n", NAMESPACE, "--no-headers")
    if not listed.ok:
        return []
    rows: List[Tuple[str, str]] = []
    for line in (listed.stdout or "").splitlines():
        fields = line.split()
        if len(fields) >= 3:
            rows.append((fields[0], fields[2]))
    return rows


def wait_ready(
    ctx: AppContext,
    *,
    timeout: int = READY_TIMEOUT,
    sleep: Sleep = time.sleep,
    clock: Clock = time.monotonic,
) -> None:
    """Ready, not Degraded, routed, and more than three pods running."""
    ctx.console.info("Waiting for Automation Orchestrator instance (may take 10+ minutes)...")
    started = clock()
    while True:
        conditions = _conditions(ctx)
        ready = conditions.get("Ready", ("", ""))[0]
        degraded, reason = conditions.get("Degraded", ("", ""))
        running = sum(
            1
            for name, status in _pods(ctx)
            if status == "Running" and not name.startswith("redhat-operators-")
        )
        if ready == "True" and degraded != "True" and route_host(ctx) and running > 3:
            ctx.console.success("Route ready")
            return
        elapsed = clock() - started
        ctx.console.progress(
            f"running={running} ready={ready or 'unknown'} degraded={reason or 'none'} "
            f"({int(elapsed)}s)"
        )
        if elapsed >= timeout:
            hint = f"Check: kubectl get automationorchestrator,pods,routes -n {NAMESPACE}"
            if reason:
                hint = f"Degraded reason: {reason}\n{hint}"
            raise AddonError(
                f"Automation Orchestrator was not Ready after {timeout // 60} minutes.", hint=hint
            )
        sleep(READY_INTERVAL)


def already_running(ctx: AppContext, *, channel: str) -> Optional[Tuple[int, int]]:
    """(running, total) when AO is healthy on ``channel``; None means install."""
    pods = [(name, status) for name, status in _pods(ctx) if status != "Completed"]
    running = sum(1 for _name, status in pods if status == "Running")
    if len(pods) <= 2 or running != len(pods):
        return None
    current = kubectl.jsonpath(
        ctx.runner, "subscription", SUBSCRIPTION, "-n", NAMESPACE, path="{.spec.channel}"
    )
    if current != channel:
        return None
    available = kubectl.run(
        ctx.runner,
        "wait",
        "--for=condition=Available",
        f"deployment/{OPERATOR}",
        "-n",
        NAMESPACE,
        "--timeout=5s",
    )
    if not available.ok:
        return None
    if kubectl.exists(ctx.runner, "automationorchestrator", NAME, "-n", NAMESPACE):
        degraded, reason = _conditions(ctx).get("Degraded", ("", ""))
        if degraded == "True":
            ctx.console.info(f"Instance is Degraded ({reason or 'unknown'}); continuing install...")
            return None
        if not route_host(ctx):
            ctx.console.info("Route not ready yet; continuing install...")
            return None
    return running, len(pods)


# -- local AAP access ------------------------------------------------------------


def aap_route_host(ctx: AppContext, aap_namespace: str) -> str:
    host = kubectl.jsonpath(ctx.runner, "route", "aap", "-n", aap_namespace, path="{.spec.host}")
    return host or kubectl.jsonpath(
        ctx.runner, "route", "-n", aap_namespace, path="{.items[0].spec.host}"
    )


def is_local_host(host: str) -> bool:
    return (
        host.endswith(".crc.testing")
        or host.endswith(".nip.io")
        or "127.0.0.1" in host
        or "localhost" in host
    )


def _route_hosts(ctx: AppContext, aap_namespace: str) -> List[str]:
    hosts = [
        kubectl.jsonpath(ctx.runner, "route", "aap", "-n", aap_namespace, path="{.spec.host}"),
        kubectl.jsonpath(ctx.runner, "route", NAME, "-n", NAMESPACE, path="{.spec.host}"),
    ]
    listed = kubectl.jsonpath(
        ctx.runner, "route", "-n", aap_namespace, path='{range .items[*]}{.spec.host}{"\\n"}{end}'
    )
    hosts.extend(h for h in listed.splitlines() if "mcp" in h)
    # Ollama too, so LLM calls survive the CoreDNS rewrite being wiped.
    hosts.append(
        kubectl.jsonpath(ctx.runner, "route", "ollama", "-n", OLLAMA_NAMESPACE, path="{.spec.host}")
    )
    unique: List[str] = []
    for host in (h.strip() for h in hosts):
        if host and host not in unique:
            unique.append(host)
    return unique


def pin_route_hosts(ctx: AppContext, aap_namespace: str) -> bool:
    """Pin AAP, AO and MCP route names to the ingress router in AO's callers.

    MicroShift's DNS operator can wipe the CoreDNS rewrite, and then AO's SSRF
    check rejects the AAP URL even though it is on the allow-list.
    """
    router_ip = kubectl.jsonpath(
        ctx.runner,
        "svc",
        "router-internal-default",
        "-n",
        "openshift-ingress",
        path="{.spec.clusterIP}",
    )
    if not router_ip:
        ctx.console.warn("Ingress router ClusterIP not found; skipping AO hostAliases")
        return False
    hosts = _route_hosts(ctx, aap_namespace)
    if not hosts:
        ctx.console.warn("No route hostnames for AO hostAliases")
        return False
    patch = json.dumps(
        {"spec": {"template": {"spec": {"hostAliases": [{"ip": router_ip, "hostnames": hosts}]}}}}
    )
    for deployment in CALLERS:
        document = kubectl.run(
            ctx.runner, "get", "deployment", deployment, "-n", NAMESPACE, "-o", "json"
        )
        if not document.ok:
            continue
        try:
            spec = as_dict(
                as_dict(as_dict(json.loads(document.stdout or "{}")).get("spec")).get("template")
            ).get("spec")
        except json.JSONDecodeError:
            spec = {}
        current = (as_dict(spec).get("hostAliases") or [{}])[0]
        if as_dict(current).get("ip") == router_ip and sorted(
            as_dict(current).get("hostnames") or []
        ) == sorted(hosts):
            continue
        kubectl.run(
            ctx.runner,
            "patch",
            "deployment",
            deployment,
            "-n",
            NAMESPACE,
            "--type=strategic",
            "-p",
            patch,
        )
        ctx.console.info(f"patched hostAliases on {deployment}")
    ctx.console.success(f"AO pods resolve route hosts via hostAliases ({router_ip})")
    return True


def configure_local_access(ctx: AppContext, aap_namespace: str) -> None:
    """Let AO call a local AAP: DNS, hostAliases and the SSRF allow-list."""
    host = aap_route_host(ctx, aap_namespace)
    if not host:
        ctx.console.warn(
            f"AAP gateway route not found in {aap_namespace}; skipping the AO SSRF allow-list. "
            "After AAP is up, run: aap-demo enable ao"
        )
        return
    if not is_local_host(host):
        ctx.console.success(f"AAP route {host} is not a local hostname; no SSRF allow-list needed")
        return
    ctx.console.info(f"Configuring AO to reach local AAP ({host})...")
    try:
        if coredns.needs_configuration(coredns.read_corefile(ctx)):
            ctx.console.info("CoreDNS is missing the rewrite for in-cluster route hostnames...")
            if not coredns.configure(ctx):
                ctx.console.warn("CoreDNS rewrite could not be applied. Run: aap-demo start")
    except Exception as exc:  # noqa: BLE001 - DNS repair is best effort, as in Bash
        ctx.console.warn(f"CoreDNS rewrite could not be applied ({exc}). Run: aap-demo start")
    pin_route_hosts(ctx, aap_namespace)

    hosts = json.dumps([host])
    before = kubectl.jsonpath(
        ctx.runner,
        "configmap",
        SETTINGS,
        "-n",
        NAMESPACE,
        path="{.data.APP_INTEGRATION_URL_ALLOWED_HOSTS}",
    )
    settings = json.dumps(
        {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": SETTINGS,
                "namespace": NAMESPACE,
                "labels": {
                    "app.kubernetes.io/managed-by": "aap-demo",
                    "app.kubernetes.io/part-of": NAME,
                },
            },
            "data": {
                "APP_INTEGRATION_URL_ALLOWED_HOSTS": hosts,
                "APP_WORKFLOW_HTTP_REQUEST_ALLOWED_HOSTS": hosts,
            },
        }
    )
    applied = kubectl.apply_stdin(ctx.runner, settings)
    if not applied.ok:
        raise AddonError(
            "could not write AO's allow-list settings", hint=output_of(applied) or None
        )
    changed = before != hosts
    if kubectl.exists(ctx.runner, "automationorchestrator", NAME, "-n", NAMESPACE):
        current = kubectl.jsonpath(
            ctx.runner,
            "automationorchestrator",
            NAME,
            "-n",
            NAMESPACE,
            path="{.spec.workflowHttpRequestAllowedHosts[0]}",
        )
        kubectl.run(
            ctx.runner,
            "patch",
            "automationorchestrator",
            NAME,
            "-n",
            NAMESPACE,
            "--type",
            "merge",
            "-p",
            json.dumps({"spec": {"workflowHttpRequestAllowedHosts": [host]}}),
        )
        changed = changed or current != host
    if changed:
        ctx.console.info("Restarting AO backend and workers to load the SSRF allow-list...")
        kubectl.run(
            ctx.runner,
            "rollout",
            "restart",
            *(f"deployment/{name}" for name in CALLERS),
            "-n",
            NAMESPACE,
        )
        for name in CALLERS:
            kubectl.run(
                ctx.runner,
                "rollout",
                "status",
                f"deployment/{name}",
                "-n",
                NAMESPACE,
                "--timeout=180s",
            )
    ctx.console.success(f"AO SSRF allow-list includes {host}")


def allow_aap_ingress(ctx: AppContext, aap_namespace: str) -> None:
    """AAP's namespace may reach AO's backend on 8000."""
    policy = json.dumps(
        {
            "apiVersion": "networking.k8s.io/v1",
            "kind": "NetworkPolicy",
            "metadata": {"name": NETWORK_POLICY, "namespace": NAMESPACE},
            "spec": {
                "podSelector": {
                    "matchLabels": {
                        "app.kubernetes.io/name": NAME,
                        "app.kubernetes.io/component": "backend",
                    }
                },
                "policyTypes": ["Ingress"],
                "ingress": [
                    {
                        "from": [
                            {
                                "namespaceSelector": {
                                    "matchLabels": {"kubernetes.io/metadata.name": aap_namespace}
                                }
                            }
                        ],
                        "ports": [{"protocol": "TCP", "port": 8000}],
                    }
                ],
            },
        }
    )
    applied = kubectl.apply_stdin(ctx.runner, policy)
    if not applied.ok:
        raise AddonError("could not let AAP reach AO's backend", hint=output_of(applied) or None)


def show_access(ctx: AppContext, *, password: Optional[str]) -> None:
    host = route_host(ctx)
    ctx.console.info(
        f"URL:      https://{host}" if host else f"URL:      kubectl get routes -n {NAMESPACE}"
    )
    ctx.console.info("Username: admin")
    if password and ctx.env.get("CI") != "true":
        ctx.console.info(f"Password: {password}")
    else:
        ctx.console.info(
            "Password: kubectl get secret automation-orchestrator-initial-admin-password "
            f"-n {NAMESPACE} -o jsonpath='{{.data.password}}' | base64 -d"
        )
    ctx.console.info(f"Status:   kubectl get pods -n {NAMESPACE}")


def remove_finalizers(ctx: AppContext) -> None:
    for kind in ("automationorchestrator", "automationorchestrators.aap.ansible.com"):
        listed = kubectl.run(ctx.runner, "get", kind, "-n", NAMESPACE, "-o", "name")
        for name in (listed.stdout or "").split() if listed.ok else []:
            kubectl.run(
                ctx.runner,
                "patch",
                name,
                "-n",
                NAMESPACE,
                "--type=json",
                "-p",
                '[{"op":"remove","path":"/metadata/finalizers"}]',
            )
