"""AO's operator install through OLM. Ports addons/ao/deploy.sh and install-plan-approval.sh.

The Subscription, OperatorGroup and CatalogSource all live in AO's namespace:
MicroShift's OLM cannot resolve across namespaces, and AO needs AllNamespaces
mode, so its OperatorGroup cannot share AAP's namespace.
"""

from __future__ import annotations

import json
import time
from typing import Callable, List, Optional

from aap_demo.addons.ao import catalog as catalog_mod
from aap_demo.addons.ao import manifests
from aap_demo.addons.ao.postgres import NAMESPACE
from aap_demo.addons.common.kube import as_dict, output_of
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError, UsageError
from aap_demo.exec import kubectl

SUBSCRIPTION = "automation-orchestrator-operator"
OPERATOR = "automation-orchestrator-operator-controller-manager"
CSV_MARKER = "automation-orchestrator"
APPROVALS = ("Automatic", "Manual")
DEFAULT_CHANNEL = "stable"
INSTALLPLAN_ATTEMPTS = 30
INSTALLPLAN_INTERVAL = 10
OPERATOR_APPEAR_ATTEMPTS = 60
OPERATOR_APPEAR_INTERVAL = 5
PULL_SECRET = "automation-orchestrator-pull-secret"  # pragma: allowlist secret

Sleep = Callable[[float], None]


def channel(ctx: AppContext) -> str:
    return str(ctx.env.get("AO_OPERATOR_CHANNEL") or DEFAULT_CHANNEL)


def requested_approval(ctx: AppContext) -> str:
    value = str(ctx.env.get("AO_INSTALL_PLAN_APPROVAL") or "")
    if value and value not in APPROVALS:
        raise UsageError("AO_INSTALL_PLAN_APPROVAL must be Automatic or Manual")
    return value


def approval(ctx: AppContext) -> str:
    """The requested mode, else the Subscription's current one, else Automatic."""
    requested = requested_approval(ctx)
    if requested:
        return requested
    current = kubectl.jsonpath(
        ctx.runner,
        "subscription",
        SUBSCRIPTION,
        "-n",
        NAMESPACE,
        path="{.spec.installPlanApproval}",
    )
    return current if current in APPROVALS else "Automatic"


def set_approval(ctx: AppContext, mode: str) -> None:
    patched = kubectl.run(
        ctx.runner,
        "patch",
        "subscription",
        SUBSCRIPTION,
        "-n",
        NAMESPACE,
        "--type",
        "merge",
        "-p",
        json.dumps({"spec": {"installPlanApproval": mode}}),
    )
    if not patched.ok:
        raise AddonError(
            "could not set the AO InstallPlan approval mode", hint=output_of(patched) or None
        )


def apply_manifests(ctx: AppContext, *, mode: str) -> None:
    subscription = manifests.render(
        "operator-subscription.yaml",
        {
            "NAMESPACE": NAMESPACE,
            "CATALOG_NAMESPACE": NAMESPACE,
            "OPERATOR_CHANNEL": channel(ctx),
            "INSTALL_PLAN_APPROVAL": mode,
        },
    )
    rbac = manifests.render("operator-rbac.yaml", {"NAMESPACE": NAMESPACE})
    for manifest, what in ((subscription, "Subscription"), (rbac, "RBAC")):
        applied = kubectl.apply_stdin(ctx.runner, manifest)
        if not applied.ok:
            raise AddonError(
                f"could not apply the AO operator {what}", hint=output_of(applied) or None
            )


def _csvs(ctx: AppContext, namespace: str) -> List[str]:
    listed = kubectl.run(ctx.runner, "get", "csv", "-n", namespace, "-o", "name")
    if not listed.ok:
        return []
    return [line for line in (listed.stdout or "").split() if CSV_MARKER in line]


def cleanup(ctx: AppContext, aap_namespace: str) -> None:
    """Remove AO's Subscription, InstallPlans, CSVs and cluster RBAC."""
    kubectl.run(
        ctx.runner,
        "delete",
        "clusterrolebinding",
        "automation-orchestrator-operator-cluster-rolebinding",
        "--ignore-not-found",
        "--wait=false",
    )
    kubectl.run(
        ctx.runner,
        "delete",
        "clusterrole",
        "automation-orchestrator-operator-cluster-role",
        "--ignore-not-found",
        "--wait=false",
    )
    for namespace in (NAMESPACE, aap_namespace):
        kubectl.run(
            ctx.runner,
            "delete",
            "subscription",
            SUBSCRIPTION,
            "-n",
            namespace,
            "--ignore-not-found",
            "--wait=false",
        )
        kubectl.run(
            ctx.runner,
            "delete",
            "operatorgroup",
            SUBSCRIPTION,
            "-n",
            namespace,
            "--ignore-not-found",
            "--wait=false",
        )
        if namespace == aap_namespace:
            continue
        plans = kubectl.run(ctx.runner, "get", "installplan", "-n", namespace, "-o", "name")
        names = (plans.stdout or "").split() if plans.ok else []
        if names:
            kubectl.run(ctx.runner, "delete", *names, "-n", namespace, "--wait=false")
        csvs = _csvs(ctx, namespace)
        if csvs:
            kubectl.run(ctx.runner, "delete", *csvs, "-n", namespace, "--wait=false")


def clear_for_force(ctx: AppContext, aap_namespace: str, *, sleep: Sleep = time.sleep) -> None:
    """``--force``: drop the instance and OLM state, clearing stuck CSV finalizers."""
    ctx.console.info("Clearing existing operator OLM state...")
    kubectl.run(
        ctx.runner, "delete", "automationorchestrator", "--all", "-n", NAMESPACE, "--wait=false"
    )
    cleanup(ctx, aap_namespace)
    for attempt in range(1, 13):
        stuck = _csvs(ctx, NAMESPACE)
        if not stuck:
            break
        if attempt >= 6:
            ctx.console.info("Clearing stuck CSV finalizers...")
            for csv in stuck:
                kubectl.run(
                    ctx.runner,
                    "patch",
                    csv,
                    "-n",
                    NAMESPACE,
                    "--type=json",
                    "-p",
                    '[{"op":"remove","path":"/metadata/finalizers"}]',
                )
        sleep(5)
    cleanup_early_access(ctx)


def cleanup_early_access(ctx: AppContext) -> None:
    """Objects the early-access AO installer left outside AO's namespace."""
    for namespace in ("aap-operator", "olm", "openshift-marketplace"):
        kubectl.run(
            ctx.runner,
            "delete",
            "catalogsource",
            "cs-automation-orchestrator",
            "-n",
            namespace,
            "--ignore-not-found",
            "--wait=false",
        )
        kubectl.run(
            ctx.runner,
            "delete",
            "secret",
            "ao-registry-pull-secret",
            "-n",
            namespace,
            "--ignore-not-found",
        )


def _conditions(ctx: AppContext) -> List[dict]:
    document = kubectl.run(
        ctx.runner, "get", "subscription", SUBSCRIPTION, "-n", NAMESPACE, "-o", "json"
    )
    if not document.ok:
        return []
    try:
        status = as_dict(as_dict(json.loads(document.stdout or "{}")).get("status"))
    except json.JSONDecodeError:
        return []
    return [as_dict(c) for c in status.get("conditions") or []]


def resolution_failed(ctx: AppContext) -> bool:
    for condition in _conditions(ctx):
        if condition.get("status") != "True":
            continue
        if condition.get("type") == "ResolutionFailed":
            return True
        if (
            condition.get("type") == "CatalogSourcesUnhealthy"
            and condition.get("reason") != "AllCatalogSourcesHealthy"
        ):
            return True
    return False


def failure_detail(ctx: AppContext) -> str:
    return "\n".join(f"{c.get('type', '')}: {c.get('message', '')}" for c in _conditions(ctx))


def pending_installplans(ctx: AppContext) -> List[str]:
    """Unapproved InstallPlans of AO's Subscription."""
    listed = kubectl.run(ctx.runner, "get", "installplan", "-n", NAMESPACE, "-o", "json")
    if not listed.ok:
        return []
    try:
        items = as_dict(json.loads(listed.stdout or "{}")).get("items") or []
    except json.JSONDecodeError:
        return []
    current = kubectl.jsonpath(
        ctx.runner, "subscription", SUBSCRIPTION, "-n", NAMESPACE, path="{.status.installplan.name}"
    )
    pending: List[str] = []
    for item in items:
        metadata = as_dict(as_dict(item).get("metadata"))
        owned = any(
            as_dict(owner).get("kind") == "Subscription"
            and as_dict(owner).get("name") == SUBSCRIPTION
            for owner in metadata.get("ownerReferences") or []
        )
        name = str(metadata.get("name") or "")
        approved = bool(as_dict(as_dict(item).get("spec")).get("approved", False))
        if name and (name == current or owned) and not approved:
            pending.append(name)
    return pending


def _reset(ctx: AppContext, aap_namespace: str, *, mode: str, sleep: Sleep) -> None:
    ctx.console.info("Resetting failed operator subscription...")
    cleanup(ctx, aap_namespace)
    sleep(10)
    apply_manifests(ctx, mode=mode)


def resolution_error(ctx: AppContext, catalog: catalog_mod.Catalog) -> AddonError:
    if not catalog_mod.package_in_catalog(ctx, catalog.namespace):
        return catalog_mod.not_in_catalog(ctx, catalog)
    retry = (
        "Fallback index was already applied. Retry:"
        if catalog.fallback_used
        else "This is usually a stale subscription from when the catalog was unhealthy. Retry:"
    )
    return AddonError(
        "OLM could not resolve automation-orchestrator-operator subscription.",
        hint=f"{failure_detail(ctx)}\n{retry} aap-demo disable ao && aap-demo enable ao --force",
    )


def install(
    ctx: AppContext,
    catalog: catalog_mod.Catalog,
    aap_namespace: str,
    *,
    mode: str,
    sleep: Sleep = time.sleep,
) -> None:
    """Apply the Subscription and wait for AO's CSV, approving or reporting plans."""
    # AAP already has an OperatorGroup in its namespace; a second one there
    # makes OLM refuse every Subscription in it.
    kubectl.run(
        ctx.runner,
        "delete",
        "subscription",
        SUBSCRIPTION,
        "-n",
        aap_namespace,
        "--ignore-not-found",
        "--wait=false",
    )
    kubectl.run(
        ctx.runner,
        "delete",
        "operatorgroup",
        SUBSCRIPTION,
        "-n",
        aap_namespace,
        "--ignore-not-found",
        "--wait=false",
    )
    ctx.console.info(f"Installing automation orchestrator operator ({channel(ctx)} channel)...")
    apply_manifests(ctx, mode=mode)
    ctx.console.info("Waiting for InstallPlan...")
    reset_done = False
    announced: Optional[List[str]] = None
    pending: List[str] = []
    for attempt in range(1, INSTALLPLAN_ATTEMPTS + 1):
        pending = pending_installplans(ctx)
        if pending and mode == "Automatic":
            for plan in pending:
                ctx.console.info(f"Approving InstallPlan: {plan}")
                kubectl.run(
                    ctx.runner,
                    "patch",
                    "installplan",
                    plan,
                    "-n",
                    NAMESPACE,
                    "--type",
                    "merge",
                    "-p",
                    '{"spec":{"approved":true}}',
                )
        elif pending and mode == "Manual" and announced != pending:
            for plan in pending:
                ctx.console.info(f"Manual approval required for InstallPlan: {plan}")
                ctx.console.info(
                    f"  Approve it with: kubectl patch installplan {plan} -n {NAMESPACE} "
                    '--type merge -p \'{"spec":{"approved":true}}\''
                )
            announced = pending
        if _csvs(ctx, NAMESPACE):
            ctx.console.success("CSV created")
            return
        if resolution_failed(ctx):
            if not reset_done:
                _reset(ctx, aap_namespace, mode=mode, sleep=sleep)
                reset_done = True
                sleep(10)
                continue
            if catalog_mod.try_fallback(ctx, catalog, sleep=sleep):
                ctx.console.info(
                    f"Retrying operator subscription on fallback catalog ({channel(ctx)})..."
                )
                _reset(ctx, aap_namespace, mode=mode, sleep=sleep)
                reset_done = False
                sleep(10)
                continue
            raise resolution_error(ctx, catalog)
        detail = failure_detail(ctx).lower()
        if "constraints not satisfiable" in detail or "no operators found" in detail:
            if catalog_mod.try_fallback(ctx, catalog, sleep=sleep):
                ctx.console.info(
                    f"Retrying operator subscription on fallback catalog ({channel(ctx)})..."
                )
                _reset(ctx, aap_namespace, mode=mode, sleep=sleep)
                reset_done = False
                sleep(10)
                continue
            raise catalog_mod.not_in_catalog(ctx, catalog)
        if attempt < INSTALLPLAN_ATTEMPTS:
            sleep(INSTALLPLAN_INTERVAL)
    if mode == "Manual":
        message = "Timed out waiting for manual InstallPlan approval."
        if pending:
            message += f" Pending InstallPlan: {pending[0]}"
    else:
        message = "Operator CSV not found after 5 minutes."
    raise AddonError(message, hint=f"Subscription conditions:\n{failure_detail(ctx)}")


def wait_available(ctx: AppContext, *, sleep: Sleep = time.sleep) -> None:
    """Wait for the operator Deployment to exist, then to be Available."""
    for attempt in range(OPERATOR_APPEAR_ATTEMPTS):
        if kubectl.exists(ctx.runner, "deployment", OPERATOR, "-n", NAMESPACE):
            break
        if attempt + 1 < OPERATOR_APPEAR_ATTEMPTS:
            sleep(OPERATOR_APPEAR_INTERVAL)
    waited = kubectl.run(
        ctx.runner,
        "wait",
        "--for=condition=Available",
        f"deployment/{OPERATOR}",
        "-n",
        NAMESPACE,
        "--timeout=300s",
    )
    if not waited.ok:
        raise AddonError(
            "Operator deployment not Available after 5 minutes.",
            hint=f"Check: kubectl get pods -n {NAMESPACE}",
        )
    ctx.console.success("Operator running")


def ensure_pull_secret(ctx: AppContext, pull_secret_file: Optional[str]) -> bool:
    """AO's imagePullSecrets must be kubernetes.io/dockerconfigjson.

    Never copy redhat-operators-pull-secret: OLM can replace it with an Opaque
    placeholder that fails the CR's ConfigurationValid check.
    """
    kind = kubectl.jsonpath(ctx.runner, "secret", PULL_SECRET, "-n", NAMESPACE, path="{.type}")
    if kind == "kubernetes.io/dockerconfigjson" and kubectl.jsonpath(
        ctx.runner, "secret", PULL_SECRET, "-n", NAMESPACE, path="{.data.\\.dockerconfigjson}"
    ):
        return True
    if not pull_secret_file:
        ctx.console.warn(
            "No local pull secret found. The AO operator rejects Opaque catalog secrets as "
            "imagePullSecrets."
        )
        return False
    ctx.console.info(
        f"Creating image pull secret {PULL_SECRET} (kubernetes.io/dockerconfigjson)..."
    )
    kubectl.run(ctx.runner, "delete", "secret", PULL_SECRET, "-n", NAMESPACE, "--ignore-not-found")
    created = kubectl.run(
        ctx.runner,
        "create",
        "secret",
        "generic",
        PULL_SECRET,
        f"--from-file=.dockerconfigjson={pull_secret_file}",
        "--type=kubernetes.io/dockerconfigjson",
        "-n",
        NAMESPACE,
    )
    if not created.ok:
        raise AddonError(f"could not create {PULL_SECRET}", hint=output_of(created) or None)
    return True


def link_pull_secret(ctx: AppContext, pull_secret_file: Optional[str]) -> None:
    """Give the operator's service accounts the pull secret and restart it."""
    if not ensure_pull_secret(ctx, pull_secret_file):
        return
    ctx.console.info("Linking pull secret to operator service accounts...")
    for account in (OPERATOR, "default"):
        if kubectl.exists(ctx.runner, "sa", account, "-n", NAMESPACE):
            kubectl.run(
                ctx.runner,
                "patch",
                "sa",
                account,
                "-n",
                NAMESPACE,
                "--type=merge",
                "-p",
                json.dumps({"imagePullSecrets": [{"name": PULL_SECRET}]}),
            )
    if kubectl.exists(ctx.runner, "deployment", OPERATOR, "-n", NAMESPACE):
        kubectl.run(ctx.runner, "rollout", "restart", f"deployment/{OPERATOR}", "-n", NAMESPACE)
        kubectl.run(
            ctx.runner,
            "rollout",
            "status",
            f"deployment/{OPERATOR}",
            "-n",
            NAMESPACE,
            "--timeout=5m",
        )
