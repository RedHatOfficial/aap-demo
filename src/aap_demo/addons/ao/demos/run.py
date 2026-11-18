"""Provision AAP's demo templates and import AO's demo workflows. Ports deploy.sh.

``provision_aap_demos`` and ``sync_ao_demos`` started the scripts as child
processes with tokens in argv. Here the modules run in-process: tokens never
reach a command line, and the TLS context trusts the cluster ingress CA.
"""

from __future__ import annotations

import contextlib
import io
import ssl
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, List, Optional

from aap_demo.addons.ao import llm as llm_mod
from aap_demo.addons.ao import wiring
from aap_demo.addons.ao.api import AoClient, Http, aap_token, quote
from aap_demo.addons.ao.demos import fleet_workflow, import_demos, provision
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError

DEMOS_REPOSITORY = "https://github.com/ansible-tmm/aap-orchestrator-demos"
DEMOS_REF = "abcc1a1482a"
CONTROL_REPOSITORY = "https://github.com/RedHatOfficial/aap-demo.git"
SYNC_API_URL = "https://router-internal-default.openshift-ingress.svc.cluster.local/api/v1"
#: provision exits 2 when AAP has no license and the AO sync job cannot run.
NO_LICENSE = 2


@dataclass
class Ids:
    """AO records the wiring created, looked up by name."""

    aap_credential: str = ""
    aap_integration: str = ""
    mcp_credential: str = ""
    mcp_integration: str = ""
    agent_credential: str = ""
    agent_integration: str = ""
    agent_model: str = ""
    project: str = ""

    @property
    def aap_ready(self) -> bool:
        return bool(self.aap_credential and self.aap_integration)

    @property
    def agent_ready(self) -> bool:
        return bool(self.agent_credential and self.agent_integration and self.agent_model)


def _id(ao: AoClient, path: str, name: str) -> str:
    found = ao.find(path, name=name)
    return str(found.get("id")) if found else ""


def lookup(ctx: AppContext, ao: AoClient) -> Ids:
    ids = Ids(
        aap_credential=_id(
            ao, f"/credentials?name={quote(wiring.AAP_CREDENTIAL)}&limit=100", wiring.AAP_CREDENTIAL
        ),
        aap_integration=wiring.find_integration(ao, wiring.AAP_INTEGRATION),
        mcp_credential=_id(
            ao, f"/credentials?name={quote(wiring.MCP_CREDENTIAL)}&limit=100", wiring.MCP_CREDENTIAL
        ),
        mcp_integration=wiring.find_integration(ao, wiring.MCP_INTEGRATION),
        project=ao.default_project(),
    )
    settings = llm_mod.settings(ctx)
    if settings.provider != "none":
        ids.agent_credential = _id(
            ao, f"/credentials?name={quote(settings.integration)}&limit=100", settings.integration
        )
        ids.agent_integration = wiring.find_integration(ao, settings.integration)
        if ids.agent_integration:
            found = ao.find(
                f"/integrations/{ids.agent_integration}/models?limit=50", model_id=settings.model
            )
            ids.agent_model = str(found.get("id")) if found else ""
        if (ids.agent_credential or ids.agent_integration) and not ids.agent_ready:
            ctx.console.warn(
                "AO LLM credential, integration, or model is incomplete; "
                "skipping agent binding for the demo workflows"
            )
    return ids


def _run(ctx: AppContext, main: Callable[..., int], argv: List[str], **kwargs: object) -> int:
    """Run a demo module, sending its prints to the console."""
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = main(argv, **kwargs)
    except SystemExit as exc:
        code = int(exc.code) if isinstance(exc.code, int) else 1
    except (OSError, ValueError, RuntimeError) as exc:
        out.write(f"ERROR: {exc}\n")
        code = 1
    for line in out.getvalue().splitlines():
        if line.strip():
            ctx.console.info(line)
    return code


@dataclass
class Result:
    """Whether the AAP-side sync ran, so the direct AO import can be skipped."""

    synced: bool


def provision_aap(
    ctx: AppContext,
    ao: AoClient,
    http: Http,
    context: ssl.SSLContext,
    routes: wiring.Routes,
    aap_namespace: str,
    ids: Ids,
    *,
    fleet_host: str = "",
) -> Result:
    """AAP projects and job templates, plus the AAP job that syncs AO's workflows."""
    password = wiring._secret(ctx, "aap-admin-password", aap_namespace)
    token = (
        aap_token(http, routes.aap, password, description="aap-demo AO template provisioning")
        if routes.aap and password
        else ""
    )
    if not token:
        if fleet_host:
            raise AddonError(
                "AAP route or credentials are unavailable; "
                "the Fleet integration cannot be configured."
            )
        ctx.console.warn("AAP demo template provisioning deferred (AAP credentials not ready)")
        return Result(synced=False)
    if fleet_host and not ids.aap_ready:
        raise AddonError(
            "AO credentials or the AAP integration are unavailable; "
            "Fleet workflows cannot be configured."
        )
    argv = ["--route", routes.aap, "--token", token]
    with tempfile.TemporaryDirectory() as scratch:
        service_status = Path(scratch) / "service"
        manual_status = Path(scratch) / "manual"
        if fleet_host:
            argv += [
                "--fleet-host",
                fleet_host,
                "--fleet-service-status-file",
                str(service_status),
                "--fleet-manual-status-file",
                str(manual_status),
            ]
        if ids.aap_ready:
            argv += [
                "--ao-api-url",
                str(ctx.env.get("AO_SYNC_API_URL") or SYNC_API_URL),
                "--ao-api-host",
                routes.ao,
                "--ao-token",
                ao.token,
                "--ao-credential-id",
                ids.aap_credential,
                "--ao-integration-id",
                ids.aap_integration,
                "--control-repository",
                str(ctx.env.get("AO_SYNC_REPOSITORY") or CONTROL_REPOSITORY),
                "--control-branch",
                str(ctx.env.get("AO_SYNC_BRANCH") or "main"),
                "--ao-demo-ref",
                str(ctx.env.get("AO_DEMOS_REF") or DEMOS_REF),
                "--ao-demo-repository",
                str(ctx.env.get("AO_DEMOS_REPOSITORY") or f"{DEMOS_REPOSITORY}.git"),
            ]
            if ids.agent_ready:
                argv += [
                    "--ao-agent-credential-id",
                    ids.agent_credential,
                    "--ao-agent-integration-id",
                    ids.agent_integration,
                    "--ao-agent-model-id",
                    ids.agent_model,
                ]
        else:
            ctx.console.warn("AAP AO sync job deferred (AO credentials not ready)")
        code = _run(ctx, provision.main, argv, context=context)
        if code != 0:
            if fleet_host:
                raise AddonError(
                    "Fleet integration provisioning failed; product demos setup cannot continue."
                )
            if code == NO_LICENSE:
                ctx.console.info("Continuing with direct AO workflow import.")
            else:
                raise AddonError(
                    "AAP demo provisioning or the AO sync job failed",
                    hint="The provisioning output is above.",
                )
            return Result(synced=False)
        if not ids.aap_ready:
            return Result(synced=False)
        if fleet_host:
            fleet_argv = [
                "--route",
                routes.ao,
                "--credential-id",
                ids.aap_credential,
                "--integration-id",
                ids.aap_integration,
            ]
            if _status(service_status) == "ready":
                fleet_argv.append("--include-service")
            else:
                ctx.console.warn(
                    "Fleet disk-and-service workflow unavailable: "
                    "the Product Demos service template is not ready"
                )
            if _status(manual_status) == "ready":
                fleet_argv.append("--include-disk-demo-101")
            else:
                ctx.console.warn(
                    "Fleet disk-demo-101 unavailable: the manual-intervention template is not ready"
                )
            if _run(ctx, fleet_workflow.main, fleet_argv, token=ao.token, context=context) != 0:
                raise AddonError("Fleet AO workflow synchronization failed")
    return Result(synced=True)


def _status(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def import_direct(
    ctx: AppContext, ao: AoClient, context: ssl.SSLContext, routes: wiring.Routes, ids: Ids
) -> None:
    """Import AO's demo workflows straight into AO when the AAP sync did not run."""
    if not ids.aap_ready:
        ctx.console.warn("AO demo synchronization deferred (AO credentials not ready)")
        return
    argv = [
        "--route",
        routes.ao,
        "--token",
        ao.token,
        "--aap-credential-id",
        ids.aap_credential,
        "--aap-integration-id",
        ids.aap_integration,
        "--repository",
        str(ctx.env.get("AO_DEMOS_REPOSITORY") or DEMOS_REPOSITORY),
        "--ref",
        str(ctx.env.get("AO_DEMOS_REF") or DEMOS_REF),
    ]
    if ids.agent_ready:
        argv += [
            "--agent-credential-id",
            ids.agent_credential,
            "--agent-integration-id",
            ids.agent_integration,
            "--agent-model-id",
            ids.agent_model,
        ]
    if ids.mcp_credential and ids.mcp_integration:
        argv += [
            "--mcp-credential-id",
            ids.mcp_credential,
            "--mcp-integration-id",
            ids.mcp_integration,
        ]
    if ids.project:
        argv += ["--project-id", ids.project]
    if _run(ctx, import_demos.main, argv, context=context) != 0:
        raise AddonError("AO demo workflow import failed", hint="The import output is above.")


def run(
    ctx: AppContext,
    ao: AoClient,
    http: Http,
    context: ssl.SSLContext,
    routes: wiring.Routes,
    aap_namespace: str,
    *,
    fleet_host: str = "",
) -> None:
    """Provision AAP's templates, then import AO's workflows if the sync did not.

    Unlike the Bash installer, a provisioning or import failure fails the enable
    (a #338 follow-up): a demo that silently did not load looks like success.
    AO still gets its workflows directly before a provisioning failure is raised.
    """
    if str(ctx.env.get("AO_IMPORT_DEMOS") or "1") == "0":
        return
    ids = lookup(ctx, ao)
    failure: Optional[AddonError] = None
    try:
        synced = provision_aap(
            ctx, ao, http, context, routes, aap_namespace, ids, fleet_host=fleet_host
        ).synced
    except AddonError as exc:
        if fleet_host:
            raise
        failure, synced = exc, False
    if not synced:
        import_direct(ctx, ao, context, routes, ids)
    if failure is not None:
        raise failure


__all__ = ["Ids", "lookup", "run"]
