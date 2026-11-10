"""Addon registry.

``fleet`` is implemented in Python. Product demos run the bash installers
under ``addons/``. Every other name is still an error.
"""

from __future__ import annotations

from typing import Dict, Literal, Optional, Union, overload

from aap_demo.addons.fleet import FleetAddon
from aap_demo.addons.shell import PUBLIC_SHELL_ADDONS, SHELL_ADDONS, ShellAddon
from aap_demo.core.errors import AddonError

_REGISTRY = {"fleet": FleetAddon()}

#: How to run the bash command next to this one, for addons not ported yet.
OLDER_COMMAND_GUIDE = (
    "https://github.com/RedHatOfficial/aap-demo/blob/main/docs/guides/older-command.md"
)


def names() -> list:
    """Addons ``enable`` prints when no name is given."""
    return sorted({*_REGISTRY, *PUBLIC_SHELL_ADDONS})


def needs_cluster(name: Optional[str]) -> bool:
    """True when enable/disable has to talk to the cluster before it starts."""
    return bool(name) and (name in _REGISTRY or name in SHELL_ADDONS)


@overload
def get(name: Literal["fleet"]) -> FleetAddon: ...


@overload
def get(name: str) -> Union[FleetAddon, ShellAddon]: ...


def get(name: str) -> Union[FleetAddon, ShellAddon]:
    if name in _REGISTRY:
        return _REGISTRY[name]
    if name in SHELL_ADDONS:
        return ShellAddon(name)
    available = ", ".join(names())
    raise AddonError(
        f"unknown addon {name!r}; implemented addons: {available}",
        hint=(
            f"The older bash command still installs it: aap-demo-v1 enable {name}. "
            f"To set that command up, see {OLDER_COMMAND_GUIDE}"
        ),
    )


def registry() -> Dict[str, FleetAddon]:
    return dict(_REGISTRY)
