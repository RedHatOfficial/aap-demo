"""Automation Orchestrator, native (ADR-045).

``aap-demo enable ao`` installs or adopts AO in the same order as the frozen
``addons/ao/deploy.sh``: dependencies, then either the already-running path or
namespace, catalog, PostgreSQL, operator and instance, then local access,
wiring and the demo workflows.
"""

from __future__ import annotations

import argparse
import time
from typing import Callable, List

from aap_demo.addons.ao import admin, catalog, deps, instance, olm, postgres, wiring
from aap_demo.addons.ao.demos import run as demos
from aap_demo.addons.base import AddonKind
from aap_demo.addons.common.state import enabled_names, set_enabled_names
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError
from aap_demo.exec import kubectl

NAME = "ao"
NAMESPACE = postgres.NAMESPACE
CATALOG_ACCOUNT = "redhat-operators"
DELETE_ATTEMPTS = 60
DELETE_INTERVAL = 5
LEGACY_MESSAGE = (
    "Legacy PostgreSQL credentials exist; refusing to reset the database automatically."
)
RESET_HINT = "To replace the database and delete its data, run: aap-demo enable ao --force"

Sleep = Callable[[float], None]


class AoAddon:
    name = NAME
    kind: AddonKind = "native"
    public = True
    needs_cluster = True

    def __init__(self, *, sleep: Sleep = time.sleep) -> None:
        self.sleep = sleep

    # -- enable -----------------------------------------------------------------

    def enable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        aap_ns = ctx.namespace
        fleet_host = str(
            getattr(args, "fleet_host", "") or ctx.env.get("AAP_DEMO_FLEET_HOST") or ""
        )
        pull_secret = deps.prepare(ctx)
        force = bool(ctx.force)
        if force:
            postgres.validate_storage_size(postgres.requested_storage_size(ctx))
        cnpg = postgres.cnpg_cluster(ctx)
        replicas = instance.replica_count(ctx)
        ctx.console.info(
            "AO replica profile: 1 each (default local, non-HA)"
            if replicas == 1
            else "AO replica profile: 2 each (explicit higher-resource mode)"
        )
        host = instance.ingress_host(ctx, aap_ns)
        ctx.console.success(f"Ingress host: {host}")

        running = None if force else instance.already_running(ctx, channel=olm.channel(ctx))
        if running is not None:
            self._adopt(ctx, aap_ns, host=host, cnpg=cnpg, running=running)
        else:
            self._install(ctx, aap_ns, host=host, cnpg=cnpg, force=force, pull_secret=pull_secret)
        self._connect(ctx, aap_ns, fleet_host=fleet_host)
        _record(ctx)
        ctx.console.success("Automation Orchestrator enabled")
        return 0

    def _adopt(self, ctx: AppContext, aap_ns: str, *, host: str, cnpg: str, running: tuple) -> None:
        """An AO that is already up: refresh its config, keep its data."""
        requested = olm.requested_approval(ctx)
        if requested:
            olm.set_approval(ctx, requested)
        if not cnpg:
            # A CNPG install's database uses CNPG certificates; the current CR
            # points at the StatefulSet's service-ca host and would cut it off.
            instance.apply(ctx, host=host)
            postgres.reconcile(ctx, aap_ns)
        instance.wait_ready(ctx, sleep=self.sleep)
        ctx.console.success(
            f"Automation Orchestrator already running ({running[0]}/{running[1]} pods, "
            f"{olm.channel(ctx)} channel)"
        )
        ctx.console.info("Use aap-demo enable ao --force to reinstall.")
        if cnpg:
            ctx.console.info(
                "Its database is still in CloudNativePG, which aap-demo no longer uses."
            )
            ctx.console.info(
                "aap-demo enable ao --force moves AO to the new PostgreSQL and deletes AO's data."
            )

    def _install(
        self, ctx: AppContext, aap_ns: str, *, host: str, cnpg: str, force: bool, pull_secret: str
    ) -> None:
        ctx.console.info("Creating namespace and SCC grants...")
        kubectl.run(ctx.runner, "create", "namespace", NAMESPACE)
        # OLM runs the local catalog pod as a ServiceAccount named after the
        # CatalogSource; the namespace default account does not cover it.
        kubectl.run(ctx.runner, "create", "serviceaccount", CATALOG_ACCOUNT, "-n", NAMESPACE)
        for account in ("default", CATALOG_ACCOUNT):
            for scc in ("anyuid", "privileged"):
                catalog.grant_scc(ctx, scc, account, NAMESPACE)
        if not force:
            admin.ensure(ctx)
        ctx.console.success("Namespace ready")

        ctx.console.info("Checking AAP redhat-operators catalog (for index and fallback image)...")
        catalog.require_aap_catalog(ctx)
        state = catalog.Catalog(refresh=str(ctx.env.get("AO_REFRESH_CATALOG") or "") != "")
        catalog.ensure(ctx, state, sleep=self.sleep)
        if not catalog.package_in_catalog(ctx, NAMESPACE) and not catalog.try_fallback(
            ctx, state, sleep=self.sleep
        ):
            raise catalog.not_in_catalog(ctx, state)
        ctx.console.success(f"Operator package found in AO catalog ({olm.channel(ctx)})")

        ctx.console.info("Creating PostgreSQL for Automation Orchestrator...")
        if cnpg and not force:
            raise AddonError(
                "This AO keeps its database in CloudNativePG, which aap-demo no longer uses.",
                hint="To replace it with the new PostgreSQL, which deletes AO's data, run: "
                "aap-demo enable ao --force",
            )
        legacy = postgres.legacy_secrets_present(ctx)
        if legacy and not force:
            raise AddonError(
                LEGACY_MESSAGE,
                hint=RESET_HINT,
            )
        if force:
            if legacy:
                ctx.console.info("Recreating PostgreSQL to match the current secret names...")
                postgres.delete_legacy_secrets(ctx)
            ctx.console.info("Resetting PostgreSQL for a fresh database...")
            postgres.reset_storage(ctx, cnpg_expected=bool(cnpg))
        postgres.ensure_database_secrets(ctx)
        postgres.apply_manifest(ctx, aap_ns)
        postgres.ensure_ca(ctx, sleep=self.sleep)
        ctx.console.info("Waiting for PostgreSQL to be ready...")
        postgres.wait_ready(ctx)
        ctx.console.success("PostgreSQL ready")
        postgres.ensure_databases(ctx)

        mode = olm.approval(ctx)
        if force:
            olm.clear_for_force(ctx, aap_ns, sleep=self.sleep)
        olm.install(ctx, state, aap_ns, mode=mode, sleep=self.sleep)
        ctx.console.info("Waiting for operator to become available...")
        olm.wait_available(ctx, sleep=self.sleep)
        olm.link_pull_secret(ctx, pull_secret or None)

        if force:
            # The CR's admin Secret is read only when the database is created,
            # and --force just emptied it.
            admin.generate(ctx)
        instance.apply(ctx, host=host)
        instance.wait_ready(ctx, sleep=self.sleep)
        ctx.console.success("Automation Orchestrator operator and instance applied")

    def _connect(self, ctx: AppContext, aap_ns: str, *, fleet_host: str) -> None:
        instance.configure_local_access(ctx, aap_ns)
        instance.allow_aap_ingress(ctx, aap_ns)
        instance.show_access(ctx, password=admin.saved(ctx))
        session = wiring.wire(ctx, aap_ns, sleep=self.sleep)
        if session is not None:
            demos.run(
                ctx,
                session.ao,
                session.http,
                session.context,
                session.routes,
                aap_ns,
                fleet_host=fleet_host,
            )

    # -- disable ----------------------------------------------------------------

    def disable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        del args
        aap_ns = ctx.namespace
        ctx.console.info("Removing Automation Orchestrator...")
        if str(ctx.env.get("AO_PURGE_DATA") or "") not in ("", "0"):
            ctx.console.info("Purging retained AO database and credentials...")
            admin.forget(ctx)
            kubectl.run(
                ctx.runner, "delete", "secret", admin.SECRET, "-n", NAMESPACE, "--ignore-not-found"
            )
            postgres.reset_storage(ctx, cnpg_expected=bool(postgres.cnpg_cluster(ctx)))
        else:
            admin.save(ctx)
        instance.remove_finalizers(ctx)
        kubectl.run(
            ctx.runner, "delete", "automationorchestrator", "--all", "-n", NAMESPACE, "--wait=false"
        )
        olm.cleanup(ctx, aap_ns)
        catalog.remove(ctx)
        olm.cleanup_early_access(ctx)
        kubectl.run(ctx.runner, "delete", "namespace", NAMESPACE, "--wait=false")
        ctx.console.info("Waiting for namespace to terminate...")
        for attempt in range(DELETE_ATTEMPTS):
            if not kubectl.exists(ctx.runner, "namespace", NAMESPACE):
                break
            if attempt + 1 < DELETE_ATTEMPTS:
                self.sleep(DELETE_INTERVAL)
        else:
            raise AddonError(
                "Namespace still terminating after 5 minutes",
                hint=f"Check: kubectl get namespace {NAMESPACE}",
            )
        set_enabled_names(ctx, [n for n in enabled_names(ctx) if n != NAME], save=True)
        ctx.console.success("Automation Orchestrator removed")
        if kubectl.exists(ctx.runner, "namespace", "cnpg-system"):
            ctx.console.info(
                "CloudNativePG (cnpg-system) from an older AO install was left installed. "
                "AO no longer uses it."
            )
        return 0


def _record(ctx: AppContext) -> None:
    names: List[str] = enabled_names(ctx)
    if NAME not in names:
        set_enabled_names(ctx, [*names, NAME], save=True)


__all__ = ["AoAddon"]
