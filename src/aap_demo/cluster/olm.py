"""OLM installation and the AAP operator's CatalogSource/OperatorGroup/Subscription.

Two halves:

* :func:`ensure_installed` ports ``addons/olm/deploy.sh``. Per the design's
  three-tier model (§4.5) ``olm`` is a **built-in**, not an addon, so it lands
  here rather than as an addon plugin — MicroShift ships no OLM and nothing
  else in the deploy path works without it.
* :func:`install_operator` ports the OLM half of ``deploy_latest``
  (aap-demo.sh:2101-2214): render and apply the three manifests, wait for the
  catalog, wait for the CSV.

**§14 R6 applies to the renderers below.** Bash patches these manifests with
``sed`` on substrings. That is reproduced here as real YAML manipulation,
which is R6's own recommendation, and the golden-file tests in
``tests/unit/test_olm_render.py`` pin every rendered document against what
bash's ``sed`` pipeline actually emits.

Two bash behaviors are preserved on purpose because they are *properties of
the sed*, not accidents of it:

* ``sed -e "s|namespace: aap|namespace: $NS|"`` on the Subscription has no
  ``g`` and is case-sensitive, so it never touches ``sourceNamespace:``. The
  YAML version sets ``metadata.namespace`` only, leaving ``sourceNamespace``
  at its hardcoded ``aap-operator``. That is a latent bug for a non-default
  namespace, but it is bash's behavior and fixing it is not in R6's brief.
* The OperatorGroup's ``s|- aap|- $NS|`` (no ``g``) rewrites the single
  ``targetNamespaces`` entry.

And **one is deliberately fixed**, exactly as R6 instructs: bash's
``s|channel: stable-2.6|channel: $AAP_CHANNEL|`` is a dead substitution —
``config/olm/subscription.yaml`` has said ``stable-2.7`` since the 2.7 bump,
so asking for any other channel silently installed 2.7. :func:`render_subscription`
sets ``spec.channel`` to the requested channel unconditionally.
"""

from __future__ import annotations

import re
import time
from typing import Any, Callable, Dict, List, Optional

import yaml

from aap_demo import data
from aap_demo.core import waiting
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError
from aap_demo.exec import kubectl
from aap_demo.exec import operator_sdk as sdk

SUBSCRIPTION_CRD = "subscriptions.operators.coreos.com"
OLM_NAMESPACE = "olm"
OPERATORS_NAMESPACE = "operators"
#: Ships with upstream OLM and cannot start on MicroShift, so bash removes it.
OPERATORHUB_CATALOG = "operatorhubio-catalog"

CSV_PREFIX = "aap-operator."
#: ``for i in $(seq 1 60)`` at 10s — ten minutes (aap-demo.sh:2196-2204).
CSV_APPEAR_ATTEMPTS = 60
CSV_APPEAR_INTERVAL = 10
#: ``kubectl wait --timeout=600s`` (aap-demo.sh:2214).
CSV_SUCCEED_TIMEOUT = 600

_INDEX_TAG_RE = re.compile(r"redhat-operator-index:v[0-9.]*")


# ---------------------------------------------------------------------------
# Manifest rendering (§14 R6)
# ---------------------------------------------------------------------------


def _load(package: str, name: str) -> Dict[str, Any]:
    return yaml.safe_load(data.read(package, name))


def _dump(document: Dict[str, Any]) -> str:
    return yaml.safe_dump(document, sort_keys=False, default_flow_style=False)


def render_catalogsource(namespace: str, ocp_version: str) -> str:
    """``sed -e s|redhat-operator-index:v[0-9.]*|…| -e s|namespace: aap-operator|…|``."""
    document = _load(data.OLM, "catalogsource.yaml")
    document["metadata"]["namespace"] = namespace
    document["spec"]["image"] = _INDEX_TAG_RE.sub(
        f"redhat-operator-index:v{ocp_version}", document["spec"]["image"]
    )
    return _dump(document)


def render_operatorgroup(namespace: str) -> str:
    """``sed -e s|namespace: aap|…|g -e s|name: aap-og|…| -e s|- aap|…|``."""
    document = _load(data.OLM, "operatorgroup.yaml")
    document["metadata"]["name"] = f"{namespace}-og"
    document["metadata"]["namespace"] = namespace
    document["spec"]["targetNamespaces"] = [namespace]
    return _dump(document)


def render_subscription(namespace: str, channel: str) -> str:
    """``sed -e s|namespace: aap|…| -e s|channel: stable-2.6|…|`` — with R6's fix.

    ``sourceNamespace`` is untouched, matching the non-global, case-sensitive
    sed; ``spec.channel`` is set unconditionally, which the sed only *appeared*
    to do (see the module docstring).
    """
    document = _load(data.OLM, "subscription.yaml")
    document["metadata"]["namespace"] = namespace
    document["spec"]["channel"] = channel
    return _dump(document)


# ---------------------------------------------------------------------------
# OLM itself
# ---------------------------------------------------------------------------


def is_installed(ctx: AppContext) -> bool:
    return kubectl.exists(ctx.runner, "crd", SUBSCRIPTION_CRD)


def _delete_operatorhub_catalog(ctx: AppContext) -> None:
    kubectl.delete(ctx.runner, "catsrc", OPERATORHUB_CATALOG, "-n", OLM_NAMESPACE)


def ensure_installed(
    ctx: AppContext, *, which: Optional[Callable[[str], Optional[str]]] = None
) -> bool:
    """Ports ``addons/olm/deploy.sh``'s deploy action.

    The odd-looking "install failed, but check the CRDs anyway" branch is
    bash's and is kept: ``operator-sdk olm install`` has an aggressive
    internal timeout and reports failure for installs that in fact completed.
    Only a genuinely partial install — no Subscription CRD — is cleaned up and
    treated as fatal.
    """
    import shutil

    resolve = which if which is not None else shutil.which

    if not kubectl.cluster_reachable(ctx.runner):
        raise AapDemoError(
            "kubectl not connected to cluster",
            hint="Make sure your cluster is running: crc start",
        )

    sdk.ensure_available(ctx, which=resolve)

    if is_installed(ctx):
        ctx.console.checkpoint("OLM is already installed")
        status = sdk.olm_status(ctx)
        for line in (status.stdout or "").splitlines()[:5]:
            if line.startswith("  "):
                ctx.console.note(line.strip())
        return True

    if sdk.olm_install(ctx).ok:
        _delete_operatorhub_catalog(ctx)
        return True

    ctx.console.warn("OLM install may have issues")
    ctx.console.out("Check: operator-sdk olm status")
    if is_installed(ctx):
        _delete_operatorhub_catalog(ctx)
        ctx.console.out("OLM CRDs are present — installation likely succeeded despite timeout.")
        return True

    ctx.console.out("ERROR: OLM installation incomplete. Cleaning up...")
    kubectl.delete(ctx.runner, "namespace", OLM_NAMESPACE)
    kubectl.delete(ctx.runner, "namespace", OPERATORS_NAMESPACE)
    raise AapDemoError(
        "OLM installation failed",
        hint="OLM is required for AAP deployments. Try: aap-demo enable olm",
    )


# ---------------------------------------------------------------------------
# The AAP operator's OLM objects
# ---------------------------------------------------------------------------


def apply_catalogsource(ctx: AppContext, namespace: str, ocp_version: str) -> None:
    ctx.console.progress(f"Creating CatalogSource (OCP {ocp_version})")
    kubectl.apply_stdin(ctx.runner, render_catalogsource(namespace, ocp_version))


def apply_operatorgroup(ctx: AppContext, namespace: str) -> None:
    ctx.console.progress("Creating OperatorGroup")
    kubectl.apply_stdin(ctx.runner, render_operatorgroup(namespace))


def apply_subscription(ctx: AppContext, namespace: str, channel: str) -> None:
    ctx.console.progress("Creating Subscription")
    kubectl.apply_stdin(ctx.runner, render_subscription(namespace, channel))


def find_csv(ctx: AppContext, namespace: str) -> str:
    """``kubectl get csv | grep '^aap-operator\\.' | awk '{print $1}' | head -1``."""
    listing = ctx.runner.run(["kubectl", "get", "csv", "-n", namespace])
    if not listing.ok:
        return ""
    for line in listing.stdout.splitlines():
        if line.startswith(CSV_PREFIX):
            return line.split()[0]
    return ""


def wait_for_csv(
    ctx: AppContext,
    namespace: str,
    *,
    attempts: int = CSV_APPEAR_ATTEMPTS,
    interval: float = CSV_APPEAR_INTERVAL,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> str:
    """Ports the ``for i in $(seq 1 60)`` CSV-appearance loop. Empty means timeout."""
    ctx.console.progress("Waiting for CSV to be created")

    def attempt(_n: int) -> str:
        return find_csv(ctx, namespace)

    def progress(n: int, _elapsed: float, _value: Any) -> None:
        ctx.events.progress(f"Waiting for CSV... ({n}/{attempts})")

    result = waiting.wait_for(
        attempt,
        timeout=attempts * interval,
        interval=interval,
        description="CSV created",
        on_attempt=progress,
        sleep=sleep,
        clock=clock,
    )
    if not result.ok:
        return ""
    ctx.console.progress(f"Found CSV: {result.value}")
    return str(result.value)


def wait_csv_succeeded(ctx: AppContext, namespace: str, csv_name: str) -> bool:
    """Ports the ``kubectl wait … || true`` on the CSV phase — without the ``|| true``.

    §14 R5: bash discards this result, so a CSV that never reaches Succeeded
    looks identical to one that did and the failure only surfaces much later
    as a missing operator. The result is returned here and the caller warns.
    """
    ctx.console.progress("Waiting for CSV to reach Succeeded")
    result = ctx.runner.run(
        [
            "kubectl",
            "wait",
            "--for=jsonpath={.status.phase}=Succeeded",
            f"csv/{csv_name}",
            "-n",
            namespace,
            f"--timeout={CSV_SUCCEED_TIMEOUT}s",
        ]
    )
    return bool(result.ok)


__all__: List[str] = [
    "CSV_PREFIX",
    "apply_catalogsource",
    "apply_operatorgroup",
    "apply_subscription",
    "ensure_installed",
    "find_csv",
    "is_installed",
    "render_catalogsource",
    "render_operatorgroup",
    "render_subscription",
    "wait_csv_succeeded",
    "wait_for_csv",
]
