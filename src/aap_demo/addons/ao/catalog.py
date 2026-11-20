"""The CatalogSource AO's Subscription resolves from. Ports addons/ao/deploy.sh.

MicroShift's OLM cannot resolve from openshift-marketplace, so AO gets its own
``redhat-operators`` CatalogSource in its namespace. It points at AAP's healthy
catalog Service when both use the same index image, and at a fallback registry
Deployment next to AAP's catalog when AO needs a different index.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, List, Sequence

import yaml

from aap_demo import data
from aap_demo.addons.ao.postgres import NAMESPACE
from aap_demo.addons.common.kube import output_of
from aap_demo.cluster import catalog_signature as signature
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError
from aap_demo.exec import kubectl

CATALOG = "redhat-operators"
PACKAGE = "automation-orchestrator-operator"
PULL_SECRET = "redhat-operators-pull-secret"  # pragma: allowlist secret
SOURCE_NAMESPACES = ("aap-operator", "openshift-marketplace", "olm")
DEFAULT_FALLBACK_INDEX = (
    "registry.redhat.io/redhat/redhat-operator-index:"
    "v4.22-automation-orchestrator-operator-early-access-1787151066"
)
DEFAULT_FALLBACK_NAME = "ao-fallback"
PACKAGE_ATTEMPTS = 24
PACKAGE_INTERVAL = 5

Sleep = Callable[[float], None]


@dataclass
class Catalog:
    """Index choices made during one enable."""

    active_image: str = ""
    fallback_used: bool = False
    refresh: bool = False
    namespace: str = NAMESPACE


def fallback_index(ctx: AppContext) -> str:
    return str(ctx.env.get("AO_FALLBACK_INDEX_IMAGE") or DEFAULT_FALLBACK_INDEX)


def fallback_name(ctx: AppContext) -> str:
    return str(ctx.env.get("AO_FALLBACK_CATALOG_NAME") or DEFAULT_FALLBACK_NAME)


def _short(ref: str) -> str:
    return ref.split("/", 1)[1] if "/" in ref else ref


def source_namespace(ctx: AppContext) -> str:
    for namespace in SOURCE_NAMESPACES:
        if kubectl.exists(ctx.runner, "catalogsource", CATALOG, "-n", namespace):
            return namespace
    return SOURCE_NAMESPACES[0]


def _spec_image(ctx: AppContext, namespace: str, name: str = CATALOG) -> str:
    return kubectl.jsonpath(
        ctx.runner, "catalogsource", name, "-n", namespace, path="{.spec.image}"
    )


def require_aap_catalog(ctx: AppContext) -> None:
    """AO copies AAP's catalog, so that one must exist and be READY."""
    namespace = source_namespace(ctx)
    if not kubectl.exists(ctx.runner, "catalogsource", CATALOG, "-n", namespace):
        raise AddonError(
            "redhat-operators CatalogSource is missing.",
            hint="Run 'aap-demo deploy' first to install OLM and the operator catalog.",
        )
    state = signature.catalog_state(ctx, namespace)
    if state != "READY":
        raise AddonError(
            f"AAP redhat-operators catalog is not READY (state: {state or 'unknown'}).",
            hint=(
                "Fix the AAP catalog before enabling AO: aap-demo deploy\n"
                f"Check: kubectl get catalogsource {CATALOG} -n {namespace}"
            ),
        )


def package_in_catalog(ctx: AppContext, namespace: str, name: str = CATALOG) -> bool:
    source = kubectl.jsonpath(
        ctx.runner, "packagemanifest", PACKAGE, "-n", namespace, path="{.status.catalogSource}"
    )
    return source == name


def wait_for_package(
    ctx: AppContext, namespace: str, name: str = CATALOG, *, sleep: Sleep = time.sleep
) -> bool:
    for attempt in range(PACKAGE_ATTEMPTS):
        if package_in_catalog(ctx, namespace, name):
            return True
        if attempt + 1 < PACKAGE_ATTEMPTS:
            sleep(PACKAGE_INTERVAL)
    return False


def select_index(ctx: AppContext, catalog: Catalog) -> str:
    """AO_INDEX_IMAGE, else AAP's own index, else the fallback index."""
    explicit = str(ctx.env.get("AO_INDEX_IMAGE") or "")
    if explicit:
        catalog.active_image = explicit
        return explicit
    if catalog.active_image:
        return catalog.active_image
    aap_image = _spec_image(ctx, source_namespace(ctx))
    if aap_image:
        catalog.active_image = aap_image
        return aap_image
    if ctx.env.get("AO_DISABLE_INDEX_FALLBACK") != "1":
        ctx.console.info(
            "automation-orchestrator-operator not in default catalog; using fallback index"
        )
        ctx.console.info(f"  {_short(fallback_index(ctx))}")
        catalog.active_image = fallback_index(ctx)
        catalog.fallback_used = True
        return catalog.active_image
    version = signature.resolve_ocp_version(ctx)
    return f"registry.redhat.io/redhat/redhat-operator-index:v{version}"


# -- manifests ------------------------------------------------------------------


def _template() -> Dict[str, Any]:
    document = yaml.safe_load(data.read(data.OLM, "catalogsource.yaml"))
    return document if isinstance(document, dict) else {}


def image_catalogsource(name: str, namespace: str, image: str) -> str:
    document = _template()
    document["metadata"].update(name=name, namespace=namespace)
    document["spec"]["image"] = image
    return yaml.safe_dump(document, sort_keys=False)


def address_catalogsource(name: str, namespace: str, address: str) -> str:
    """A CatalogSource that proxies a running registry Service."""
    document = _template()
    document["metadata"].update(name=name, namespace=namespace)
    spec = document["spec"]
    spec.pop("image", None)
    spec.pop("secrets", None)
    rebuilt: Dict[str, Any] = {}
    for key, value in spec.items():
        if key == "grpcPodConfig":
            rebuilt["address"] = address
        rebuilt[key] = value
    rebuilt.setdefault("address", address)
    document["spec"] = rebuilt
    return yaml.safe_dump(document, sort_keys=False)


def _registry_template() -> Path:
    # Imported here: shell imports the addon registry, which imports this package.
    from aap_demo.addons.shell import scripts_root

    return scripts_root().parent / "config" / "olm" / "catalog-registry.yaml"


def registry_manifest(name: str, namespace: str, image: str) -> str:
    try:
        documents = list(yaml.safe_load_all(_registry_template().read_text(encoding="utf-8")))
    except OSError as exc:
        raise AddonError("could not read the catalog registry template", hint=str(exc)) from exc
    out: List[Dict[str, Any]] = []
    for document in documents:
        if not isinstance(document, dict):
            continue
        text = yaml.safe_dump(document, sort_keys=False)
        text = text.replace("redhat-operators-registry", name)
        text = text.replace("namespace: aap-operator", f"namespace: {namespace}")
        rendered = yaml.safe_load(text)
        for container in (
            rendered.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
        ):
            if "redhat-operator-index" in str(container.get("image", "")):
                container["image"] = image
        out.append(rendered)
    return yaml.safe_dump_all(out, sort_keys=False)


def _apply(ctx: AppContext, manifest: str, message: str) -> None:
    applied = kubectl.apply_stdin(ctx.runner, manifest)
    if not applied.ok:
        raise AddonError(message, hint=output_of(applied) or None)


# The AO pods outside restricted-v2 need only a fixed non-root UID: PostgreSQL
# runs as 26, and OLM's bundle unpack and catalog pods as 1001.
SCC = "nonroot-v2"
# Earlier releases granted these to the same accounts; enable and disable remove them.
LEGACY_SCCS = ("anyuid", "privileged")


def _binding(scc: str, account: str, namespace: str) -> str:
    return f"aap-demo-scc-{scc}-{namespace}-{account}"


def grant_scc(ctx: AppContext, scc: str, account: str, namespace: str) -> None:
    binding = _binding(scc, account, namespace)
    manifest = yaml.safe_dump(
        {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "ClusterRoleBinding",
            "metadata": {"name": binding},
            "roleRef": {
                "apiGroup": "rbac.authorization.k8s.io",
                "kind": "ClusterRole",
                "name": f"system:openshift:scc:{scc}",
            },
            "subjects": [{"kind": "ServiceAccount", "name": account, "namespace": namespace}],
        },
        sort_keys=False,
    )
    applied = kubectl.apply_stdin(ctx.runner, manifest)
    if not applied.ok:
        raise AddonError(
            f"Failed to grant SCC '{scc}' to ServiceAccount '{account}' "
            f"in namespace '{namespace}'.",
            hint=f"The current user must be allowed to create the SCC binding '{binding}'.",
        )


def grant_sccs(ctx: AppContext, accounts: Sequence[str], namespace: str) -> None:
    """Grant nonroot-v2, then drop the broader grants of earlier releases.

    SCCs are checked when a pod is admitted, so running pods keep theirs; the
    narrower grant is in place before any of them restarts.
    """
    for account in accounts:
        grant_scc(ctx, SCC, account, namespace)
    legacy = [_binding(scc, a, namespace) for a in accounts for scc in LEGACY_SCCS]
    removed = kubectl.run(ctx.runner, "delete", "clusterrolebinding", *legacy, "--ignore-not-found")
    if not removed.ok:
        ctx.console.warn(
            "Could not remove the anyuid and privileged grants earlier releases gave "
            f"{', '.join(accounts)} in {namespace}; remove them with: "
            f"kubectl delete clusterrolebinding {' '.join(legacy)}"
        )


def remove_sccs(ctx: AppContext, accounts: Sequence[str], namespace: str) -> None:
    """Delete AO's SCC bindings; they are cluster-scoped and outlive the namespace."""
    names = [_binding(scc, a, namespace) for a in accounts for scc in (SCC, *LEGACY_SCCS)]
    kubectl.run(ctx.runner, "delete", "clusterrolebinding", *names, "--ignore-not-found")


def copy_pull_secret(ctx: AppContext, source: str, target: str) -> bool:
    encoded = kubectl.jsonpath(
        ctx.runner, "secret", PULL_SECRET, "-n", source, path="{.data.\\.dockerconfigjson}"
    )
    if not encoded:
        return False
    manifest = yaml.safe_dump(
        {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {"name": PULL_SECRET, "namespace": target},
            "type": "kubernetes.io/dockerconfigjson",
            "data": {".dockerconfigjson": encoded},
        }
    )
    _apply(ctx, manifest, f"could not copy {PULL_SECRET} into {target}")
    return True


# -- fallback registry ---------------------------------------------------------


def remove_fallback(ctx: AppContext, namespace: str) -> None:
    name = fallback_name(ctx)
    kubectl.run(
        ctx.runner,
        "delete",
        "catalogsource",
        name,
        "-n",
        namespace,
        "--ignore-not-found",
        "--wait=false",
    )
    kubectl.run(
        ctx.runner,
        "delete",
        "deployment,service",
        f"{name}-registry",
        "-n",
        namespace,
        "--ignore-not-found",
    )
    kubectl.run(ctx.runner, "delete", "serviceaccount", name, "-n", namespace, "--ignore-not-found")
    kubectl.run(
        ctx.runner,
        "delete",
        "clusterrolebinding",
        f"aap-demo-scc-anyuid-{namespace}-{name}",
        f"aap-demo-scc-privileged-{namespace}-{name}",
        "--ignore-not-found",
    )


def _ensure_fallback(ctx: AppContext, namespace: str, image: str, *, sleep: Sleep) -> str:
    """Run the fallback index as a registry Deployment; return its gRPC address."""
    name = fallback_name(ctx)
    registry = f"{name}-registry"
    ctx.console.info(f"Creating fallback catalog registry {registry} in {namespace}...")
    _apply(
        ctx,
        registry_manifest(registry, namespace, image),
        "could not create the fallback catalog registry",
    )
    if _spec_image(ctx, namespace, name):
        deleted = kubectl.run(
            ctx.runner, "delete", "catalogsource", name, "-n", namespace, "--wait=true"
        )
        if not deleted.ok:
            raise AddonError(
                "could not replace the fallback CatalogSource", hint=output_of(deleted) or None
            )
    started = kubectl.run(
        ctx.runner,
        "rollout",
        "status",
        f"deployment/{registry}",
        "-n",
        namespace,
        f"--timeout={signature.timeout_seconds(ctx)}s",
    )
    if not started.ok:
        raise AddonError(
            "the fallback catalog registry did not start", hint=output_of(started) or None
        )
    address = f"{registry}.{namespace}.svc:50051"
    _apply(
        ctx,
        address_catalogsource(name, namespace, address),
        "could not create the fallback CatalogSource",
    )
    _wait_ready(ctx, namespace, name, sleep=sleep)
    if not wait_for_package(ctx, namespace, name, sleep=sleep):
        raise AddonError("automation-orchestrator-operator not found in fallback catalog.")
    return address


# -- the AO CatalogSource ---------------------------------------------------------


def report_failure(ctx: AppContext, namespace: str, name: str) -> AddonError:
    if signature.has_scc_admission_failure(ctx, namespace, catalog_name=name):
        signature.report_scc_failure(ctx, namespace, catalog_name=name)
        return AddonError("The catalog pod was refused by SCC admission.")
    state = signature.catalog_state(ctx, namespace, catalog_name=name) or "unknown"
    phase = signature.catalog_pod_phase(ctx, namespace, catalog_name=name) or "unknown"
    if phase in ("ImagePullBackOff", "ErrImagePull") and signature.has_signature_failure(
        ctx, namespace, catalog_name=name
    ):
        signature.report_signature_failure(ctx)
        return AddonError("The catalog index image failed signature validation.")
    reason = signature.wait_reason(ctx, namespace, catalog_name=name)
    hint = [
        f"Namespace: {namespace}",
        f"CatalogSource state: {state}",
        f"Catalog pod phase: {phase}",
        *(f"Pod detail: {line}" for line in reason),
        f"The AO addon copies redhat-operators into {NAMESPACE}. TRANSIENT_FAILURE while the "
        "pod is Pending usually means the multi-GB index image is still pulling.",
        f"Inspect: kubectl describe catalogsource {name} -n {namespace}",
        "Retry with a longer wait: AO_CATALOG_TIMEOUT=900 AO_REFRESH_CATALOG=1 aap-demo enable ao",
    ]
    return AddonError("CatalogSource not READY after waiting.", hint="\n".join(hint))


def _wait_ready(ctx: AppContext, namespace: str, name: str, *, sleep: Sleep) -> None:
    waited = signature.wait_for_catalog_ready(ctx, namespace, catalog_name=name, sleep=sleep)
    if not waited.ok:
        raise report_failure(ctx, namespace, name)


def ensure(ctx: AppContext, catalog: Catalog, *, sleep: Sleep = time.sleep) -> None:
    """Create or update AO's CatalogSource and wait for the operator package."""
    target = catalog.namespace
    source_ns = source_namespace(ctx)
    image = select_index(ctx, catalog)
    source_image = _spec_image(ctx, source_ns)
    current_image = _spec_image(ctx, target)
    refresh_ns, refresh_name = target, CATALOG

    ctx.console.info(f"Creating AO CatalogSource in {target}...")
    ctx.console.info(f"  Index: {_short(image)}")
    if not signature.ensure_policy(ctx):
        raise AddonError("could not relax the registry signature policy for the catalog index")

    if source_ns != target and source_image and image == source_image:
        # Proxy AAP's healthy catalog Service. A second image-backed catalog pod
        # can pass its own readiness probe while OLM still reports it unhealthy.
        remove_fallback(ctx, source_ns)
        _apply(
            ctx,
            address_catalogsource(CATALOG, target, f"{CATALOG}.{source_ns}.svc:50051"),
            "could not create AO's CatalogSource",
        )
        refresh_ns = source_ns
    elif image != source_image:
        address = _ensure_fallback(ctx, source_ns, image, sleep=sleep)
        _apply(
            ctx,
            address_catalogsource(CATALOG, target, address),
            "could not create AO's CatalogSource",
        )
        refresh_ns, refresh_name = source_ns, fallback_name(ctx)
    else:
        if not copy_pull_secret(ctx, source_ns, target):
            raise AddonError(
                f"{PULL_SECRET} not found in {source_ns}", hint="Run 'aap-demo deploy' first."
            )
        _apply(
            ctx, image_catalogsource(CATALOG, target, image), "could not create AO's CatalogSource"
        )

    if catalog.refresh or (current_image and current_image != image):
        ctx.console.info("Restarting catalog pod...")
        if refresh_name == fallback_name(ctx):
            registry = f"{refresh_name}-registry"
            for argv in (
                ("rollout", "restart", f"deployment/{registry}", "-n", refresh_ns),
                (
                    "rollout",
                    "status",
                    f"deployment/{registry}",
                    "-n",
                    refresh_ns,
                    f"--timeout={signature.timeout_seconds(ctx)}s",
                ),
            ):
                result = kubectl.run(ctx.runner, *argv)
                if not result.ok:
                    raise AddonError(
                        "could not restart the fallback catalog registry",
                        hint=output_of(result) or None,
                    )
        else:
            kubectl.run(
                ctx.runner,
                "delete",
                "pod",
                "-n",
                refresh_ns,
                "-l",
                f"olm.catalogSource={refresh_name}",
                "--wait=false",
            )

    ctx.console.info("Waiting for CatalogSource READY...")
    _wait_ready(ctx, target, CATALOG, sleep=sleep)
    ctx.console.success("CatalogSource READY")
    if wait_for_package(ctx, target, sleep=sleep):
        ctx.console.success("automation-orchestrator-operator found in catalog")
    else:
        ctx.console.warn(
            "automation-orchestrator-operator still not in catalog after refresh; "
            "the index image may not include this operator yet."
        )


def try_fallback(ctx: AppContext, catalog: Catalog, *, sleep: Sleep = time.sleep) -> bool:
    """Switch to the fallback index once. False when it is off or already used."""
    if ctx.env.get("AO_DISABLE_INDEX_FALLBACK") == "1" or ctx.env.get("AO_INDEX_IMAGE"):
        return False
    if catalog.fallback_used or select_index(ctx, catalog) == fallback_index(ctx):
        return False
    ctx.console.info("Switching AO catalog to fallback index...")
    ctx.console.info(f"  {_short(fallback_index(ctx))}")
    catalog.active_image = fallback_index(ctx)
    catalog.fallback_used = True
    ensure(ctx, catalog, sleep=sleep)
    return package_in_catalog(ctx, catalog.namespace)


def not_in_catalog(ctx: AppContext, catalog: Catalog) -> AddonError:
    image = _spec_image(ctx, catalog.namespace) or "unknown"
    hint = "\n".join(
        [
            f"The operator may not be published in your current operator index: {_short(image)}",
            "This install path requires automation-orchestrator-operator in "
            "redhat-operator-index (v4.18+).",
            f"Verify: kubectl get packagemanifest {PACKAGE} -n {catalog.namespace}",
            "Clean up a failed attempt: aap-demo disable ao",
            "Force a catalog refresh: AO_REFRESH_CATALOG=1 aap-demo enable ao",
            f"Fallback index (automatic when the default catalog lacks AO): "
            f"{_short(fallback_index(ctx))}",
            "Disable the automatic fallback: AO_DISABLE_INDEX_FALLBACK=1 aap-demo enable ao",
        ]
    )
    return AddonError(
        f"automation-orchestrator-operator is not in catalog {CATALOG} ({catalog.namespace}).",
        hint=hint,
    )


def remove(ctx: AppContext) -> None:
    """Remove the fallback registry left next to AAP's catalog."""
    remove_fallback(ctx, source_namespace(ctx))


__all__ = [
    "CATALOG",
    "Catalog",
    "PACKAGE",
    "ensure",
    "not_in_catalog",
    "package_in_catalog",
    "remove",
    "require_aap_catalog",
    "try_fallback",
]
