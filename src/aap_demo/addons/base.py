"""What every addon provides to the CLI. See ADR-040."""

from __future__ import annotations

import argparse
from typing import Literal, Protocol, runtime_checkable

from aap_demo.core.context import AppContext

#: ``native`` addons are Python. ``legacy`` addons run a bundled bash installer.
AddonKind = Literal["native", "legacy"]


@runtime_checkable
class Addon(Protocol):
    #: The name ``aap-demo enable`` takes.
    name: str
    kind: AddonKind
    #: Listed by ``aap-demo enable`` with no name. Helper installers, such as one
    #: product-demos domain, are enabled by name but not listed.
    public: bool
    #: The CLI sets up the kubeconfig and checks the cluster before calling the addon.
    needs_cluster: bool

    def enable(self, ctx: AppContext, args: argparse.Namespace) -> int: ...

    def disable(self, ctx: AppContext, args: argparse.Namespace) -> int: ...
