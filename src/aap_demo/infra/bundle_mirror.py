"""MicroShift CRC bundles on mirror.openshift.com (ADR-041).

Reads the mirror's directory listings only. Downloading and verifying a bundle
is ``bundle_fetch``'s job.
"""

from __future__ import annotations

import platform
import re
import urllib.request
from typing import Any, Callable, List, Optional, Sequence

from aap_demo.core.errors import PrerequisiteError
from aap_demo.infra import ocp_version as ocp

BASE_URL = "https://mirror.openshift.com/pub/openshift-v4/clients/crc/bundles/microshift"
TIMEOUT_SECONDS = 15
Opener = Callable[..., Any]

_HREF_RE = re.compile(r'href="([^"?#]+)"', re.IGNORECASE)
_DRIVER = {"Darwin": "vfkit", "Linux": "libvirt", "Windows": "hyperv"}
_ARCH = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}


def bundle_name(version: str, *, system: str = "", machine: str = "") -> str:
    """``crc_microshift_vfkit_5.0.0_arm64.crcbundle`` for this host."""
    system = system or platform.system()
    machine = machine or platform.machine()
    driver = _DRIVER.get(system)
    arch = _ARCH.get(machine.lower())
    if driver is None or arch is None or (driver == "hyperv" and arch != "amd64"):
        raise PrerequisiteError(f"No MicroShift bundle is published for {system} {machine}")
    return f"crc_microshift_{driver}_{version}_{arch}.crcbundle"


def version_url(version: str, name: str = "") -> str:
    return f"{BASE_URL}/{version}/{name}"


def _links(url: str, opener: Opener) -> List[str]:
    with opener(url, timeout=TIMEOUT_SECONDS) as response:
        text = response.read().decode("utf-8", errors="replace")
    return [
        link.rsplit("/", 2)[-2] + "/" if link.endswith("/") else link.rsplit("/", 1)[-1]
        for link in _HREF_RE.findall(text)
    ]


def versions(*, opener: Opener = urllib.request.urlopen) -> List[str]:
    """Every full version the mirror lists, oldest first."""
    return ocp.versions_in(_links(f"{BASE_URL}/", opener))


def host_versions(
    *,
    minimum: str,
    system: str = "",
    machine: str = "",
    opener: Opener = urllib.request.urlopen,
    listed: Optional[Sequence[str]] = None,
) -> List[str]:
    """Versions at or above ``minimum`` with a bundle for this host, oldest first.

    One request for the top listing, then one per version at or above
    ``minimum``.
    """
    floor = ocp.parse(minimum)
    candidates = [
        v
        for v in (listed if listed is not None else versions(opener=opener))
        if ocp.parse(v) >= floor
    ]
    found: List[str] = []
    for version in candidates:
        name = bundle_name(version, system=system, machine=machine)
        if name in _links(version_url(version), opener):
            found.append(version)
    return found


__all__ = ["BASE_URL", "bundle_name", "host_versions", "version_url", "versions"]
