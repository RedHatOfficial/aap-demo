"""Python addons. The bash tree under ``addons/`` is a different thing."""

from __future__ import annotations

from typing import Dict

from aap_demo.addons.fleet import FleetAddon
from aap_demo.core.errors import AddonError

_REGISTRY = {"fleet": FleetAddon()}


def names() -> list:
    return sorted(_REGISTRY)


def get(name: str) -> FleetAddon:
    addon = _REGISTRY.get(name)
    if addon is None:
        raise AddonError(f"unknown addon {name!r}; only fleet is implemented")
    return addon


def registry() -> Dict[str, object]:
    return dict(_REGISTRY)
