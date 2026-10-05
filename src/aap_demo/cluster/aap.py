"""The AnsibleAutomationPlatform CR: render, apply, patch, wait, tear down.

Ports ``create_aap_instance`` (aap-demo.sh:2424), ``_patch_gateway_capability``
(aap-demo.sh:2477) and ``_clean_operator``'s AAP half (aap-demo.sh:750-780).

**§14 R6 applies to :func:`render_cr`.** Bash injects ``route_host`` with an
awk line-insertion keyed on the literal text ``storage_type: file``:

    awk -v host=… '/storage_type: file/{print; print "    route_host: " host; next} {print}'

Two consequences of that being a *text* operation, both preserved here because
they are observable behavior, not bugs of the mechanism:

* the key lands at four spaces of indentation, i.e. as a sibling of
  ``storage_type`` under ``hub:`` — it is a hub setting, not a top-level one;
* a CR with no ``storage_type: file`` line gets **no** ``route_host`` at all.
  ``aap-controller.yaml`` disables hub entirely and is exactly that case, so
  the controller-only deploy legitimately renders an unmodified CR.

The rewrite reproduces the *effect* via YAML — set ``spec.hub.route_host``
when and only when ``spec.hub.storage_type == "file"`` — and the golden-file
tests in ``tests/unit/test_aap_render.py`` pin the parsed result against
bash's awk output for every CR in ``config/crs/``.
"""

from __future__ import annotations

import base64
import json
import time
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Optional

import yaml

from aap_demo import data
from aap_demo.core import waiting
from aap_demo.core.context import AppContext
from aap_demo.core.errors import UsageError

#: ``cr_name="${CR:-minimal}"`` (aap-demo.sh:2429).
DEFAULT_CR = "minimal"
CR_FILENAME = "aap-{name}.yaml"

#: ``_patch_gateway_capability`` polls 60 × 5s for the gateway Deployment.
GATEWAY_ATTEMPTS = 60
GATEWAY_INTERVAL = 5

#: ``watch_aap``'s budget (aap-demo.sh:2529).
WATCH_TIMEOUT = 3600
WATCH_INTERVAL = 10

#: ``watch_aap``'s secret-name fallbacks (aap-demo.sh:2601).
ADMIN_SECRET_FALLBACKS = (
    "aap-admin-password",
    "aap-controller-admin-password",
    "custom-admin-password",
)


def available_crs() -> List[str]:
    """The ``ls -1 config/crs/ | sed 's/aap-//; s/.yaml//'`` list, sorted."""
    return sorted(
        name[len("aap-") : -len(".yaml")]
        for name in data.names(data.CRS)
        if name.startswith("aap-")
    )


def load_cr(name: str) -> str:
    if name not in available_crs():
        raise UsageError(
            f"CR file not found: aap-{name}.yaml",
            hint="Available CRs: " + ", ".join(available_crs()),
        )
    return data.read(data.CRS, CR_FILENAME.format(name=name))


def cr_metadata_name(document: Dict[str, Any]) -> str:
    """Ports ``grep '^  name:' | head -1 | awk '{print $2}'`` with an ``aap`` default."""
    name = (document.get("metadata") or {}).get("name")
    return str(name) if name else "aap"


def route_host_for(namespace: str) -> str:
    """``aap-hub-<ns>.apps.127.0.0.1.nip.io`` (aap-demo.sh:2464)."""
    return f"aap-hub-{namespace}.apps.127.0.0.1.nip.io"


def render_cr(
    template: str,
    *,
    namespace: str,
    public_url: Optional[str] = None,
    noingress: bool = False,
) -> str:
    """Render one CR: the ``__PUBLIC_BASE_URL__`` path, or the ``route_host`` path."""
    if noingress:
        if not public_url:
            raise UsageError("PUBLIC_URL required for noingress CR")
        return template.replace("__PUBLIC_BASE_URL__", public_url)

    document = yaml.safe_load(template)
    hub = (document.get("spec") or {}).get("hub")
    if isinstance(hub, dict) and hub.get("storage_type") == "file":
        hub["route_host"] = route_host_for(namespace)
    return yaml.safe_dump(document, sort_keys=False, default_flow_style=False)


def public_url_for(ctx: AppContext) -> Optional[str]:
    """Ports the PUBLIC_URL auto-construction (aap-demo.sh:2441-2456).

    ``POD_NAME``/``POD_NAMESPACE``/``BASE_DOMAIN`` stay raw env vars rather
    than schema fields: they exist only for the one off-cluster deployment
    shape the noingress CR serves, and §3.2's env list keeps them working.
    """
    configured = str(ctx.config.get("deploy.public_url", "") or "")
    if configured:
        return configured
    pod_name = ctx.env.get("POD_NAME")
    pod_namespace = ctx.env.get("POD_NAMESPACE")
    base_domain = ctx.env.get("BASE_DOMAIN")
    if pod_name and pod_namespace and base_domain:
        return f"https://aap-{pod_name}-{pod_namespace}.{base_domain}"
    return None


# ---------------------------------------------------------------------------
# Cluster interaction
# ---------------------------------------------------------------------------


def instance_name(ctx: AppContext, namespace: Optional[str] = None) -> str:
    from aap_demo.exec import kubectl

    return kubectl.jsonpath(
        ctx.runner, "aap", "-n", namespace or ctx.namespace, path="{.items[0].metadata.name}"
    )


def existing_instance(ctx: AppContext, namespace: Optional[str] = None) -> str:
    """Ports the ``AAP_EXISTS`` short-circuit probe in ``cmd_deploy`` (aap-demo.sh:2057)."""
    ns = namespace or ctx.namespace
    listing = ctx.runner.run(["kubectl", "get", "aap", "-n", ns])
    if not listing.ok:
        return ""
    for line in listing.stdout.splitlines():
        if line.startswith("NAME") or not line.strip():
            continue
        return line.split()[0]
    return ""


def create_instance(
    ctx: AppContext,
    *,
    cr_name: Optional[str] = None,
    namespace: Optional[str] = None,
    sleep: Callable[[float], None] = time.sleep,
) -> str:
    """Ports ``create_aap_instance``. Returns the CR's ``metadata.name``."""
    from aap_demo.cluster import storage
    from aap_demo.exec import kubectl

    ns = namespace or ctx.namespace
    name = cr_name or str(ctx.config.get("deploy.cr", "") or DEFAULT_CR) or DEFAULT_CR

    ctx.console.progress("Creating AAP instance")

    template = load_cr(name)
    aap_name = cr_metadata_name(yaml.safe_load(template))
    storage.ensure_aap_pvcs(ctx, aap_name=aap_name, namespace=ns)

    noingress = "noingress" in name
    public_url = public_url_for(ctx) if noingress else None
    if noingress and not public_url:
        raise UsageError(
            "PUBLIC_URL required for noingress CR",
            hint=(
                "Full URL:      aap-demo deploy --cr "
                + name
                + " --public-url https://aap.apps.example.com\n"
                "  Components:    aap-demo deploy --cr "
                + name
                + " --set POD_NAME=… --set POD_NAMESPACE=… --set BASE_DOMAIN=…"
            ),
        )
    if noingress:
        ctx.console.progress(f"Using CR: {name} with PUBLIC_URL={public_url}")
    else:
        ctx.console.progress(f"Using CR: {name}")

    manifest = render_cr(template, namespace=ns, public_url=public_url, noingress=noingress)
    kubectl.apply_stdin(ctx.runner, manifest, "-n", ns).check()

    from aap_demo.cluster import pull_secret as pull_secret_mod

    pull_secret_mod.attach_to_workload(ctx, ns, aap_name)

    patch_gateway_capability(ctx, namespace=ns, sleep=sleep)
    return aap_name


def patch_gateway_capability(
    ctx: AppContext,
    *,
    namespace: Optional[str] = None,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> bool:
    """Ports ``_patch_gateway_capability`` (aap-demo.sh:2477).

    The gateway binds a privileged port, so its ``api`` container needs
    NET_BIND_SERVICE. On full OpenShift the privileged SCC grants every
    capability; on MicroShift the SCC admission controller picks
    ``restricted-v2``, which does not include it, and the pod crash-loops on
    EACCES. Replicas are forced to 1 *before* the capability patch, because
    two replicas racing the same schema migration is a separate, worse failure.
    """
    from aap_demo.exec import kubectl

    ns = namespace or ctx.namespace
    aap_name = instance_name(ctx, ns)
    if not aap_name:
        return False
    deploy_name = f"{aap_name}-gateway"

    ctx.console.progress("Waiting for gateway deployment")

    appeared = waiting.wait_for(
        lambda _n: kubectl.exists(ctx.runner, "deployment", deploy_name, "-n", ns),
        timeout=GATEWAY_ATTEMPTS * GATEWAY_INTERVAL,
        interval=GATEWAY_INTERVAL,
        description="gateway deployment",
        sleep=sleep,
        clock=clock,
    )
    if not appeared.ok:
        ctx.console.out(
            "  ⚠ Gateway deployment not found after 5 minutes — skipping capability patch"
        )
        return False

    replicas = kubectl.jsonpath(
        ctx.runner, "deployment", deploy_name, "-n", ns, path="{.spec.replicas}"
    )
    if replicas != "1":
        ctx.console.progress("Setting gateway replicas to 1")
        if ctx.runner.run(
            [
                "kubectl",
                "patch",
                "deployment",
                deploy_name,
                "-n",
                ns,
                "--type=merge",
                "-p",
                '{"spec":{"replicas":1}}',
            ]
        ).ok:
            ctx.console.progress("Gateway replicas set to 1")
        else:
            ctx.console.out("  ⚠ Gateway replica patch failed — migration race may occur")

    existing_caps = kubectl.jsonpath(
        ctx.runner,
        "deployment",
        deploy_name,
        "-n",
        ns,
        path='{.spec.template.spec.containers[?(@.name=="api")].securityContext.capabilities.add}',
    )
    if "NET_BIND_SERVICE" in existing_caps:
        ctx.console.progress("Gateway already has NET_BIND_SERVICE")
        return True

    ctx.console.progress("Patching gateway with NET_BIND_SERVICE")
    patched = ctx.runner.run(
        [
            "kubectl",
            "patch",
            "deployment",
            deploy_name,
            "-n",
            ns,
            "--type=strategic",
            "-p",
            '{"spec":{"template":{"spec":{"containers":[{"name":"api",'
            '"securityContext":{"capabilities":{"add":["NET_BIND_SERVICE"]}}}]}}}}',
        ]
    )
    if patched.ok:
        ctx.console.progress("Gateway patched — pod will restart with NET_BIND_SERVICE")
        return True
    ctx.console.out("  ⚠ Gateway patch failed — may need manual fix if gateway crashes")
    return False


# ---------------------------------------------------------------------------
# Readiness
# ---------------------------------------------------------------------------


@dataclass
class AapReadiness:
    ready: bool
    elapsed: float
    route: str = ""
    username: str = "admin"
    password: str = ""
    csv: str = ""
    version: str = ""


def installed_version(ctx: AppContext, namespace: str, *, csv: str = "") -> str:
    """AAP release from the custom resource, then from the operator CSV."""
    from aap_demo.exec import kubectl

    reported = kubectl.jsonpath(
        ctx.runner, "aap", "-n", namespace, path="{.items[0].status.version}"
    )
    if reported:
        return reported
    name = csv or kubectl.jsonpath(
        ctx.runner, "csv", "-n", namespace, path="{.items[0].metadata.name}"
    )
    if not name:
        return ""
    spec = kubectl.jsonpath(ctx.runner, "csv", name, "-n", namespace, path="{.spec.version}")
    if spec and all(part.isdigit() for part in spec.split(".")):
        return spec
    marker = ".v"
    if marker not in name:
        return ""
    rest = name.split(marker, 1)[1]
    return rest.split("-", 1)[0]


def successful_condition(ctx: AppContext, namespace: str) -> str:
    from aap_demo.exec import kubectl

    return kubectl.jsonpath(
        ctx.runner,
        "aap",
        "-n",
        namespace,
        path='{.items[0].status.conditions[?(@.type=="Successful")].status}',
    )


def read_conditions(ctx: AppContext, namespace: str) -> List[Dict[str, Any]]:
    """The AAP custom resource ``status.conditions`` array, newest last."""
    from aap_demo.exec import kubectl

    raw = kubectl.jsonpath(ctx.runner, "aap", "-n", namespace, path="{.items[0].status.conditions}")
    if not raw:
        return []
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if not isinstance(parsed, list):
        return []
    return [item for item in parsed if isinstance(item, dict)]


def _newest_condition(conditions: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    if not conditions:
        return None
    return max(conditions, key=lambda item: str(item.get("lastTransitionTime") or ""))


def condition_message(conditions: List[Dict[str, Any]]) -> str:
    """The newest condition's message, then its reason."""
    chosen = _newest_condition(conditions)
    if not chosen:
        return ""
    message = str(chosen.get("message") or "").strip()
    reason = str(chosen.get("reason") or "").strip()
    return message or reason


def condition_line(conditions: List[Dict[str, Any]]) -> str:
    """One nested-line summary of the condition that changed most recently."""
    chosen = _newest_condition(conditions)
    if not chosen:
        return ""
    kind = str(chosen.get("type") or "").strip() or "AAP"
    detail = condition_message(conditions)
    if detail and detail.lower() != kind.lower():
        return f"{kind}: {detail}"
    return kind


def deployment_line(table: str) -> str:
    """Not-ready workloads from ``kubectl get deploy --no-headers``.

    A ready count of ``1/1`` is omitted. Names drop a leading ``aap-`` so the
    nested line stays on the workload: ``controller 0/1, gateway 0/1``.
    """
    pending: List[str] = []
    ready_n = 0
    total = 0
    for raw in table.splitlines():
        parts = raw.split()
        if len(parts) < 2 or "/" not in parts[1]:
            continue
        name, counts = parts[0], parts[1]
        have, _, want = counts.partition("/")
        total += 1
        if want != "0" and have == want:
            ready_n += 1
            continue
        short = name[4:] if name.startswith("aap-") else name
        pending.append(f"{short} {counts}")
    if total == 0:
        return ""
    if not pending:
        return f"{ready_n}/{total} deployments ready"
    shown = pending[:3]
    if len(pending) > 3:
        shown.append(f"+{len(pending) - 3}")
    return ", ".join(shown)


def wait_status(deployments: str, message: str) -> str:
    """``Status: <message> (<deployments>)`` for the nested wait line."""
    status = message or "Waiting for AAP status"
    if deployments:
        return f"Status: {status} ({deployments})"
    return f"Status: {status}"


def deployment_status(ctx: AppContext, namespace: str) -> str:
    result = ctx.runner.run(["kubectl", "get", "deploy", "-n", namespace, "--no-headers"])
    if not result.ok:
        return ""
    return deployment_line(result.stdout or "")


def admin_password(ctx: AppContext, namespace: str) -> str:
    """Ports ``watch_aap``'s adminPasswordSecret lookup plus its name fallbacks."""
    from aap_demo.exec import kubectl

    names = []
    referenced = kubectl.jsonpath(
        ctx.runner, "aap", "-n", namespace, path="{.items[0].status.adminPasswordSecret}"
    )
    if referenced:
        names.append(referenced)
    aap_name = instance_name(ctx, namespace)
    if aap_name:
        names.append(f"{aap_name}-admin-password")
    names.extend(ADMIN_SECRET_FALLBACKS)
    password = _password_from_secrets(ctx, namespace, names)
    if password:
        return password
    listing = ctx.runner.run(["kubectl", "get", "secrets", "-n", namespace, "-o", "name"])
    if not listing.ok:
        return ""
    extra = []
    for line in listing.stdout.splitlines():
        secret_name = line.strip().removeprefix("secret/")
        if secret_name.endswith("-admin-password") and secret_name not in names:
            extra.append(secret_name)
    return _password_from_secrets(ctx, namespace, extra)


def _password_from_secrets(ctx: AppContext, namespace: str, names: List[str]) -> str:
    from aap_demo.exec import kubectl

    seen = set()
    for name in names:
        if not name or name in seen:
            continue
        seen.add(name)
        raw = kubectl.jsonpath(ctx.runner, "secret", name, "-n", namespace, path="{.data.password}")
        if not raw:
            continue
        try:
            return base64.b64decode(raw).decode("utf-8").strip()
        except (ValueError, UnicodeDecodeError):
            continue
    return ""


def wait_ready(
    ctx: AppContext,
    *,
    namespace: Optional[str] = None,
    timeout: float = WATCH_TIMEOUT,
    interval: float = WATCH_INTERVAL,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> AapReadiness:
    """The non-interactive half of ``watch_aap`` (aap-demo.sh:2521-2609).

    ``watch_aap`` is two things at once: a full-screen, ``clear``-ing status
    dashboard, and the deploy path's terminal wait for
    ``conditions[type=Successful].status == "True"``. Only the second belongs
    to phase 3; the dashboard is ``aap-demo watch``, which §12.4 puts in
    phase 2. The success criterion, the 60-minute budget, the 10-second
    interval, and the credential lookup are the same.
    """
    from aap_demo.cluster import pull_secret as pull_secret_mod
    from aap_demo.exec import kubectl

    ns = namespace or ctx.namespace

    def reconcile_pull_secret() -> None:
        if pull_secret_mod.discover(ctx) is None:
            return
        pull_secret_mod.reconcile(ctx, ns, instance_name(ctx, ns) or "aap")

    reconcile_pull_secret()

    def attempt(_n: int) -> bool:
        return successful_condition(ctx, ns) == "True"

    def progress(n: int, elapsed: float, _value: Any) -> None:
        reconcile_pull_secret()
        detail = wait_status(
            deployment_status(ctx, ns),
            condition_message(read_conditions(ctx, ns)),
        )
        ctx.events.progress(detail)
        del n, elapsed

    result = waiting.wait_for(
        attempt,
        timeout=timeout,
        interval=interval,
        description="AAP Successful condition",
        on_attempt=progress,
        sleep=sleep,
        clock=clock,
    )
    route = kubectl.jsonpath(ctx.runner, "route", "-n", ns, path="{.items[0].spec.host}")
    csv = kubectl.jsonpath(ctx.runner, "csv", "-n", ns, path="{.items[0].metadata.name}")
    version = installed_version(ctx, ns, csv=csv)
    return AapReadiness(
        ready=result.ok,
        elapsed=result.elapsed,
        route=route,
        password=admin_password(ctx, ns),
        csv=csv,
        version=version,
    )


# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

OPERATOR_PACKAGE = "ansible-automation-platform-operator"


def teardown(
    ctx: AppContext,
    *,
    namespace: Optional[str] = None,
    which: Optional[Callable[[str], Optional[str]]] = None,
    sleep: Callable[[float], None] = time.sleep,
) -> bool:
    """Ports ``_clean_operator``'s deletion half (aap-demo.sh:750-784).

    The owner-reference strip is load-bearing, not tidiness: the AAP CR's
    children carry ``blockOwnerDeletion: true``, so deleting the namespace
    without first setting ``remove_owner_references_from_children`` deadlocks
    namespace termination. Bash waits 3 seconds for the operator to reconcile
    that patch before deleting the CR, and so does this.
    """
    import shutil

    from aap_demo.exec import kubectl
    from aap_demo.exec import operator_sdk as sdk_mod

    resolve = which if which is not None else shutil.which
    ns = namespace or ctx.namespace

    if not kubectl.exists(ctx.runner, "namespace", ns):
        ctx.console.out(f"Namespace {ns} not found - nothing to clean")
        return False

    if resolve("operator-sdk") is not None:
        ctx.console.step("Cleaning up OLM")
        ctx.console.progress("Cleaning up OLM resources")
        sdk_mod.cleanup(ctx, OPERATOR_PACKAGE, ns)
        # `operator-sdk cleanup` scales OLM's own deployments down on some
        # versions; bash scales them straight back up (aap-demo.sh:758).
        ctx.runner.run(
            [
                "kubectl",
                "scale",
                "deploy",
                "catalog-operator",
                "olm-operator",
                "-n",
                "olm",
                "--replicas=1",
            ]
        )
        ctx.console.checkpoint("OLM resources cleaned up")

    listing = ctx.runner.run(["kubectl", "get", "aap", "-n", ns, "--no-headers", "-o", "name"])
    started_delete = False
    for line in (listing.stdout or "").splitlines():
        resource = line.strip()
        if not resource:
            continue
        if not started_delete:
            ctx.console.step("Deleting the AAP instance")
            started_delete = True
        ctx.console.progress("Removing owner references from children")
        ctx.runner.run(
            [
                "kubectl",
                "patch",
                resource,
                "-n",
                ns,
                "--type",
                "merge",
                "-p",
                '{"spec":{"remove_owner_references_from_children": true}}',
            ]
        )
        sleep(3)
        ctx.console.progress(f"Deleting {resource}")
        kubectl.delete(ctx.runner, resource, "-n", ns, timeout="30s")
    if started_delete:
        ctx.console.checkpoint("AAP instance deleted")

    ctx.console.step("Deleting the namespace")
    ctx.console.progress(f"Deleting namespace {ns}")
    kubectl.delete(ctx.runner, "namespace", ns, timeout="60s")
    ctx.console.checkpoint(f"Namespace {ns} deleted")
    return True


__all__ = [
    "ADMIN_SECRET_FALLBACKS",
    "AapReadiness",
    "DEFAULT_CR",
    "admin_password",
    "available_crs",
    "cr_metadata_name",
    "create_instance",
    "existing_instance",
    "instance_name",
    "load_cr",
    "patch_gateway_capability",
    "render_cr",
    "route_host_for",
    "successful_condition",
    "teardown",
    "wait_ready",
]
