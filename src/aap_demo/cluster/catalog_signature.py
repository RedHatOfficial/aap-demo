"""MicroShift 4.22+ signature policy relaxation and catalog-pull recovery.

Ports ``includes/olm-catalog-signature.sh`` in full. The problem it exists for:
MicroShift 4.22 and later enforce GPG signatures for images pulled from
``registry.redhat.io``, and ``redhat-operator-index`` fails that check, so the
catalog pod sits in ``SignatureValidationFailed`` forever. The fix is
demo-only and deliberately narrow — it marks *one* registry
``insecureAcceptAnything`` in the CRC VM's ``/etc/containers/policy.json`` and
reloads CRI-O — and it is gated on the cluster actually being 4.22+.

The wait loop is where §14 R5 bites hardest: bash's version can run ten
minutes and its caller reads a bare exit status. :func:`wait_for_catalog_ready`
returns a :class:`CatalogWait` naming *why* it stopped, so the deploy path can
print bash's specific message for each failure shape instead of a generic one.
"""

from __future__ import annotations

import re
import time
from dataclasses import dataclass
from typing import Any, Callable, List, Optional

from aap_demo.core import waiting
from aap_demo.core.context import AppContext
from aap_demo.exec import kubectl
from aap_demo.exec import ssh as ssh_mod
from aap_demo.infra import crc as infra_crc

CATALOG_NAME = "redhat-operators"
CATALOG_SELECTOR = "olm.catalogSource=redhat-operators"

#: ``grep -Eiq`` in ``catalog_pod_has_scc_admission_failure``.
_SCC_ADMISSION_RE = re.compile(
    r"security.?context.?constraint"
    r"|scc admission"
    r"|forbidden.*(runAsUser|serviceaccount)"
    r"|unable to validate against any.*constraint",
    re.IGNORECASE,
)
DEFAULT_OCP_VERSION = "4.20"

#: ``catalog_wait_timeout_seconds`` (includes/olm-catalog-signature.sh:213).
DEFAULT_CATALOG_TIMEOUT = 600
CATALOG_POLL_INTERVAL = 5
#: Bash sleeps 15s after a recovery restart before resuming the poll.
RECOVERY_SETTLE_SECONDS = 15

_VERSION_RE = re.compile(r"^(\d+\.\d+)")

#: The remote one-liner that rewrites policy.json. Byte-identical in effect to
#: the bash heredoc: it only writes when the entry is not already
#: ``insecureAcceptAnything``, and it prints CHANGED/UNCHANGED so the caller
#: knows whether CRI-O needs a reload.
_RELAX_SCRIPT = """
import json
p = "/etc/containers/policy.json"
with open(p) as f: d = json.load(f)
docker = d.setdefault("transports", {}).setdefault("docker", {})
reg = docker.get("registry.redhat.io", [])
if not reg or reg[0].get("type") != "insecureAcceptAnything":
    docker["registry.redhat.io"] = [{"type": "insecureAcceptAnything"}]
    with open(p, "w") as f: json.dump(d, f, indent=4)
    print("CHANGED")
else:
    print("UNCHANGED")
"""


def resolve_ocp_version(ctx: AppContext) -> str:
    """Ports ``resolve_aap_ocp_version`` — env, then ``crc status``, then the cluster."""
    explicit = ctx.env.get("AAP_OCP_VERSION")
    if explicit:
        return explicit
    crc_version = str(infra_crc.status_json(ctx.runner).get("openshiftVersion", "") or "")
    match = _VERSION_RE.match(crc_version)
    if match:
        return match.group(1)
    cluster_version = kubectl.jsonpath(
        ctx.runner, "clusterversion", "version", path="{.status.desired.version}"
    )
    match = _VERSION_RE.match(cluster_version)
    if match:
        return match.group(1)
    return DEFAULT_OCP_VERSION


def needs_relaxation(version: str) -> bool:
    """Ports ``needs_signature_policy_relaxation`` — true from 4.22 upward."""
    try:
        major_text, _, minor_text = version.partition(".")
        major, minor = int(major_text), int(minor_text.split(".")[0])
    except (TypeError, ValueError):
        return False
    if major < 4:
        return False
    if major == 4 and minor < 22:
        return False
    return True


def _reload_crio(ctx: AppContext, key: Any) -> None:
    result = ssh_mod.exec_remote(ctx.runner, key, "systemctl", "reload", "crio")
    if result.ok:
        ctx.console.progress("Reloaded CRI-O")
    else:
        ctx.console.warn("CRI-O reload failed — restart CRC if catalog pull still fails")


def relax_signature_policy(ctx: AppContext, *, force_crio_reload: bool = False) -> bool:
    """Ports ``maybe_relax_redhat_registry_signature_policy``."""
    if not needs_relaxation(resolve_ocp_version(ctx)):
        return True
    key = ssh_mod.detect_ssh_key(ssh_mod.crc_machines_dir(ctx.env))
    if key is None:
        ctx.console.warn("MicroShift 4.22+ blocks unsigned registry.redhat.io images.")
        ctx.console.err(
            "  Ensure CRC is running (crc start) and SSH key exists under ~/.crc/machines/crc/."
        )
        ctx.console.err("  Test: aap-demo ssh")
        return False

    result = ssh_mod.exec_remote(ctx.runner, key, "python3", "-c", _RELAX_SCRIPT)
    if not result.ok:
        ctx.console.warn(
            "Could not relax signature policy via SSH "
            f"(is CRC running? port {ssh_mod.CRC_SSH_PORT} open?)"
        )
        return False

    verdict = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
    if verdict == "CHANGED":
        ctx.console.progress("Relaxed container signature policy")
        _reload_crio(ctx, key)
        return True
    if verdict == "UNCHANGED":
        ctx.console.progress("Container signature policy already relaxed")
        if force_crio_reload:
            _reload_crio(ctx, key)
        return True
    ctx.console.warn("Unexpected signature policy response from CRC VM")
    return False


def ensure_policy(ctx: AppContext) -> bool:
    """Ports ``ensure_catalog_signature_policy``."""
    if not needs_relaxation(resolve_ocp_version(ctx)):
        return True
    ctx.console.out("  Ensuring MicroShift 4.22+ signature policy allows registry.redhat.io...")
    return relax_signature_policy(ctx)


# ---------------------------------------------------------------------------
# Catalog pod inspection
# ---------------------------------------------------------------------------


def selector_for(catalog_name: str = CATALOG_NAME) -> str:
    """``olm.catalogSource=<name>``. Defaults to the AAP catalog."""
    return f"olm.catalogSource={catalog_name}"


def _pods_jsonpath(
    ctx: AppContext,
    namespace: str,
    path: str,
    *,
    catalog_name: str = CATALOG_NAME,
) -> str:
    return kubectl.jsonpath(
        ctx.runner,
        "pods",
        "-n",
        namespace,
        "-l",
        selector_for(catalog_name),
        path=path,
    )


def catalog_pod_name(ctx: AppContext, namespace: str, *, catalog_name: str = CATALOG_NAME) -> str:
    return _pods_jsonpath(ctx, namespace, "{.items[0].metadata.name}", catalog_name=catalog_name)


def catalog_pod_phase(ctx: AppContext, namespace: str, *, catalog_name: str = CATALOG_NAME) -> str:
    return (
        _pods_jsonpath(ctx, namespace, "{.items[0].status.phase}", catalog_name=catalog_name)
        or "Pending"
    )


def container_waiting(ctx: AppContext, namespace: str, *, catalog_name: str = CATALOG_NAME) -> str:
    """Ports ``catalog_pod_container_waiting``."""
    return _pods_jsonpath(
        ctx,
        namespace,
        "{range .items[0].status.containerStatuses[*].state.waiting}"
        '{.reason}{": "}{.message}{"\\n"}{end}',
        catalog_name=catalog_name,
    )


def has_image_pull_backoff(
    ctx: AppContext, namespace: str, *, catalog_name: str = CATALOG_NAME
) -> bool:
    """Ports ``catalog_pod_has_image_pull_backoff``.

    The pod *phase* stays ``Pending`` while the container reports
    ImagePullBackOff, which is why the container's waiting reason has to be
    consulted separately.
    """
    phase = _pods_jsonpath(ctx, namespace, "{.items[0].status.phase}", catalog_name=catalog_name)
    if phase in ("ImagePullBackOff", "ErrImagePull"):
        return True
    waiting_text = container_waiting(ctx, namespace, catalog_name=catalog_name)
    return any(
        token in waiting_text
        for token in ("ImagePullBackOff", "ErrImagePull", "SignatureValidationFailed")
    )


def has_signature_failure(
    ctx: AppContext, namespace: str, *, catalog_name: str = CATALOG_NAME
) -> bool:
    """Ports ``catalog_pod_has_signature_pull_failure``."""
    pod = catalog_pod_name(ctx, namespace, catalog_name=catalog_name)
    if not pod:
        return False
    if "SignatureValidationFailed" in container_waiting(ctx, namespace, catalog_name=catalog_name):
        return True
    if not has_image_pull_backoff(ctx, namespace):
        return False
    events = ctx.runner.run(
        [
            "kubectl",
            "get",
            "events",
            "-n",
            namespace,
            "--field-selector",
            f"involvedObject.name={pod}",
        ]
    )
    return "SignatureValidationFailed" in (events.stdout or "")


def wait_reason(ctx: AppContext, namespace: str, *, catalog_name: str = CATALOG_NAME) -> List[str]:
    """Ports ``catalog_pod_wait_reason`` — the first three explanatory lines."""
    raw = _pods_jsonpath(
        ctx,
        namespace,
        '{range .items[0].status.conditions[?(@.type=="PodScheduled")]}'
        '{.reason}{": "}{.message}{"\\n"}{end}'
        "{range .items[0].status.containerStatuses[*].state.waiting}"
        '{.reason}{": "}{.message}{"\\n"}{end}',
        catalog_name=catalog_name,
    )
    return [line for line in raw.splitlines() if line.strip()][:3]


def _events_text(ctx: AppContext, namespace: str, pod: str) -> str:
    """Events for one pod, or the namespace when the pod has no name yet."""
    argv = ["kubectl", "get", "events", "-n", namespace]
    if pod:
        argv.extend(["--field-selector", f"involvedObject.name={pod}"])
    argv.append("--sort-by=.lastTimestamp")
    result = ctx.runner.run(argv)
    return result.stdout or ""


def has_scc_admission_failure(
    ctx: AppContext, namespace: str, *, catalog_name: str = CATALOG_NAME
) -> bool:
    """Ports ``catalog_pod_has_scc_admission_failure`` (upstream #150)."""
    pod = catalog_pod_name(ctx, namespace, catalog_name=catalog_name)
    detail = "\n".join(wait_reason(ctx, namespace, catalog_name=catalog_name))
    blob = f"{detail}\n{_events_text(ctx, namespace, pod)}"
    return _SCC_ADMISSION_RE.search(blob) is not None


def report_scc_failure(
    ctx: AppContext, namespace: str, *, catalog_name: str = CATALOG_NAME
) -> None:
    """Ports ``report_catalog_scc_failure``."""
    pod = catalog_pod_name(ctx, namespace, catalog_name=catalog_name)
    account = ""
    if pod:
        account = kubectl.jsonpath(
            ctx.runner,
            "pod",
            pod,
            "-n",
            namespace,
            path="{.spec.serviceAccountName}",
        )
    detail = wait_reason(ctx, namespace, catalog_name=catalog_name)
    fallback = ctx.env.get("AO_CATALOG_SERVICE_ACCOUNT") or CATALOG_NAME
    ctx.console.err("ERROR: CatalogSource pod was rejected by SCC admission.")
    ctx.console.err(f"  Namespace: {namespace}")
    ctx.console.err(f"  ServiceAccount: {account or 'unknown'}")
    if detail:
        ctx.console.err("  Pod detail:")
        for line in detail:
            ctx.console.err(f"    {line}")
    ctx.console.err("  Grant the required SCC to this ServiceAccount, then retry:")
    ctx.console.err(
        f"    oc adm policy add-scc-to-user anyuid -z {account or fallback} -n {namespace}"
    )


def is_pulling(catalog_state: str, pod_phase: str) -> bool:
    """Ports ``catalog_pod_is_pulling`` — governs which progress line prints."""
    if catalog_state not in ("TRANSIENT_FAILURE", "CONNECTING", "", "Pending"):
        return False
    return pod_phase in ("Pending", "ContainerCreating", "Running")


def catalog_state(ctx: AppContext, namespace: str, *, catalog_name: str = CATALOG_NAME) -> str:
    return kubectl.jsonpath(
        ctx.runner,
        "catalogsource",
        catalog_name,
        "-n",
        namespace,
        path="{.status.connectionState.lastObservedState}",
    )


def recover_catalog_pull(
    ctx: AppContext,
    namespace: str,
    *,
    fix_signature: bool = False,
    catalog_name: str = CATALOG_NAME,
) -> bool:
    """Ports ``maybe_recover_catalog_pull``."""
    if fix_signature and needs_relaxation(resolve_ocp_version(ctx)):
        ctx.console.out("  Applying MicroShift 4.22+ signature policy fix...")
        if not relax_signature_policy(ctx, force_crio_reload=True):
            return False
    ctx.console.out("  Restarting catalog pod...")
    ctx.runner.run(
        [
            "kubectl",
            "delete",
            "pod",
            "-n",
            namespace,
            "-l",
            selector_for(catalog_name),
            "--wait=false",
        ]
    )
    return True


def report_signature_failure(ctx: AppContext) -> None:
    """Ports ``report_catalog_signature_failure`` — verbatim."""
    ctx.console.err("ERROR: redhat-operator-index cannot be pulled (SignatureValidationFailed).")
    ctx.console.err("  MicroShift 4.22+ requires GPG signatures; the index image fails that check.")
    ctx.console.err(
        "  Fix (demo-only): aap-demo deploy re-applies signature policy and restarts "
        "the catalog pod."
    )
    ctx.console.err("  Ensure CRC is running with a valid ~/.crc/machines/crc SSH key.")


# ---------------------------------------------------------------------------
# The wait
# ---------------------------------------------------------------------------

#: Why :func:`wait_for_catalog_ready` stopped.
READY = "ready"
TIMEOUT = "timeout"
SIGNATURE_FAILURE = "signature_failure"
PULL_FAILURE = "pull_failure"
SCC_FAILURE = "scc_failure"


@dataclass(frozen=True)
class CatalogWait:
    outcome: str
    elapsed: float
    detail: List[str] = None  # type: ignore[assignment]

    @property
    def ok(self) -> bool:
        return self.outcome == READY


def timeout_seconds(ctx: AppContext) -> int:
    """Ports ``catalog_wait_timeout_seconds`` including the AO_ fallback name."""
    for var in ("AAP_CATALOG_TIMEOUT", "AO_CATALOG_TIMEOUT"):
        raw = ctx.env.get(var)
        if raw:
            try:
                return int(raw)
            except ValueError:
                continue
    return DEFAULT_CATALOG_TIMEOUT


def pod_is_ready(ctx: AppContext, namespace: str, *, catalog_name: str = CATALOG_NAME) -> bool:
    """Ports ``catalog_pod_is_ready``: phase Running and Ready=True."""
    phase = _pods_jsonpath(ctx, namespace, "{.items[0].status.phase}", catalog_name=catalog_name)
    ready = _pods_jsonpath(
        ctx,
        namespace,
        '{.items[0].status.conditions[?(@.type=="Ready")].status}',
        catalog_name=catalog_name,
    )
    return phase == "Running" and ready == "True"


def service_has_endpoint(
    ctx: AppContext, namespace: str, *, catalog_name: str = CATALOG_NAME
) -> bool:
    """Ports ``catalog_service_has_endpoint``."""
    address = kubectl.jsonpath(
        ctx.runner,
        "endpoints",
        catalog_name,
        "-n",
        namespace,
        path="{.subsets[0].addresses[0].ip}",
    )
    return bool(address.strip())


def wait_for_catalog_service_ready(
    ctx: AppContext,
    namespace: str,
    catalog_name: str = CATALOG_NAME,
    *,
    timeout: Optional[int] = None,
    interval: float = CATALOG_POLL_INTERVAL,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> CatalogWait:
    """Ports ``wait_for_catalog_service_ready`` (upstream #165).

    The AO fallback catalog uses this: the pod must be Ready and the Service
    must have an endpoint address. An SCC rejection stops the wait immediately.
    """
    budget = timeout if timeout is not None else timeout_seconds(ctx)
    state = {"outcome": TIMEOUT}

    def attempt(_n: int) -> bool:
        if pod_is_ready(ctx, namespace, catalog_name=catalog_name) and service_has_endpoint(
            ctx, namespace, catalog_name=catalog_name
        ):
            state["outcome"] = READY
            return True
        if has_scc_admission_failure(ctx, namespace, catalog_name=catalog_name):
            report_scc_failure(ctx, namespace, catalog_name=catalog_name)
            state["outcome"] = SCC_FAILURE
            raise waiting.Aborted("scc admission failed")
        return False

    def progress(n: int, _elapsed: float, _value: Any) -> None:
        ctx.events.progress(f"CatalogSource pod: {catalog_name} ({n * int(interval)}s / {budget}s)")

    result = waiting.wait_for(
        attempt,
        timeout=budget,
        interval=interval,
        description="CatalogSource service ready",
        on_attempt=progress,
        sleep=sleep,
        clock=clock,
    )
    outcome = READY if result.ok else str(state["outcome"])
    return CatalogWait(outcome=outcome, elapsed=result.elapsed)


def wait_for_catalog_ready(
    ctx: AppContext,
    namespace: str,
    *,
    catalog_name: str = CATALOG_NAME,
    timeout: Optional[int] = None,
    interval: float = CATALOG_POLL_INTERVAL,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> CatalogWait:
    """Ports ``wait_for_catalog_ready`` (includes/olm-catalog-signature.sh:216).

    Each of bash's two one-shot recovery attempts is preserved: the signature
    fix is tried once, the plain pod restart is tried once, and a second
    failure of the same shape is terminal rather than looping. Both are
    followed by a 15s settle before the poll resumes, which is why the
    recovery sleeps go through the injected ``sleep`` too.
    """
    budget = timeout if timeout is not None else timeout_seconds(ctx)
    state = {"signature_fix": False, "pod_restart": False, "outcome": TIMEOUT, "detail": []}

    def attempt(_n: int) -> bool:
        if catalog_state(ctx, namespace, catalog_name=catalog_name) == "READY":
            state["outcome"] = READY
            return True
        if has_scc_admission_failure(ctx, namespace, catalog_name=catalog_name):
            report_scc_failure(ctx, namespace, catalog_name=catalog_name)
            state["outcome"] = SCC_FAILURE
            raise waiting.Aborted("scc admission failed")
        if not has_image_pull_backoff(ctx, namespace, catalog_name=catalog_name):
            return False
        if has_signature_failure(ctx, namespace, catalog_name=catalog_name):
            if not state["signature_fix"] and recover_catalog_pull(
                ctx, namespace, fix_signature=True, catalog_name=catalog_name
            ):
                state["signature_fix"] = True
                state["pod_restart"] = True
                sleep(RECOVERY_SETTLE_SECONDS)
                return False
            state["outcome"] = SIGNATURE_FAILURE
            raise waiting.Aborted("signature validation failed")
        if not state["pod_restart"]:
            recover_catalog_pull(ctx, namespace, catalog_name=catalog_name)
            state["pod_restart"] = True
            sleep(RECOVERY_SETTLE_SECONDS)
            return False
        state["outcome"] = PULL_FAILURE
        state["detail"] = wait_reason(ctx, namespace, catalog_name=catalog_name)
        raise waiting.Aborted("catalog image cannot be pulled")

    def progress(n: int, elapsed: float, _value: Any) -> None:
        observed = catalog_state(ctx, namespace, catalog_name=catalog_name)
        phase = catalog_pod_phase(ctx, namespace, catalog_name=catalog_name)
        if is_pulling(observed, phase):
            ctx.events.progress(f"Pulling catalog image... ({n * int(interval)}s / {budget}s)")
        else:
            ctx.events.progress(
                f"CatalogSource: {observed or 'Pending'} | pod: {phase} ({n * int(interval)}s)"
            )

    result = waiting.wait_for(
        attempt,
        timeout=budget,
        interval=interval,
        description="CatalogSource ready",
        on_attempt=progress,
        sleep=sleep,
        clock=clock,
    )
    outcome = READY if result.ok else str(state["outcome"])
    return CatalogWait(outcome=outcome, elapsed=result.elapsed, detail=list(state["detail"]))


__all__ = [
    "CATALOG_NAME",
    "CatalogWait",
    "PULL_FAILURE",
    "READY",
    "SCC_FAILURE",
    "SIGNATURE_FAILURE",
    "TIMEOUT",
    "catalog_state",
    "ensure_policy",
    "has_image_pull_backoff",
    "has_scc_admission_failure",
    "has_signature_failure",
    "is_pulling",
    "needs_relaxation",
    "pod_is_ready",
    "recover_catalog_pull",
    "relax_signature_policy",
    "report_scc_failure",
    "report_signature_failure",
    "resolve_ocp_version",
    "selector_for",
    "service_has_endpoint",
    "timeout_seconds",
    "wait_for_catalog_ready",
    "wait_for_catalog_service_ready",
]
