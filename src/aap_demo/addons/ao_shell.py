"""Get ready to run the bundled Automation Orchestrator installer (ADR-040).

The bash command did these steps in ``aap-demo.sh`` before it ran
``addons/ao/deploy.sh``. Here they read the environment and don't prompt, so
nothing is written to the bash command's config file:

- ``AO_LLM_PROVIDER`` picks the LLM: ``ollama`` (the default), ``external``,
  or ``none``. With ``ollama``, the ollama addon is enabled first.
- The mcp-server addon is enabled first, so it is recorded in ``addons.enabled``.
- With no product demos enabled, a note says to enable them before AO.
- The pull secret this command found is passed on as ``PULL_SECRET_PATH``.
"""

from __future__ import annotations

import argparse
from typing import Dict, List

from aap_demo.addons.common.state import enabled_names
from aap_demo.cluster import pull_secret
from aap_demo.core.context import AppContext
from aap_demo.core.errors import UsageError

LLM_PROVIDERS = ("ollama", "external", "none")
DEFAULT_LLM_PROVIDER = "ollama"


def llm_provider(ctx: AppContext) -> str:
    provider = str(ctx.env.get("AO_LLM_PROVIDER", "") or "").strip() or DEFAULT_LLM_PROVIDER
    if provider not in LLM_PROVIDERS:
        raise UsageError(
            f"AO_LLM_PROVIDER={provider} is not a known provider",
            hint="Use ollama, external, or none.",
        )
    return provider


def dependencies(provider: str) -> List[str]:
    return ["mcp-server", "ollama"] if provider == "ollama" else ["mcp-server"]


def prepare(ctx: AppContext) -> Dict[str, str]:
    provider = llm_provider(ctx)
    if not any(name.startswith("product-demo") for name in enabled_names(ctx)):
        ctx.console.note(
            "No product demos are enabled. AO links its workflows to AAP job templates "
            "when it installs. To include them, run aap-demo enable product-demos, then "
            "aap-demo enable ao again."
        )
    # Imported here: the registry imports this module.
    from aap_demo.addons import get

    for name in dependencies(provider):
        if name in enabled_names(ctx):
            continue
        ctx.console.note(f"AO needs the {name} addon. Enabling it first.")
        get(name).enable(ctx, argparse.Namespace(addon=name, addon_args=[]))

    env = {"AO_LLM_PROVIDER": provider}
    secret = pull_secret.discover(ctx)
    if secret is not None:
        env["PULL_SECRET_PATH"] = str(secret)
    return env


__all__ = ["DEFAULT_LLM_PROVIDER", "LLM_PROVIDERS", "dependencies", "llm_provider", "prepare"]
