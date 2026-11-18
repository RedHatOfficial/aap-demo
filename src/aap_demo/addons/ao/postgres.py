"""AO's PostgreSQL: one rhel9/postgresql-15 StatefulSet with service-ca TLS (ADR-043).

Ports addons/ao/lib/postgres-{tls,reset,storage}.sh and the PostgreSQL steps of
addons/ao/deploy.sh. Every check that cannot tell "absent" from "could not
read" treats the failure as present and stops, so a failed API call never
leads to deleting or replacing a database.
"""

from __future__ import annotations

import base64
import json
import re
import secrets
import string
import time
from typing import Any, Callable, Dict, List, Optional

from aap_demo.addons.ao import manifests
from aap_demo.addons.common.kube import as_dict, output_of
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError
from aap_demo.exec import kubectl

NAMESPACE = "automation-orchestrator"
STATEFULSET = "orchestrator-postgres"
POD = "orchestrator-postgres-0"
PVC = "data-orchestrator-postgres-0"
SERVICE_HOST = f"orchestrator-postgres-rw.{NAMESPACE}.svc"
CA_SECRET = "orchestrator-postgres-ca"
CA_BUNDLE = "orchestrator-postgres-ca-bundle"
TLS_SECRET = "orchestrator-postgres-tls"  # pragma: allowlist secret
DATABASES = ("orchestrator", "temporal", "temporal_visibility")
#: Secret name -> database, all owned by the ``orchestrator`` role.
DATABASE_SECRETS = {
    "orchestrator-postgres-secret": "orchestrator",
    "temporal-postgres-secret": "temporal",
    "temporal-visibility-postgres-secret": "temporal_visibility",
}
#: Names from installs before ADR-043. Their presence needs ``--force``.
LEGACY_SECRETS = ("orchestrator-pg-credentials", "temporal-pg-credentials")
IMAGE_FALLBACK = "registry.redhat.io/rhel9/postgresql-15"
DEFAULT_STORAGE_SIZE = "3Gi"
NFS_CLASS = "nfs-local-rwx"
BLOCK_CLASS = "topolvm-provisioner"

#: The CNPG objects an older AO created. Cleanup never uses ``--all``.
CNPG_CLUSTER = "orchestrator-postgres"
CNPG_DATABASES = ("orchestrator", "temporal", "temporal-visibility")
CNPG_PVC = "orchestrator-postgres-1"

_IMAGE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/:@-]*$")
_CLASS_RE = re.compile(r"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$")
_SIZE_RE = re.compile(r"^[0-9]+([.][0-9]+)?([EPTGMK]i|[EPTGMkmun]|[eE][+-]?[0-9]+)?$")
_ZERO_RE = re.compile(r"^0+([.]0+)?([EPTGMK]i|[EPTGMkmun]|[eE][+-]?[0-9]+)?$")
_AAP_PG_IMAGE_RE = re.compile(r"/rhel[0-9]+/postgresql-15[@:]")

Sleep = Callable[[float], None]


def _kubectl(ctx: AppContext, *args: str, stdin: Optional[str] = None) -> Any:
    return ctx.runner.run(["kubectl", *args], input=stdin)


def _name_if_present(ctx: AppContext, *args: str, what: str) -> str:
    """``kubectl get … --ignore-not-found -o name``. A failed read raises."""
    result = _kubectl(ctx, "get", *args, "--ignore-not-found", "-o", "name")
    if not result.ok:
        raise AddonError(
            f"Could not check {what}; refusing to change AO PostgreSQL.",
            hint=output_of(result) or None,
        )
    return (result.stdout or "").strip()


def _json_if_present(ctx: AppContext, *args: str, what: str) -> Optional[Dict[str, Any]]:
    result = _kubectl(ctx, "get", *args, "--ignore-not-found", "-o", "json")
    if not result.ok:
        raise AddonError(
            f"Could not read {what}; refusing to change AO PostgreSQL.",
            hint=output_of(result) or None,
        )
    text = (result.stdout or "").strip()
    if not text:
        return None
    try:
        return as_dict(json.loads(text))
    except json.JSONDecodeError as exc:
        raise AddonError(f"Could not read {what}", hint=str(exc)) from exc


# -- settings -----------------------------------------------------------------


def validate_storage_size(size: str) -> str:
    if not _SIZE_RE.match(size) or _ZERO_RE.match(size):
        raise AddonError(
            f"PostgreSQL storage size '{size}' is not a supported Kubernetes quantity.",
            hint="Set AO_STORAGE_SIZE to a size such as 3Gi.",
        )
    return size


def requested_storage_size(ctx: AppContext) -> str:
    return str(ctx.env.get("AO_STORAGE_SIZE") or DEFAULT_STORAGE_SIZE)


def storage_class(ctx: AppContext) -> str:
    """Block storage for PostgreSQL. Never the NFS class AO's own volumes use."""
    chosen = str(ctx.env.get("AO_POSTGRES_STORAGE_CLASS") or "")
    if not chosen:
        if kubectl.exists(ctx.runner, "sc", BLOCK_CLASS):
            chosen = BLOCK_CLASS
        else:
            path = (
                "{range .items[?(@.metadata.annotations.storageclass\\.kubernetes\\.io/"
                'is-default-class=="true")]}{.metadata.name}{"\\n"}{end}'
            )
            default = kubectl.jsonpath(ctx.runner, "sc", path=path).splitlines()
            chosen = default[0].strip() if default else ""
            if chosen == NFS_CLASS:
                chosen = ""
    if not chosen:
        raise AddonError(
            "No block StorageClass found for AO's PostgreSQL.",
            hint="Set AO_POSTGRES_STORAGE_CLASS to a ReadWriteOnce block StorageClass.",
        )
    if not _CLASS_RE.match(chosen):
        raise AddonError(f"StorageClass '{chosen}' is not a valid name.")
    return chosen


def image(ctx: AppContext, aap_namespace: str) -> str:
    """AAP's own PostgreSQL 15 image, already on the node, else the public one."""
    chosen = str(ctx.env.get("AO_POSTGRES_IMAGE") or "")
    if not chosen:
        result = _kubectl(ctx, "get", "statefulset", "-n", aap_namespace, "-o", "json")
        if result.ok:
            try:
                items = as_dict(json.loads(result.stdout or "{}")).get("items") or []
            except json.JSONDecodeError:
                items = []
            for item in items:
                spec = as_dict(as_dict(as_dict(item).get("spec")).get("template")).get("spec")
                for container in as_dict(spec).get("containers") or []:
                    ref = str(as_dict(container).get("image") or "")
                    if _AAP_PG_IMAGE_RE.search(ref):
                        chosen = ref
                        break
                if chosen:
                    break
    chosen = chosen or IMAGE_FALLBACK
    if not _IMAGE_RE.match(chosen):
        raise AddonError(f"PostgreSQL image '{chosen}' is not a valid image reference.")
    return chosen


def storage_size(ctx: AppContext, requested: str) -> str:
    """The claim size to apply. A StatefulSet's claim template is immutable.

    Reuse the template size of an existing set, else the requested size of a
    retained PVC, else ``requested``.
    """
    existing = ""
    document = _json_if_present(
        ctx, "statefulset", STATEFULSET, "-n", NAMESPACE, what="the PostgreSQL StatefulSet"
    )
    if document is not None:
        sizes = [
            as_dict(as_dict(as_dict(t).get("spec")).get("resources")).get("requests", {})
            for t in as_dict(document.get("spec")).get("volumeClaimTemplates") or []
            if as_dict(as_dict(t).get("metadata")).get("name") == "data"
        ]
        values = [str(as_dict(s).get("storage") or "") for s in sizes]
        if len(values) != 1 or not values[0]:
            raise AddonError(
                "Could not read the PostgreSQL StatefulSet claim size; "
                "refusing to apply the manifest."
            )
        existing = values[0]
    else:
        claim = _json_if_present(
            ctx, "pvc", PVC, "-n", NAMESPACE, what="the retained PostgreSQL PVC"
        )
        if claim is not None:
            value = as_dict(as_dict(claim.get("spec")).get("resources")).get("requests")
            existing = str(as_dict(value).get("storage") or "")
            if not existing:
                raise AddonError(
                    "Could not read the retained PostgreSQL PVC size; "
                    "refusing to apply the manifest."
                )
    size = validate_storage_size(existing or requested)
    if existing and existing != requested:
        ctx.console.note(
            f"Keeping PostgreSQL's existing volume size {existing} (requested {requested})."
        )
    return size


# -- CNPG (installs before ADR-043) -----------------------------------------------


def cnpg_cluster(ctx: AppContext) -> str:
    """The legacy CNPG cluster's name, or "". A failed lookup raises."""
    if not _name_if_present(ctx, "crd", "clusters.postgresql.cnpg.io", what="for CloudNativePG"):
        return ""
    return _name_if_present(
        ctx,
        "clusters.postgresql.cnpg.io",
        CNPG_CLUSTER,
        "-n",
        NAMESPACE,
        what="the CloudNativePG cluster",
    )


def remove_cnpg(ctx: AppContext, *, expected: bool) -> None:
    """Delete the CNPG cluster, AO's three Database objects and the CNPG PVC.

    Stops before anything replaces the database when a step cannot be confirmed.
    """
    if not _name_if_present(ctx, "crd", "clusters.postgresql.cnpg.io", what="for CloudNativePG"):
        if expected:
            raise AddonError("CloudNativePG CRD disappeared; refusing to replace PostgreSQL.")
        return
    if cnpg_cluster(ctx):
        deleted = _kubectl(
            ctx,
            "delete",
            "clusters.postgresql.cnpg.io",
            CNPG_CLUSTER,
            "-n",
            NAMESPACE,
            "--ignore-not-found",
            "--wait=true",
            "--timeout=180s",
        )
        if not deleted.ok:
            raise AddonError(
                "Could not delete the CloudNativePG cluster; refusing to replace PostgreSQL.",
                hint=output_of(deleted) or None,
            )
        if cnpg_cluster(ctx):
            raise AddonError("CloudNativePG cluster still exists; refusing to replace PostgreSQL.")
    if _name_if_present(ctx, "crd", "databases.postgresql.cnpg.io", what="CloudNativePG databases"):
        for database in CNPG_DATABASES:
            owner = _kubectl(
                ctx,
                "get",
                "databases.postgresql.cnpg.io",
                database,
                "-n",
                NAMESPACE,
                "--ignore-not-found",
                "-o",
                "jsonpath={.spec.cluster.name}",
            )
            if not owner.ok:
                raise AddonError(
                    f"Could not check CloudNativePG database {database}; "
                    "refusing to replace PostgreSQL.",
                    hint=output_of(owner) or None,
                )
            cluster = (owner.stdout or "").strip()
            if not cluster:
                continue
            if cluster != CNPG_CLUSTER:
                raise AddonError(
                    f"CloudNativePG database {database} belongs to {cluster}; "
                    "refusing to replace PostgreSQL."
                )
            deleted = _kubectl(
                ctx,
                "delete",
                "databases.postgresql.cnpg.io",
                database,
                "-n",
                NAMESPACE,
                "--wait=true",
                "--timeout=180s",
            )
            if not deleted.ok:
                raise AddonError(
                    f"Could not delete CloudNativePG database {database}; "
                    "refusing to replace PostgreSQL.",
                    hint=output_of(deleted) or None,
                )
    deleted = _kubectl(
        ctx,
        "delete",
        "pvc",
        CNPG_PVC,
        "-n",
        NAMESPACE,
        "--ignore-not-found",
        "--wait=true",
        "--timeout=180s",
    )
    if not deleted.ok:
        raise AddonError(
            "Could not delete the CloudNativePG PVC; refusing to replace PostgreSQL.",
            hint=output_of(deleted) or None,
        )


# -- reset (--force) ---------------------------------------------------------


def _absent(ctx: AppContext, resource: str) -> bool:
    """True only when the API answers that the resource does not exist."""
    result = _kubectl(ctx, "get", resource, "-n", NAMESPACE, "--ignore-not-found", "-o", "name")
    return bool(result.ok) and not (result.stdout or "").strip()


def reset_storage(ctx: AppContext, *, cnpg_expected: bool) -> None:
    """Empty AO's PostgreSQL for ``--force``: StatefulSet, pod, PVC, then CNPG."""
    _kubectl(
        ctx,
        "delete",
        "statefulset",
        STATEFULSET,
        "-n",
        NAMESPACE,
        "--ignore-not-found",
        "--wait=true",
    )
    # Check what is left rather than the exit code: `kubectl wait` on a pod
    # that is already gone fails on some kubectl versions.
    _kubectl(ctx, "wait", "--for=delete", f"pod/{POD}", "-n", NAMESPACE, "--timeout=180s")
    for resource in (f"statefulset/{STATEFULSET}", f"pod/{POD}"):
        if not _absent(ctx, resource):
            raise AddonError(
                f"{resource} is still present or could not be checked; refusing to delete its PVC."
            )
    if not _absent(ctx, f"pvc/{PVC}"):
        _kubectl(ctx, "delete", "pvc", PVC, "-n", NAMESPACE, "--wait=false")
        gone = _kubectl(
            ctx, "wait", "--for=delete", f"pvc/{PVC}", "-n", NAMESPACE, "--timeout=180s"
        )
        if not gone.ok:
            raise AddonError("PostgreSQL PVC did not finish deleting; refusing to recreate AO.")
    remove_cnpg(ctx, expected=cnpg_expected)


# -- Secrets -------------------------------------------------------------------


def legacy_secrets_present(ctx: AppContext) -> bool:
    return any(
        kubectl.exists(ctx.runner, "secret", name, "-n", NAMESPACE) for name in LEGACY_SECRETS
    )


def delete_legacy_secrets(ctx: AppContext) -> None:
    _kubectl(ctx, "delete", "secret", *LEGACY_SECRETS, "-n", NAMESPACE, "--ignore-not-found")


def _secret_value(ctx: AppContext, name: str, key: str) -> str:
    escaped = key.replace(".", "\\.")
    encoded = kubectl.jsonpath(
        ctx.runner, "secret", name, "-n", NAMESPACE, path=f"{{.data.{escaped}}}"
    )
    if not encoded:
        return ""
    try:
        return base64.b64decode(encoded).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return ""


def _new_password() -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(32))


def database_secrets_manifest(password: str) -> str:
    documents: List[Dict[str, Any]] = [
        {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {"name": name, "namespace": NAMESPACE},
            "type": "kubernetes.io/basic-auth",
            "stringData": {
                "database": database,
                "host": SERVICE_HOST,
                "password": password,
                "port": "5432",
                "username": "orchestrator",
            },
        }
        for name, database in DATABASE_SECRETS.items()
    ]
    return json.dumps({"apiVersion": "v1", "kind": "List", "items": documents})


def ensure_database_secrets(ctx: AppContext) -> None:
    """Reuse the existing password so the database and the Secrets never disagree."""
    password = _secret_value(ctx, "orchestrator-postgres-secret", "password") or _new_password()
    applied = kubectl.apply_stdin(ctx.runner, database_secrets_manifest(password))
    if not applied.ok:
        raise AddonError("Could not write AO's PostgreSQL Secrets", hint=output_of(applied) or None)


# -- manifest, TLS and databases -----------------------------------------------------


def apply_manifest(ctx: AppContext, aap_namespace: str) -> None:
    chosen_image = image(ctx, aap_namespace)
    chosen_class = storage_class(ctx)
    size = storage_size(ctx, requested_storage_size(ctx))
    if chosen_image == IMAGE_FALLBACK:
        ctx.console.info(f"PostgreSQL image: {chosen_image}")
    else:
        ctx.console.info(f"PostgreSQL image: {chosen_image.split('/', 1)[-1]} (the one AAP runs)")
    manifest = manifests.render(
        "postgres.yaml",
        {
            "NAMESPACE": NAMESPACE,
            "STORAGE_CLASS": chosen_class,
            "STORAGE_SIZE": size,
            "POSTGRES_IMAGE": chosen_image,
        },
    )
    applied = kubectl.apply_stdin(ctx.runner, manifest)
    if not applied.ok:
        raise AddonError(
            "Failed to apply the PostgreSQL manifests.", hint=output_of(applied) or None
        )


def bundle_ca(ctx: AppContext) -> str:
    return kubectl.jsonpath(
        ctx.runner, "configmap", CA_BUNDLE, "-n", NAMESPACE, path="{.data.service-ca\\.crt}"
    )


def sync_ca(ctx: AppContext) -> Optional[bool]:
    """Copy the service-ca CA into the Secret the CR names.

    True when the Secret changed, False when it already matched, None when
    service-ca has not published a CA yet. A failed write raises.
    """
    ca = bundle_ca(ctx)
    if not ca:
        return None
    if _secret_value(ctx, CA_SECRET, "ca.crt") == ca:
        return False
    manifest = json.dumps(
        {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {"name": CA_SECRET, "namespace": NAMESPACE},
            "type": "Opaque",
            "stringData": {"ca.crt": ca},
        }
    )
    applied = kubectl.apply_stdin(ctx.runner, manifest)
    if not applied.ok:
        raise AddonError(
            f"Could not write the PostgreSQL CA to {CA_SECRET}.", hint=output_of(applied) or None
        )
    return True


def restart_clients(ctx: AppContext) -> None:
    """Restart AO's workloads, which read the CA Secret only when they start.

    A failed list raises: the Secret is already updated, so a later enable
    would not retry the restart.
    """
    listed = _kubectl(ctx, "get", "deployment", "-n", NAMESPACE, "-o", "name")
    if not listed.ok:
        raise AddonError(
            "Could not list AO deployments to restart them for the renewed PostgreSQL CA",
            hint=f"Run: kubectl rollout restart deployment -n {NAMESPACE}",
        )
    for deployment in (listed.stdout or "").split():
        if deployment.endswith("-operator-controller-manager"):
            continue
        if "/automation-orchestrator-" not in deployment:
            continue
        restarted = _kubectl(ctx, "rollout", "restart", deployment, "-n", NAMESPACE)
        if not restarted.ok:
            raise AddonError(
                f"Could not restart {deployment}",
                hint=f"Run: kubectl rollout restart deployment -n {NAMESPACE}",
            )


def ensure_ca(ctx: AppContext, *, sleep: Sleep = time.sleep, attempts: int = 60) -> None:
    """Wait for service-ca to issue the certificate, then copy its CA."""
    for attempt in range(attempts):
        if bundle_ca(ctx) and kubectl.exists(ctx.runner, "secret", TLS_SECRET, "-n", NAMESPACE):
            break
        if attempt + 1 < attempts:
            sleep(2)
    else:
        raise AddonError(
            "service-ca did not issue the PostgreSQL certificate within 2 minutes.",
            hint="Check: kubectl get pods -n openshift-service-ca",
        )
    changed = sync_ca(ctx)
    ctx.console.success("PostgreSQL TLS certificate issued by service-ca")
    # A fresh install has no AO pods yet, so this restarts nothing.
    if changed:
        restart_clients(ctx)


def wait_ready(ctx: AppContext) -> None:
    result = _kubectl(
        ctx, "rollout", "status", f"statefulset/{STATEFULSET}", "-n", NAMESPACE, "--timeout=10m"
    )
    if not result.ok:
        raise AddonError(
            "PostgreSQL not ready after 10 minutes.",
            hint=f"Check: kubectl describe pod {POD} -n {NAMESPACE}",
        )


def _psql(ctx: AppContext, sql: str, *, flags: str = "-tAc") -> Any:
    return _kubectl(ctx, "exec", "-n", NAMESPACE, POD, "--", "psql", "-U", "postgres", flags, sql)


def database_exists(ctx: AppContext, name: str) -> bool:
    result = _psql(ctx, f"SELECT 1 FROM pg_database WHERE datname='{name}'")
    return bool(result.ok) and (result.stdout or "").strip() == "1"


def ensure_databases(ctx: AppContext) -> None:
    for name in DATABASES:
        if database_exists(ctx, name):
            continue
        ctx.console.info(f"Creating PostgreSQL database: {name}")
        _psql(ctx, f'CREATE DATABASE "{name}" OWNER orchestrator', flags="-c")
    missing = [name for name in DATABASES if not database_exists(ctx, name)]
    if missing:
        raise AddonError(f"PostgreSQL database {missing[0]} was not created.")
    ctx.console.success("PostgreSQL databases ready (" + ", ".join(DATABASES) + ")")


def reconcile(ctx: AppContext, aap_namespace: str) -> None:
    """On a running AO: reapply postgres.yaml and pick up a rotated CA.

    Skipped when there is no StatefulSet. The caller skips CNPG installs, which
    share the Service name.
    """
    if not kubectl.exists(ctx.runner, "statefulset", STATEFULSET, "-n", NAMESPACE):
        return
    try:
        apply_manifest(ctx, aap_namespace)
        wait_ready(ctx)
        ctx.console.success("PostgreSQL up to date")
    except AddonError as exc:
        ctx.console.warn(
            f"Could not update PostgreSQL ({exc.message}); check: "
            f"kubectl describe statefulset {STATEFULSET} -n {NAMESPACE}"
        )
    try:
        changed = sync_ca(ctx)
    except AddonError:
        ctx.console.warn(f"Could not check the PostgreSQL CA in {CA_SECRET}")
        return
    if changed:
        ctx.console.success("PostgreSQL CA renewed by service-ca; restarting AO to trust it")
        restart_clients(ctx)
