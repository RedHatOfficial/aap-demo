"""What AO needs before it installs. Replaces ao_shell.prepare (ADR-040, ADR-045).

- With the ``ollama`` provider, Ollama running on the host with a model, and a
  path to it from the cluster (ADR-046). Checked first, since it installs nothing.
- The mcp-server addon, recorded in ``addons.enabled``. An MCP Server that is
  already running is adopted instead of installed again.
- A note when no product demos are enabled, since AO links its workflows to
  AAP job templates when it installs.
"""

from __future__ import annotations

import argparse
from typing import List

from aap_demo.addons.ao import host_ollama, llm
from aap_demo.addons.common import mcp
from aap_demo.addons.common.state import enabled_names, set_enabled_names
from aap_demo.cluster import pull_secret
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError


def dependencies() -> List[str]:
    return ["mcp-server"]


def prepare(ctx: AppContext) -> str:
    """Install AO's dependencies. Returns the pull secret path, or ""."""
    settings = llm.settings(ctx)
    if settings.provider == "ollama":
        host_ollama.prepare(ctx, settings.base_url)
    if not any(name.startswith("product-demo") for name in enabled_names(ctx)):
        ctx.console.note(
            "No product demos are enabled. AO links its workflows to AAP job templates "
            "when it installs. To include them, run aap-demo enable product-demos, then "
            "aap-demo enable ao again."
        )
    # Imported here: the registry imports this package.
    from aap_demo.addons import get

    for name in dependencies():
        if name in enabled_names(ctx):
            continue
        if name == "mcp-server":
            present = mcp.installed(ctx)
            if present is None:
                raise AddonError(
                    "Could not determine whether MCP Server is installed",
                    hint="Check access to the MCP server resource and deployment in "
                    f"namespace {ctx.namespace}, then retry.",
                )
            if present:
                set_enabled_names(ctx, [*enabled_names(ctx), name], save=True)
                ctx.console.note("Using the existing MCP Server addon.")
                continue
        ctx.console.note(f"AO needs the {name} addon. Enabling it first.")
        get(name).enable(ctx, argparse.Namespace(addon=name, addon_args=[]))
    found = pull_secret.discover(ctx)
    return str(found) if found is not None else ""
