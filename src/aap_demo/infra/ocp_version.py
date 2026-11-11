"""Which MicroShift version ``--ocp-version`` builds (ADR-041).

The value can be a major (``4``), a minor (``4.22``), or an exact version
(``4.22.13``). Unset means the newest supported stable version. Each major has
a profile in ``aap_demo.data.openshift``, and the code reads those instead of
branching on the version.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from importlib.resources import files
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Tuple

import yaml

from aap_demo.core.errors import AapDemoError

PROFILES = "aap_demo.data.openshift"
Version = Tuple[int, ...]

_VALUE_RE = re.compile(r"^\d+(?:\.\d+){0,2}$")


@dataclass(frozen=True)
class Profile:
    major: int
    stable: str
    minimum: str
    supported: bool
    crc_bundle: Optional[str]
    aap_channels: Tuple[str, ...]
    operators: Tuple[str, ...]


@dataclass(frozen=True)
class Resolved:
    """The version ``create`` builds, and where its bundle comes from."""

    version: str
    profile: Profile
    #: The pinned CRC release ships this bundle, so nothing is downloaded.
    builtin: bool
    #: The profile's tested version.
    stable: bool


def parse(value: str) -> Version:
    """``"4.22"`` -> ``(4, 22)``. Raises for anything but one to three numbers."""
    text = value.strip()
    if not _VALUE_RE.match(text):
        raise AapDemoError(
            f"Not an OpenShift version: {value!r}",
            hint="Use a major (5), a minor (4.22), or an exact version (4.22.13).",
        )
    return tuple(int(part) for part in text.split("."))


def format_version(version: Version) -> str:
    return ".".join(str(part) for part in version)


def _profile(document: Dict[str, Any]) -> Profile:
    return Profile(
        major=int(document["major"]),
        stable=str(document["stable"]),
        minimum=str(document["minimum"]),
        supported=bool(document["supported"]),
        crc_bundle=str(document["crc_bundle"]) if document.get("crc_bundle") else None,
        aap_channels=tuple(str(c) for c in document.get("aap_channels") or ()),
        operators=tuple(str(o) for o in document.get("operators") or ()),
    )


def load_profiles() -> Dict[int, Profile]:
    profiles: Dict[int, Profile] = {}
    for entry in files(PROFILES).iterdir():
        if entry.name.endswith(".yaml"):
            profile = _profile(yaml.safe_load(entry.read_text(encoding="utf-8")))
            profiles[profile.major] = profile
    return profiles


def default_profile(profiles: Dict[int, Profile]) -> Profile:
    """The supported profile with the highest stable version."""
    supported = [p for p in profiles.values() if p.supported]
    if not supported:
        raise AapDemoError("No supported OpenShift version is configured")
    return max(supported, key=lambda p: parse(p.stable))


def _below(version: Version, minimum: str) -> bool:
    """``4.20`` is below ``4.21``. A bare ``4`` is not: it means the newest 4."""
    floor = parse(minimum)
    return version < floor[: len(version)]


def _supported_list(profiles: Dict[int, Profile]) -> str:
    majors = sorted(profiles)
    return ", ".join(f"{m} ({profiles[m].stable})" for m in majors)


def resolve(
    value: str,
    *,
    profiles: Optional[Dict[int, Profile]] = None,
    available: Callable[[], Sequence[str]] = lambda: (),
) -> Resolved:
    """Turn a ``--ocp-version`` value into the version to build.

    ``available`` returns the mirror versions with a bundle for this host. It
    is only called when the answer is not a profile's stable version, so the
    default path never touches the network.
    """
    known = profiles if profiles is not None else load_profiles()
    text = (value or "").strip()
    if not text:
        default = default_profile(known)
        return _resolved(default.stable, default)

    requested = parse(text)
    profile = known.get(requested[0])
    if profile is None:
        raise AapDemoError(
            f"OpenShift {requested[0]} is not supported",
            hint=f"Supported: {_supported_list(known)}. List them with: aap-demo ocp-version-list",
        )
    if _below(requested, profile.minimum):
        raise AapDemoError(
            f"OpenShift {text} is older than {profile.minimum}, the oldest aap-demo builds",
            hint="List the versions with: aap-demo ocp-version-list",
        )

    stable = parse(profile.stable)
    if len(requested) < 3 and stable[: len(requested)] == requested:
        return _resolved(profile.stable, profile)
    if len(requested) == 3 and text in (profile.stable, profile.crc_bundle):
        return _resolved(text, profile)

    choices = sorted(
        (parse(v) for v in available() if parse(v)[: len(requested)] == requested),
    )
    if not choices:
        raise AapDemoError(
            f"No MicroShift {text} bundle on the mirror for this host",
            hint="List the versions you can build with: aap-demo ocp-version-list",
        )
    return _resolved(format_version(choices[-1]), profile)


def _resolved(version: str, profile: Profile) -> Resolved:
    return Resolved(
        version=version,
        profile=profile,
        builtin=version == profile.crc_bundle,
        stable=version == profile.stable,
    )


def matches(requested: str, cluster_version: str) -> bool:
    """True when a running ``cluster_version`` satisfies ``requested``.

    ``4`` matches any 4.x, ``4.22`` any 4.22.z, and an exact value only itself.
    An unset value matches anything: deploy keeps the cluster it finds.
    """
    if not (requested or "").strip():
        return True
    wanted = parse(requested)
    found = parse(cluster_version)
    return found[: len(wanted)] == wanted


def check_cluster(
    value: str,
    cluster_version: str,
    *,
    channel: str,
    index: str = "",
    profiles: Optional[Dict[int, Profile]] = None,
) -> None:
    """Stop deploy before any change when the cluster, channel or index doesn't fit.

    ``value`` is ``crc.ocp_version``. Unset keeps whatever cluster is running.
    ``index`` is ``AAP_OCP_VERSION``, the operator index tag override.
    """
    known = profiles if profiles is not None else load_profiles()
    found = parse(cluster_version)
    if index and index.split(".")[0] != str(found[0]):
        raise AapDemoError(
            f"AAP_OCP_VERSION={index} does not match this OpenShift {cluster_version} cluster",
            hint="Unset AAP_OCP_VERSION, or give it the cluster's major version.",
        )
    if not matches(value, cluster_version):
        raise AapDemoError(
            f"This cluster runs OpenShift {cluster_version}, not {value}",
            hint=f"Run aap-demo destroy, then aap-demo create --ocp-version {value}.",
        )
    profile = known.get(found[0])
    if profile is not None and profile.aap_channels and channel not in profile.aap_channels:
        raise AapDemoError(
            f"The AAP channel {channel} is not available on OpenShift {found[0]}",
            hint=f"Use one of: {', '.join(profile.aap_channels)}.",
        )


def requested(ctx: Any) -> str:
    """``crc.ocp_version`` (flag, environment, or config). Empty when unset."""
    return str(ctx.config.get("crc.ocp_version", "") or "").strip()


def legacy_setting(ctx: Any) -> Optional[str]:
    """``CRC_VERSION`` or ``crc.version`` when one is set, for a deprecation note.

    They keep their old meaning (a MicroShift floor that keeps the CRC already
    on PATH), so a user who relied on skipping the CRC upgrade still can.
    """
    if str(ctx.env.get("CRC_VERSION", "") or "").strip():
        return "CRC_VERSION"
    if str(ctx.config.get("crc.version", "") or "").strip():
        return "crc.version"
    return None


def versions_in(names: Iterable[str]) -> List[str]:
    """Directory entries that are full versions, oldest first."""
    found = [n.strip("/") for n in names if re.match(r"^\d+\.\d+\.\d+/?$", n.strip())]
    return [format_version(v) for v in sorted({parse(n) for n in found})]


__all__ = [
    "Profile",
    "check_cluster",
    "Resolved",
    "default_profile",
    "format_version",
    "load_profiles",
    "matches",
    "parse",
    "legacy_setting",
    "requested",
    "resolve",
    "versions_in",
]
