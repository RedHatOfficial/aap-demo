"""OpenShift Local (CRC) backend queries via the ``CommandRunner`` seam.

Ports the parts of ``includes/infra-crc.sh`` and ``includes/infra-api.sh``
needed by the phase-1 read-only commands (design §2.2 mapping table).
"""

from __future__ import annotations

import json
import re
from importlib.resources import files
from pathlib import Path
from typing import Any, Callable, Dict, Optional, Tuple

from aap_demo.core.errors import AapDemoError

STATE_RUNNING = "running"
STATE_STOPPED = "stopped"
STATE_NOT_CREATED = "not_created"

#: Bash defaults (aap-demo.sh). ``CRC_VERSION`` may be lowered; the warning
#: still uses ``CRC_RECOMMENDED_VERSION``. Create and deploy both use this
#: floor, so a new cluster is the release deploy will accept.
RECOMMENDED_VERSION = "4.22"
MINIMUM_VERSION = "4.22"
#: Page the manual install hint points at. ``create`` installs the release in
#: ``data/crc-release`` itself; ``.github/workflows/crc-release.yaml`` opens a
#: pull request when crc-org/crc publishes a newer one.
CRC_DOWNLOAD_URL = "https://console.redhat.com/openshift/create/local"
_RELEASE_RE = re.compile(r"\d+(?:\.\d+){1,2}")
STABILITY_SAMPLES = 3
STABILITY_ATTEMPTS = 30
STABILITY_SLEEP_SECONDS = 5.0

_VERSION_RE = re.compile(r"^(\d+)\.(\d+)")


def managed_crc_release() -> str:
    """CRC release ``create`` installs. Bumped by the CRC release workflow."""
    return files("aap_demo.data").joinpath("crc-release").read_text(encoding="utf-8").strip()


def normalize_release(tag: str) -> str:
    """``v2.64.0`` and ``2.58.0+sha`` both become ``2.64.0`` / ``2.58.0``."""
    text = tag.strip()
    if text[:1] in ("v", "V"):
        text = text[1:]
    text = text.split("+", 1)[0]
    if "-" in text:
        raise ValueError(f"pre-release CRC tag: {tag}")
    if _RELEASE_RE.fullmatch(text) is None:
        raise ValueError(f"unrecognized CRC release: {tag}")
    return text


def parse_release(tag: str) -> Tuple[int, ...]:
    return tuple(int(part) for part in normalize_release(tag).split("."))


def release_is_newer(latest: str, current: str) -> bool:
    """True when ``latest`` is a newer CRC release than ``current``."""
    return parse_release(latest) > parse_release(current)


def crc_client_version(text: str) -> Optional[str]:
    """The ``CRC version:`` line from ``crc version``."""
    for line in text.splitlines():
        label, sep, value = line.partition(":")
        if sep == ":" and label == "CRC version":
            return value.strip()
    return None


#: ``_crc_status_json`` polls 20 times at 0.1s (includes/infra-crc.sh). The CRC
#: daemon can stop answering while the VM is stopped or unhealthy; without this
#: bound, ``status`` and every other read-only caller hang with it.
STATUS_TIMEOUT_SECONDS = 2.0


def status_json(runner: Any) -> Dict[str, Any]:
    """``crc status -o json``, tolerating a missing, hung, or broken ``crc``.

    Mirrors the bash pattern of piping through a throwaway ``python3 -c``
    parser and falling back to "unknown" on any failure (aap-demo.sh:1035,
    includes/infra-crc.sh) — here that fallback is just an empty dict. A hang
    is the same outcome as a failure: callers must not block on the daemon.
    """
    try:
        result = runner.run(
            ["crc", "status", "-o", "json"],
            timeout=STATUS_TIMEOUT_SECONDS,
        )
    except Exception:  # noqa: BLE001 - crc absent, hung, or failing must never crash callers
        return {}
    if not result.ok or not result.stdout.strip():
        return {}
    try:
        data = json.loads(result.stdout)
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def get_state(runner: Any) -> str:
    """Ports ``_infra_crc_get_state`` (includes/infra-crc.sh:92)."""
    crc_status = status_json(runner).get("crcStatus", "Unknown")
    if crc_status == "Running":
        return STATE_RUNNING
    if crc_status == "Stopped":
        return STATE_STOPPED
    return STATE_NOT_CREATED


def has_instance(runner: Any, *, home: Optional[Path] = None) -> bool:
    """True when a CRC VM exists to delete.

    ``crc status`` reports ``Stopped`` both for a stopped VM and for a host
    that was never created. A real VM includes ``openshiftVersion``. A status
    call that does not answer falls back to CRC's machine directory.
    """
    data = status_json(runner)
    status = str(data.get("crcStatus") or "")
    if status == "Running":
        return True
    if status == "Stopped" and str(data.get("openshiftVersion") or "").strip():
        return True
    root = home if home is not None else Path.home()
    return (root / ".crc" / "machines" / "crc" / "config.json").is_file()


def get_name(preset: str) -> str:
    """Ports ``_infra_crc_get_name`` (includes/infra-crc.sh:144).

    Bash's ``_detect_crc_preset`` (includes/infra-crc.sh:118) checks
    ``CRC_PRESET``, then the legacy ``~/.aap-demo/config`` value, then falls
    back to querying ``crc config get preset`` live, defaulting to
    "microshift" only when crc reports it unset. The Python config layer
    already resolves env (``CRC_PRESET``) over the saved file over a
    "microshift" schema default (§5.3), which covers the same cases except
    one: a preset set directly via ``crc config set preset`` without ever
    going through aap-demo. That live-crc fallback is not reproduced here —
    a live cluster is needed to judge how much it matters in practice.
    """
    return f"crc-{preset}"


def disk_usage_percent(data: Dict[str, Any]) -> int:
    """Ports the disk-usage percentage calc in ``cmd_diagnose`` (aap-demo.sh:1080).

    Mirrors bash's ``d.get('diskUse',0)`` / ``d.get('diskSize',1)`` exactly:
    the default applies only when the key is *absent*, not when it is present
    and zero — an explicit ``diskSize: 0`` still divides by zero and falls
    back to 0, same as bash's ``2>/dev/null || echo "0"``.
    """
    used = data.get("diskUse", 0)
    total = data.get("diskSize", 1)
    try:
        return int(used / total * 100)
    except (TypeError, ZeroDivisionError):
        return 0


def prune_images(ctx: Any) -> int:
    """Ports ``_prune_unused_images`` (aap-demo.sh:569).

    Counts the ``Deleted`` lines ``crictl rmi --prune`` prints, the way bash's
    ``grep -ci deleted`` does, and never fails the caller: reclaiming disk is
    an optimization, and a VM that is unreachable for SSH has already produced
    a louder error somewhere else.
    """
    from aap_demo.exec import ssh as ssh_mod

    ctx.console.progress("Pruning unused container images")
    key = ssh_mod.detect_ssh_key(ssh_mod.crc_machines_dir(ctx.env))
    if key is None:
        return 0
    result = ssh_mod.exec_remote(
        ctx.runner, key, "bash", "-c", "sudo crictl rmi --prune 2>&1", sudo=False
    )
    pruned = sum(1 for line in (result.stdout or "").splitlines() if "deleted" in line.lower())
    return pruned


def parse_version(text: str) -> Optional[Tuple[int, int]]:
    """Major.minor from a CRC ``openshiftVersion``, ignoring a patch suffix."""
    match = _VERSION_RE.match(text.strip())
    if match is None:
        return None
    return int(match.group(1)), int(match.group(2))


def _version_pair(text: str, fallback: str) -> Tuple[int, int]:
    parsed = parse_version(text)
    if parsed is None:
        parsed = parse_version(fallback)
    if parsed is None:
        return (0, 0)
    return parsed


def _below(installed: Tuple[int, int], required: Tuple[int, int]) -> bool:
    return installed[0] < required[0] or (
        installed[0] == required[0] and installed[1] < required[1]
    )


def verify_version(ctx: Any) -> bool:
    """Ports ``_verify_crc_version`` (upstream #167).

    A cluster older than ``CRC_VERSION`` (default 4.22) is rejected. A cluster
    older than ``CRC_RECOMMENDED_VERSION`` warns even when an override lowered
    the hard minimum. Returns False when deploy must stop.
    """
    installed_text = str(status_json(ctx.runner).get("openshiftVersion", "") or "")
    installed = parse_version(installed_text)
    if installed is None:
        ctx.console.err("")
        ctx.console.err("ERROR: Could not detect CRC version")
        ctx.console.err("")
        ctx.console.err("Ensure CRC cluster is created and running:")
        ctx.console.err("  aap-demo create")
        ctx.console.err("")
        ctx.console.err("Or bypass version check with explicit override:")
        ctx.console.err("  CRC_VERSION=4.22 aap-demo deploy")
        ctx.console.err("")
        return False

    recommended = _version_pair(ctx.env.get("CRC_RECOMMENDED_VERSION", ""), RECOMMENDED_VERSION)
    minimum = _version_pair(ctx.env.get("CRC_VERSION", ""), MINIMUM_VERSION)
    shown = _VERSION_RE.match(installed_text.strip())
    shown_text = shown.group(0) if shown else installed_text

    if _below(installed, recommended):
        ctx.console.warn("CRC/MicroShift version is below the recommended version")
        recommended_label = ctx.env.get("CRC_RECOMMENDED_VERSION") or RECOMMENDED_VERSION
        ctx.console.out(f"  Recommended: {recommended_label} or newer")
        ctx.console.out(f"  Installed: {shown_text}")
        ctx.console.out("  You may encounter deployment or VM stability issues on older versions.")
        ctx.console.out("  Download latest CRC: https://console.redhat.com/openshift/create/local")
        ctx.console.out("")

    if _below(installed, minimum):
        required = ctx.env.get("CRC_VERSION") or MINIMUM_VERSION
        ctx.console.err("")
        ctx.console.err("ERROR: CRC version too old")
        ctx.console.err(f"  Required: {required} or newer")
        ctx.console.err(f"  Installed: {shown_text}")
        ctx.console.err("")
        ctx.console.err(
            "MicroShift 4.22+ is required to avoid signature validation issues "
            "with the operator catalog."
        )
        ctx.console.err("")
        ctx.console.err("To fix:")
        ctx.console.err("  1. Delete the current cluster: aap-demo destroy")
        ctx.console.err(
            "  2. Download latest CRC: https://console.redhat.com/openshift/create/local"
        )
        ctx.console.err("  3. Install and create new cluster: aap-demo create")
        ctx.console.err("")
        ctx.console.err(f"Or override the version check: CRC_VERSION={shown_text} aap-demo deploy")
        ctx.console.err("")
        return False
    return True


def bundled_microshift_version(text: str) -> Optional[str]:
    """MicroShift line from ``crc version``, else the OpenShift line.

    ``crc version`` reports the bundle baked into that binary. A MicroShift
    preset cluster is created at that version; there is no separate bundle flag.
    """
    microshift: Optional[str] = None
    openshift: Optional[str] = None
    for line in text.splitlines():
        label, sep, value = line.partition(":")
        if sep != ":":
            continue
        version = value.strip().lstrip("v")
        if label == "MicroShift version":
            microshift = version
        elif label == "OpenShift version":
            openshift = version
    return microshift or openshift


def require_supported_bundle(ctx: Any) -> str:
    """Refuse to create a cluster older than the deploy floor.

    The default floor is :data:`MINIMUM_VERSION`. ``CRC_VERSION`` lowers it
    for one command, the same override ``deploy`` already accepts.
    """
    result = ctx.runner.run(["crc", "version"])
    shown = bundled_microshift_version(result.stdout if result.ok else "")
    installed = parse_version(shown or "")
    minimum = _version_pair(ctx.env.get("CRC_VERSION", ""), MINIMUM_VERSION)
    if installed is None or shown is None:
        raise AapDemoError(
            "Could not read the MicroShift version from crc version",
            hint=(
                f"create requires MicroShift {MINIMUM_VERSION} or newer. "
                f"Install CRC {managed_crc_release()} from {CRC_DOWNLOAD_URL}"
            ),
        )

    shown_text = shown.strip()
    recommended = _version_pair(ctx.env.get("CRC_RECOMMENDED_VERSION", ""), RECOMMENDED_VERSION)
    if _below(installed, recommended):
        ctx.console.warn("CRC/MicroShift version is below the recommended version")
        ctx.console.out(f"  Recommended: {RECOMMENDED_VERSION} or newer")
        ctx.console.out(f"  Installed: {shown_text}")
        ctx.console.out("")

    if _below(installed, minimum):
        required = ctx.env.get("CRC_VERSION") or MINIMUM_VERSION
        raise AapDemoError(
            f"Installed CRC bundles MicroShift {shown_text}; create requires {required} or newer",
            hint=(
                f"Install CRC {managed_crc_release()}, which includes "
                f"MicroShift {MINIMUM_VERSION}: {CRC_DOWNLOAD_URL}. "
                f"To create this older release anyway: CRC_VERSION={shown_text} aap-demo create"
            ),
        )
    return shown_text


def _opted_into_older_bundle(ctx: Any, microshift: Optional[str]) -> bool:
    """``CRC_VERSION=4.21`` keeps the installed bundle instead of upgrading."""
    raw = str(ctx.env.get("CRC_VERSION", "") or "").strip()
    if not raw or microshift is None:
        return False
    floor = parse_version(MINIMUM_VERSION)
    asked = parse_version(raw)
    installed = parse_version(microshift)
    if floor is None or asked is None or installed is None:
        return False
    return _below(asked, floor) and not _below(installed, asked)


def _needs_managed_crc(client: Optional[str], microshift: Optional[str]) -> bool:
    if client is None or microshift is None:
        return True
    try:
        client_release = parse_release(client)
        managed = parse_release(managed_crc_release())
    except ValueError:
        return True
    installed = parse_version(microshift)
    floor = parse_version(MINIMUM_VERSION)
    if installed is None or floor is None:
        return True
    if _below(installed, floor):
        return True
    return client_release < managed


def ensure_managed_crc(ctx: Any, *, which: Callable[[str], Optional[str]]) -> Tuple[str, bool]:
    """Install the pinned CRC release when the current binary is older.

    Returns ``(microshift_version, upgraded)``. ``CRC_VERSION`` set below the
    deploy floor keeps the installed bundle, the same override ``deploy`` uses.
    """
    from aap_demo.infra import crc_install

    found = which("crc")
    text = ""
    if found:
        result = ctx.runner.run(["crc", "version"])
        text = result.stdout if result.ok else ""
    client = crc_client_version(text)
    microshift = bundled_microshift_version(text)
    if _opted_into_older_bundle(ctx, microshift):
        return require_supported_bundle(ctx), False
    if not _needs_managed_crc(client, microshift):
        assert microshift is not None
        return microshift.strip(), False

    ctx.console.out(
        f"Installing CRC {managed_crc_release()} "
        f"(current CRC is {client or 'not installed'}, "
        f"MicroShift {microshift or 'unknown'})..."
    )
    crc_install.install_managed_release(ctx, current=found)
    if microshift:
        removed = crc_install.remove_old_bundle_cache(
            Path(ctx.env.get("HOME") or Path.home()), microshift
        )
        if removed:
            ctx.console.out(f"Removed {removed} old CRC bundle cache file(s).")
    result = ctx.runner.run(["crc", "version"])
    shown = bundled_microshift_version(result.stdout if result.ok else "")
    parsed = parse_version(shown or "")
    floor = parse_version(MINIMUM_VERSION)
    if shown is None or parsed is None or floor is None or _below(parsed, floor):
        raise AapDemoError(
            f"CRC {managed_crc_release()} did not provide MicroShift {MINIMUM_VERSION}",
            hint=f"Install it from {CRC_DOWNLOAD_URL}",
        )
    return shown.strip(), True


def _api_healthy(data: Dict[str, Any], runner: Any) -> bool:
    openshift = str(data.get("openshiftStatus", "") or "")
    if openshift == "Running":
        return True
    if openshift != "Unreachable":
        return False
    # CRC's status probe can lose the host alias while the API still answers.
    result = runner.run(["kubectl", "get", "nodes", "--request-timeout=5s"])
    return bool(getattr(result, "ok", False))


def wait_until_stable(
    runner: Any,
    *,
    samples: int = STABILITY_SAMPLES,
    attempts: Optional[int] = None,
    sleep_seconds: Optional[float] = None,
    sleep: Callable[[float], None] = None,  # type: ignore[assignment]
) -> bool:
    """Ports ``_wait_for_crc_stable`` (upstream #199).

    CRC can report a running VM just before vfkit exits or the guest reboots.
    ``samples`` consecutive healthy reads are required. A miss resets the count.
    """
    import time

    if sleep is None:
        sleep = time.sleep
    if attempts is None:
        attempts = STABILITY_ATTEMPTS
    if sleep_seconds is None:
        sleep_seconds = STABILITY_SLEEP_SECONDS
    healthy = 0
    for attempt in range(1, attempts + 1):
        data = status_json(runner)
        if data.get("crcStatus") == "Running" and _api_healthy(data, runner):
            healthy += 1
            if healthy >= samples:
                return True
        else:
            healthy = 0
        if attempt < attempts:
            sleep(sleep_seconds)
    return False
