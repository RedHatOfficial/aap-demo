"""The deploy orchestration — one entry point ``cli/`` and ``gui/`` share (§2.1).

Ports ``cmd_deploy`` (aap-demo.sh:2018-2083) and ``deploy_latest``
(aap-demo.sh:2101-2229) as one ordered sequence. The order is bash's and is
not rearranged (§14 R1's discipline, applied outside ``crc-create.sh``):

    disk space → namespace (SCCs, PSA, pull secret) → CoreDNS →
    signature policy → CatalogSource → catalog wait → OperatorGroup →
    Subscription → CSV appears → CSV Succeeded → AAP CR → gateway patch →
    readiness

Two things bash does here are deliberately **not** ported:

* ``_load_local_cache`` (aap-demo.sh:2217). §2.2's mapping table removes it
  from the deploy path outright — image caching becomes a day-2 operation
  (§4.8.5) and the deploy path stops branching on whether an addon is enabled.
* ``_aap_demo_run_addon_wire`` (aap-demo.sh:2065). Addon wiring needs the
  addon registry, which is phase 5.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional

from aap_demo.cluster import aap as aap_mod
from aap_demo.cluster import catalog_signature, coredns, olm
from aap_demo.cluster import namespace as namespace_mod
from aap_demo.core.console import format_elapsed
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError, ClusterUnreachableError
from aap_demo.exec import kubectl
from aap_demo.exec import ssh as ssh_mod
from aap_demo.infra import crc as infra_crc

#: ``_check_disk_space`` thresholds (aap-demo.sh:589-618).
DISK_ERROR_PERCENT = 95
DISK_WARN_PERCENT = 80


@dataclass
class DeployResult:
    aap_name: str = ""
    csv: str = ""
    route: str = ""
    ready: bool = False
    skipped_existing: bool = False
    warnings: List[str] = field(default_factory=list)

    def as_dict(self) -> Dict[str, Any]:
        return {
            "aap_name": self.aap_name,
            "csv": self.csv,
            "route": self.route,
            "ready": self.ready,
            "skipped_existing": self.skipped_existing,
            "warnings": list(self.warnings),
        }


def check_disk_space(ctx: AppContext) -> bool:
    """Ports ``_check_disk_space`` — False means "stop, the VM is out of room".

    Any inability to read the figure is *not* a failure: bash returns 0 when
    the SSH probe produces nothing, because a deploy should not be blocked by
    a diagnostic that could not run.
    """
    key = ssh_mod.detect_ssh_key(ssh_mod.crc_machines_dir(ctx.env))
    if key is None:
        return True
    result = ssh_mod.exec_remote(
        ctx.runner,
        key,
        "bash",
        "-c",
        "df /var --output=pcent 2>/dev/null | tail -1 | tr -d ' %'",
        sudo=False,
    )
    if not result.ok:
        return True
    try:
        usage = int(result.stdout.strip().splitlines()[-1])
    except (IndexError, ValueError):
        return True

    if usage >= DISK_ERROR_PERCENT:
        ctx.console.out("")
        ctx.console.failure(f"Cluster VM disk is {usage}% full")
        ctx.console.out("")
        ctx.console.out("  Free space by pruning unused container images:")
        ctx.console.out("    aap-demo ssh")
        ctx.console.out("    sudo crictl rmi --prune")
        ctx.console.out("")
        ctx.console.out("  Or destroy and recreate with a larger disk:")
        ctx.console.out("    aap-demo destroy && aap-demo create")
        return False
    if usage >= DISK_WARN_PERCENT:
        ctx.console.out("")
        ctx.console.warn(f"Cluster VM disk is {usage}% full")
        ctx.console.out("  Consider pruning unused images: aap-demo ssh && sudo crictl rmi --prune")
        ctx.console.out("")
    return True


def _preset(ctx: AppContext) -> str:
    return str(ctx.config.get("crc.preset", "microshift") or "microshift")


def run(
    ctx: AppContext,
    *,
    cr_name: Optional[str] = None,
    wait: bool = True,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> DeployResult:
    """Deploy AAP. Raises ``AapDemoError`` where bash called ``exit 1``."""
    ns = ctx.namespace
    result = DeployResult()

    ctx.console.tasks(
        [
            "Infrastructure: OpenShift Local",
            "Connecting to the cluster",
            "Trusting the ingress certificate",
            "Installing OLM",
            "Waiting for the operator catalog",
            "Installing the AAP operator",
            "Creating the AAP instance",
            "Waiting for AAP",
        ]
    )
    ctx.console.step("Infrastructure: OpenShift Local")
    ctx.console.checkpoint("Infrastructure: OpenShift Local")
    ctx.console.step("Connecting to the cluster")

    if not kubectl.cluster_reachable(ctx.runner):
        raise ClusterUnreachableError(
            "Cannot connect to cluster",
            hint=(
                f"Current context: {kubectl.current_context(ctx.runner) or 'none'}\n"
                "  Check your KUBECONFIG or use --context flag"
            ),
        )
    ctx.console.checkpoint(f"Connected to {kubectl.current_context(ctx.runner)}")
    ctx.console.step("Trusting the ingress certificate")
    from aap_demo.cluster import ingress_ca

    ingress_ca.install(ctx)

    if not infra_crc.verify_version(ctx):
        raise AapDemoError("CRC version check failed")

    if not ctx.force:
        existing = aap_mod.existing_instance(ctx, ns)
        if existing:
            ctx.console.out("")
            ctx.console.success(f"AAP instance '{existing}' already exists in namespace {ns}")
            ctx.console.out("  Skipping installation, validating existing deployment...")
            ctx.console.out("  (Use --force to reinstall)")
            ctx.console.out("")
            result.aap_name = existing
            result.skipped_existing = True
            if wait:
                ctx.console.step("Waiting for AAP", timed=True)
                aap_started = clock()
                readiness = aap_mod.wait_ready(ctx, namespace=ns, sleep=sleep, clock=clock)
                aap_elapsed = clock() - aap_started
                result.ready, result.route, result.csv = (
                    readiness.ready,
                    readiness.route,
                    readiness.csv,
                )
                _finish_wait(ctx, readiness)
                _report_times(ctx, None, aap_elapsed)
            return result

    ctx.console.step("Installing OLM")
    olm.ensure_installed(ctx)
    ctx.console.checkpoint("OLM is installed")

    if not kubectl.cluster_reachable(ctx.runner):
        # Bash re-runs `_verify_cluster` here because the OLM install can
        # rotate serving certs out from under the current kubeconfig.
        raise ClusterUnreachableError(
            "Cluster is not accessible",
            hint=(
                "Run: aap-demo create   # Create a new cluster\n"
                "  Run: crc start    # Start a stopped cluster\n"
                "  Run: aap-demo status   # Check cluster status"
            ),
        )

    if not check_disk_space(ctx):
        raise AapDemoError("Cluster VM is out of disk space")

    channel = str(ctx.config.get("deploy.channel", "stable-2.7") or "stable-2.7")
    ocp_version = catalog_signature.resolve_ocp_version(ctx)

    ctx.console.step("Waiting for the operator catalog")
    namespace_mod.ensure(ctx, ns, sleep=sleep)
    coredns.verify(ctx, sleep=sleep)
    if _preset(ctx) == "microshift" and catalog_signature.needs_relaxation(ocp_version):
        ctx.console.progress("Relaxing container signature policy for registry.redhat.io")
        if not catalog_signature.relax_signature_policy(ctx):
            ctx.console.out("  WARNING: Could not relax signature policy — catalog pull may fail")
            ctx.console.out(
                "  Try: crc start && aap-demo ssh   # verify VM SSH works, then re-run deploy"
            )
            result.warnings.append("signature policy not relaxed")

    olm.apply_catalogsource(ctx, ns, ocp_version)
    _await_catalog(ctx, ns, sleep=sleep, clock=clock)

    ctx.console.step("Installing the AAP operator", timed=True)
    operator_started = clock()
    ctx.console.progress(f"AAP 2.7 in {ns}")
    olm.apply_operatorgroup(ctx, ns)
    olm.apply_subscription(ctx, ns, channel)

    csv_name = olm.wait_for_csv(ctx, ns, sleep=sleep, clock=clock)
    if not csv_name:
        raise AapDemoError(
            "CSV not found after 10 minutes",
            hint=f"Check: kubectl get subscription -n {ns}",
        )
    result.csv = csv_name

    if not olm.wait_csv_succeeded(ctx, ns, csv_name):
        # §14 R5: bash's `|| true` made this indistinguishable from success.
        ctx.console.warn(f"CSV {csv_name} did not reach Succeeded — continuing as bash did")
        result.warnings.append(f"csv {csv_name} not Succeeded")

    ctx.console.checkpoint("AAP operator is installed")
    operator_elapsed = clock() - operator_started
    ctx.console.step("Creating the AAP instance")
    result.aap_name = aap_mod.create_instance(ctx, cr_name=cr_name, namespace=ns, sleep=sleep)
    ctx.console.checkpoint("AAP instance created")

    if wait:
        ctx.console.step("Waiting for AAP", timed=True)
        aap_started = clock()
        readiness = aap_mod.wait_ready(ctx, namespace=ns, sleep=sleep, clock=clock)
        aap_elapsed = clock() - aap_started
        result.ready, result.route, result.csv = (
            readiness.ready,
            readiness.route,
            readiness.csv or result.csv,
        )
        _finish_wait(ctx, readiness)
        _report_readiness(ctx, readiness, ns, operator_elapsed, aap_elapsed)

    return result


def _await_catalog(
    ctx: AppContext,
    ns: str,
    *,
    sleep: Callable[[float], None],
    clock: Callable[[], float],
) -> None:
    if catalog_signature.catalog_state(ctx, ns) == "READY":
        ctx.console.checkpoint("CatalogSource already ready")
        return

    ctx.console.progress("The operator index is multi-GB; the first pull can take 10+ minutes")
    outcome = catalog_signature.wait_for_catalog_ready(ctx, ns, sleep=sleep, clock=clock)
    if outcome.ok:
        ctx.console.checkpoint("CatalogSource is ready")
        return
    if outcome.outcome == catalog_signature.SIGNATURE_FAILURE:
        catalog_signature.report_signature_failure(ctx)
        raise AapDemoError("CatalogSource could not pull the operator index")
    if outcome.outcome == catalog_signature.PULL_FAILURE:
        ctx.console.err("ERROR: Catalog pod cannot pull operator index image.")
        if outcome.detail:
            ctx.console.err("  Pod detail:")
            for line in outcome.detail:
                ctx.console.err(f"    {line}")
        raise AapDemoError("CatalogSource could not pull the operator index")
    if outcome.outcome == catalog_signature.SCC_FAILURE:
        raise AapDemoError("CatalogSource pod was rejected by SCC admission")
    raise AapDemoError(
        f"CatalogSource not ready after {catalog_signature.timeout_seconds(ctx)}s",
        hint=(f"Check: kubectl describe pod -n {ns} -l {catalog_signature.CATALOG_SELECTOR}"),
    )


def _finish_wait(ctx: AppContext, readiness: aap_mod.AapReadiness) -> None:
    """Check off the timed wait so its duration freezes when ``wait_ready`` returns."""
    note = "AAP is ready" if readiness.ready else "AAP did not become ready"
    ctx.console.checkpoint(note)


def _report_times(
    ctx: AppContext, operator_elapsed: Optional[float], aap_elapsed: Optional[float]
) -> None:
    """Operator install, AAP reconcile, and the sum of those two."""
    if operator_elapsed is None and aap_elapsed is None:
        return
    ctx.console.out("Installation time")
    if operator_elapsed is not None:
        ctx.console.out(f"  Operator  {format_elapsed(operator_elapsed)}")
    if aap_elapsed is not None:
        ctx.console.out(f"  AAP       {format_elapsed(aap_elapsed)}")
    measured = [value for value in (operator_elapsed, aap_elapsed) if value is not None]
    ctx.console.out(f"  Total     {format_elapsed(sum(measured))}")
    ctx.console.out("")


def _report_readiness(
    ctx: AppContext,
    readiness: aap_mod.AapReadiness,
    ns: str,
    operator_elapsed: Optional[float] = None,
    aap_elapsed: Optional[float] = None,
) -> None:
    """Ports ``watch_aap``'s terminal summary (aap-demo.sh:2607-2634)."""
    if readiness.ready:
        ctx.console.success("AAP deployment successful!")
    else:
        ctx.console.warn("Deployment not complete after 60 minutes")
        ctx.console.out("The AAP instance is installed. Its Successful condition was not True.")
    ctx.console.out("")
    _report_times(ctx, operator_elapsed, aap_elapsed)
    if readiness.version:
        ctx.console.out(f"Version: {readiness.version}")
    if readiness.csv:
        ctx.console.out(f"CSV: {readiness.csv}")
    ctx.console.out(f"Namespace: {ns}")
    ctx.console.out("")
    ctx.console.out("Login:")
    ctx.console.out(f"  URL:      https://{readiness.route or '(route not found)'}")
    ctx.console.out(f"  Username: {readiness.username}")
    if readiness.password:
        ctx.console.out(f"  Password: {readiness.password}")
    else:
        ctx.console.out("  Password: (admin secret not found yet)")
        ctx.console.out(
            f"    kubectl get secret -n {ns} aap-admin-password "
            "-o jsonpath='{.data.password}' | base64 -d"
        )
    ctx.console.out("")


def ensure_cluster_running(ctx: AppContext) -> str:
    """Ports ``cmd_deploy``'s opening cluster-state branch (aap-demo.sh:2025-2033).

    Only *reports* here: ``create`` and ``start`` are phase 4 and phase 2, so
    a not-created or stopped cluster raises with bash's own next-step text
    rather than silently doing nothing.
    """
    state = infra_crc.get_state(ctx.runner)
    if state == infra_crc.STATE_NOT_CREATED:
        raise ClusterUnreachableError(
            "No cluster found.",
            hint="Run: aap-demo create",
        )
    if state == infra_crc.STATE_STOPPED:
        raise ClusterUnreachableError(
            "Cluster is stopped.",
            hint="Run: crc start",
        )
    return state


__all__ = ["DeployResult", "check_disk_space", "ensure_cluster_running", "run"]
