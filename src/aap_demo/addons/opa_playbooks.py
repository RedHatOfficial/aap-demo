"""Locate the OPA playbooks in a checkout or an installed wheel."""

from __future__ import annotations

from pathlib import Path
from typing import Dict

import aap_demo
from aap_demo.core.errors import AddonError

_NAMES = (
    "bootstrap.yml",
    "load-policies.yml",
    "test-policies.yml",
    "clear-policies.yml",
    "demo-policy.yml",
)


def _candidates() -> tuple[Path, ...]:
    package_file = Path(str(aap_demo.__file__ or "")).resolve()
    package_root = package_file.parent
    checkout_root = Path(__file__).resolve().parents[3]
    return (
        checkout_root / "addons" / "opa" / "playbooks",
        package_root / "bundled" / "addons" / "opa" / "playbooks",
    )


def playbooks_root() -> Path:
    """Return the first complete OPA playbook directory."""
    for root in _candidates():
        if all((root / name).is_file() for name in _NAMES):
            return root
    paths = ", ".join(str(root) for root in _candidates())
    raise AddonError("OPA playbooks are not packaged", hint=f"Checked: {paths}")


def playbook_files() -> Dict[str, str]:
    """Read all playbooks needed by the native OPA bootstrap job."""
    root = playbooks_root()
    return {name: (root / name).read_text(encoding="utf-8") for name in _NAMES}
