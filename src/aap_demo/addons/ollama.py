"""``aap-demo disable ollama``: remove the in-cluster Ollama of earlier releases.

AO now uses Ollama on the host (ADR-046), so ``enable ollama`` only explains
that. ``disable`` deletes what the old installer created, the same objects its
``--delete`` mode removed. Kept for one release.
"""

from __future__ import annotations

import argparse

from aap_demo.addons.ao.host_ollama import INSTALL_HINT, OLD_NAMESPACE
from aap_demo.addons.base import AddonKind
from aap_demo.addons.common.state import enabled_names, set_enabled_names
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError
from aap_demo.exec import kubectl

NAME = "ollama"
CLUSTER_ROLE_BINDING = "aap-demo-ollama-anyuid"


class OllamaCleanup:
    name = NAME
    kind: AddonKind = "native"
    public = False
    needs_cluster = True

    def enable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        del ctx, args
        raise AddonError(
            "aap-demo no longer installs Ollama in the cluster. AO uses Ollama on the host.",
            hint=f"{INSTALL_HINT} See docs/adr/046-ao-host-ollama.md.",
        )

    def disable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        del args
        ctx.console.info("Removing the in-cluster Ollama from an earlier aap-demo...")
        for argv in (
            ("namespace", OLD_NAMESPACE),
            ("clusterrolebinding", CLUSTER_ROLE_BINDING),
        ):
            result = kubectl.run(ctx.runner, "delete", *argv, "--ignore-not-found")
            if not result.ok:
                raise AddonError(
                    f"Could not delete {argv[0]} {argv[1]}",
                    hint=(result.stderr or "").strip() or None,
                )
        names = enabled_names(ctx)
        if NAME in names:
            set_enabled_names(ctx, [n for n in names if n != NAME], save=True)
        ctx.console.success("In-cluster Ollama removed")
        return 0


__all__ = ["OllamaCleanup"]
