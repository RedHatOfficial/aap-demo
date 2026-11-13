"""Addon registry: one table of every addon the new command can enable.

``fleet`` is native Python. Product demos, EDA Playground, AO, mcp-server and
ollama run their bundled bash installers (``kind == "legacy"``). Any other name
is an error that points at the older command. See ADR-040.
"""

from __future__ import annotations

from typing import Dict, Literal, Optional, overload

from aap_demo.addons import ao_shell
from aap_demo.addons.base import Addon
from aap_demo.addons.fleet import FleetAddon
from aap_demo.addons.shell import BUNDLED_ADDON_DIRS, ShellAddon
from aap_demo.core.errors import AddonError

_FLEET = FleetAddon()
_EDA_PLAYGROUND = ShellAddon(
    "eda-playground",
    required_tools=("bash", "curl", "jq", "kubectl", "base64"),
    delete_tools=("bash", "curl", "jq", "kubectl", "base64"),
    wire_after_enable=False,
    dependencies=(),
    state_dir_env="EDA_PLAYGROUND_STATE_DIR",
)

_KUBE_TOOLS = ("bash", "curl", "jq", "kubectl")
_AO = ShellAddon(
    "ao",
    required_tools=(*_KUBE_TOOLS, "base64", "python3"),
    delete_tools=("bash", "jq", "kubectl"),
    wire_after_enable=False,
    dependencies=(),
    self_wire=True,
    prepare=ao_shell.prepare,
)
_MCP_SERVER = ShellAddon(
    "mcp-server",
    required_tools=_KUBE_TOOLS,
    delete_tools=("bash", "kubectl"),
    wire_after_enable=False,
    dependencies=(),
    self_wire=True,
)
_OLLAMA = ShellAddon(
    "ollama",
    required_tools=_KUBE_TOOLS,
    delete_tools=("bash", "kubectl"),
    wire_after_enable=False,
    dependencies=(),
    self_wire=True,
)
_CUSTOM_SHELL = {a.name: a for a in (_EDA_PLAYGROUND, _AO, _MCP_SERVER, _OLLAMA)}

_REGISTRY: Dict[str, Addon] = {
    _FLEET.name: _FLEET,
    **{name: _CUSTOM_SHELL.get(name) or ShellAddon(name) for name in BUNDLED_ADDON_DIRS},
}

#: How to run the bash command next to this one, for addons not ported yet.
OLDER_COMMAND_GUIDE = (
    "https://github.com/RedHatOfficial/aap-demo/blob/main/docs/guides/older-command.md"
)


def names() -> list:
    """Addons ``enable`` prints when no name is given."""
    return sorted(name for name, addon in _REGISTRY.items() if addon.public)


def needs_cluster(name: Optional[str]) -> bool:
    """True when enable/disable has to talk to the cluster before it starts."""
    addon = _REGISTRY.get(name) if name else None
    return bool(addon and addon.needs_cluster)


@overload
def get(name: Literal["fleet"]) -> FleetAddon: ...


@overload
def get(name: str) -> Addon: ...


def get(name: str) -> Addon:
    addon = _REGISTRY.get(name)
    if addon is not None:
        return addon
    available = ", ".join(names())
    raise AddonError(
        f"unknown addon {name!r}; implemented addons: {available}",
        hint=(
            f"The older bash command still installs it: aap-demo-v1 enable {name}. "
            f"To set that command up, see {OLDER_COMMAND_GUIDE}"
        ),
    )


def registry() -> Dict[str, Addon]:
    """Every addon by name, public or not."""
    return dict(_REGISTRY)
