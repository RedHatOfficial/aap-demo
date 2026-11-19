"""Read-only detection of the MCP server installed by the addon."""

from __future__ import annotations

from typing import Optional

from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError

PROBE_TIMEOUT_SECONDS = 10.0


def installed(ctx: AppContext) -> Optional[bool]:
    """Whether the named MCP CR or deployment exists; None if the check failed.

    An existing resource is not a readiness check. Check both resources because
    AO accepts either, and the CR can exist before its deployment is created.
    """
    unknown = False
    for kind in ("ansiblemcpservers.mcpserver.ansible.com", "deployment"):
        try:
            result = ctx.runner.run(
                [
                    "kubectl",
                    "get",
                    kind,
                    "aap-mcp-server",
                    "-n",
                    ctx.namespace,
                    "--ignore-not-found",
                    "-o",
                    "name",
                ],
                env=ctx.kube_env(),
                timeout=PROBE_TIMEOUT_SECONDS,
            )
        except (AapDemoError, OSError):
            unknown = True
            continue
        if result.ok:
            if result.stdout.strip():
                return True
        elif kind != "deployment" and (
            "the server doesn't have a resource type" in result.stderr.lower()
            or "the server could not find the requested resource" in result.stderr.lower()
        ):
            # The MCP CRD is not installed on this cluster.
            continue
        else:
            unknown = True
    return None if unknown else False
