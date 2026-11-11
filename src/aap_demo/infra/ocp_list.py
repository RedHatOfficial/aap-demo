"""Rows for ``aap-demo ocp-version-list`` (ADR-041)."""

from __future__ import annotations

import urllib.error
from typing import Callable, Dict, List, Optional, Sequence

from aap_demo.infra import ocp_version as ocp

Row = Dict[str, object]


def rows(
    *,
    crc_release: str,
    show_all: bool = False,
    profiles: Optional[Dict[int, ocp.Profile]] = None,
    host_versions: Callable[[str], Sequence[str]],
) -> List[Row]:
    """Newest first. ``host_versions(minimum)`` lists mirror versions for this host.

    A mirror that can't be read still gives the profile versions, with
    ``checked`` false, so the command works offline.
    """
    known = profiles if profiles is not None else ocp.load_profiles()
    default = ocp.default_profile(known)
    floor = min(ocp.parse(p.minimum) for p in known.values())
    stables = {p.stable: p for p in known.values()}
    builtins = {p.crc_bundle for p in known.values() if p.crc_bundle}

    checked = True
    try:
        listed = list(host_versions("0.0.0" if show_all else ocp.format_version(floor)))
    except (OSError, urllib.error.URLError):
        checked = False
        listed = []
    versions = set(listed) | set(stables)

    out: List[Row] = []
    for version in sorted(versions, key=ocp.parse, reverse=True):
        parsed = ocp.parse(version)
        profile = known.get(parsed[0])
        supported = profile is not None and parsed >= ocp.parse(profile.minimum)
        if version in stables:
            status = "stable, default" if stables[version] is default else "stable"
            if not stables[version].supported:
                status += ", not default yet"
        elif supported:
            status = "untested"
        else:
            status = "not supported"
        source = f"CRC {crc_release} (built in)" if version in builtins else "download"
        if checked and version not in listed and version not in builtins:
            source = "no bundle for this host"
        out.append(
            {
                "version": version,
                "status": status,
                "source": source,
                "default": profile is default and version == default.stable,
                "checked": checked,
            }
        )
    return out


def render_text(table: List[Row]) -> str:
    lines = [f"{'VERSION':<10}{'STATUS':<28}SOURCE"]
    for row in table:
        status = str(row["status"])
        if not row["checked"]:
            status += " (not checked)"
        lines.append(f"{row['version']!s:<10}{status:<28}{row['source']}")
    return "\n".join(lines)


__all__ = ["render_text", "rows"]
