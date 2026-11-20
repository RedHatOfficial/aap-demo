"""AO's checked-in manifests, shared with the frozen Bash installer (ADR-045)."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Mapping

from aap_demo.core.errors import AddonError

#: ``__NAME__`` placeholders in addons/ao/manifests.
_PLACEHOLDER = re.compile(r"__[A-Z][A-Z0-9_]*__")


def directory() -> Path:
    # Imported here: shell imports the addon registry, which imports this package.
    from aap_demo.addons.shell import scripts_root

    return scripts_root() / "ao" / "manifests"


def render(name: str, values: Mapping[str, str]) -> str:
    """The manifest with every placeholder replaced. A leftover one is a bug."""
    path = directory() / name
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise AddonError(f"could not read AO manifest {name}", hint=str(exc)) from exc
    for key, value in values.items():
        text = text.replace(f"__{key}__", value)
    body = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
    leftover = sorted(set(_PLACEHOLDER.findall(body)))
    if leftover:
        raise AddonError(f"AO manifest {name} has unfilled values: {', '.join(leftover)}")
    return text
