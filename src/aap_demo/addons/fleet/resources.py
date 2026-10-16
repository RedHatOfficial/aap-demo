"""Packaged playbooks and the container entrypoint."""

from __future__ import annotations

from importlib.resources import files
from pathlib import Path

_PACKAGE = "aap_demo.addons.fleet"


def packaged(name: str) -> Path:
    """Absolute path of a file shipped next to this package."""
    return Path(str(files(_PACKAGE).joinpath(name)))


def playbook(name: str) -> Path:
    return packaged(f"playbooks/{name}")


def entrypoint() -> Path:
    return packaged("entrypoint.sh")


def requirements() -> Path:
    return packaged("requirements.yml")


def read_text(name: str) -> str:
    return files(_PACKAGE).joinpath(name).read_text(encoding="utf-8")
