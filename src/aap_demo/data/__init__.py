"""Packaged YAML the tool applies to a cluster (design §2.2: ``config/**`` →
``src/aap_demo/data/**``, loaded via ``importlib.resources``).

The bash tool located these relative to ``SCRIPT_DIR``, which only works from a
git checkout. As package data they work from a wheel too, which is the whole
point of ``pip install aap-demo``.
"""

from __future__ import annotations

from importlib.resources import files
from typing import List

CRS = "aap_demo.data.crs"
OLM = "aap_demo.data.olm"
MANIFESTS = "aap_demo.data.manifests"


def read(package: str, name: str) -> str:
    return files(package).joinpath(name).read_text(encoding="utf-8")


def names(package: str, *, suffix: str = ".yaml") -> List[str]:
    return sorted(e.name for e in files(package).iterdir() if e.name.endswith(suffix))


__all__ = ["CRS", "OLM", "MANIFESTS", "read", "names"]
