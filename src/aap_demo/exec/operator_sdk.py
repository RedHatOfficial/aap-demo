"""``operator-sdk`` discovery, auto-install, and invocation.

Ports ``ensure_operator_sdk`` and the ``operator-sdk`` calls in
``addons/olm/deploy.sh``, plus ``deploy_operator_sdk`` (aap-demo.sh:2381) and
the ``operator-sdk cleanup`` in ``_clean_operator`` (aap-demo.sh:755).

The download stays a ``curl`` invocation through the ``CommandRunner`` rather
than becoming ``urllib``: it is the one place the tool reaches the public
internet on the deploy path, and keeping it on the seam means a test asserts
the URL without a network stub, and a user's proxy/CA configuration keeps
working exactly as it does for the bash tool.
"""

from __future__ import annotations

import platform
import shutil
from pathlib import Path
from typing import Any, Callable, Optional

from aap_demo.core.errors import AapDemoError, PrerequisiteError

#: Pinned in ``addons/olm/deploy.sh:47``.
SDK_VERSION = "v1.38.0"
RELEASE_URL = (
    "https://github.com/operator-framework/operator-sdk/releases/download/"
    "{version}/operator-sdk_{os}_{arch}"
)

_OS_MAP = {"Darwin": "darwin", "Linux": "linux"}
_ARCH_MAP = {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}


def platform_slug(system: Optional[str] = None, machine: Optional[str] = None) -> "tuple[str, str]":
    """Ports the ``uname -s`` / ``uname -m`` case blocks, errors included."""
    sys_name = system or platform.system()
    mach = machine or platform.machine()
    if sys_name not in _OS_MAP:
        raise PrerequisiteError(f"Unsupported OS: {sys_name}")
    if mach not in _ARCH_MAP:
        raise PrerequisiteError(f"Unsupported architecture: {mach}")
    return _OS_MAP[sys_name], _ARCH_MAP[mach]


def download_url(system: Optional[str] = None, machine: Optional[str] = None) -> str:
    sdk_os, sdk_arch = platform_slug(system, machine)
    return RELEASE_URL.format(version=SDK_VERSION, os=sdk_os, arch=sdk_arch)


def ensure_available(
    ctx: Any,
    *,
    which: Callable[[str], Optional[str]] = shutil.which,
) -> Path:
    """Ports ``ensure_operator_sdk`` (addons/olm/deploy.sh:21).

    Installs to ``~/.local/bin`` first and only then tries to relocate it to
    ``/usr/local/bin`` — and only when ``sudo -n`` already works, so the
    deploy never blocks on a password prompt it cannot service.
    """
    found = which("operator-sdk")
    if found:
        return Path(found)

    ctx.console.out("operator-sdk not found. Installing...")
    ctx.console.out("")

    url = download_url()
    sdk_os, sdk_arch = platform_slug()
    ctx.console.out(f"Downloading operator-sdk {SDK_VERSION} for {sdk_os}/{sdk_arch}...")

    bin_dir = Path(ctx.env.get("HOME") or Path.home()) / ".local" / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    dest = bin_dir / "operator-sdk"

    if not ctx.runner.run(["curl", "-fsSL", "-o", str(dest), url]).ok:
        raise AapDemoError(
            "Failed to download operator-sdk",
            hint=f"Download it manually from {url} and put it on PATH.",
        )
    dest.chmod(0o755)

    if ctx.runner.run(["sudo", "-n", "true"]).ok:
        system_path = Path("/usr/local/bin/operator-sdk")
        if ctx.runner.run(["sudo", "mv", str(dest), str(system_path)]).ok:
            ctx.console.out("✓ operator-sdk installed to /usr/local/bin/")
            return system_path

    ctx.console.out(f"✓ operator-sdk installed to {dest}")
    if str(bin_dir) not in (ctx.env.get("PATH") or "").split(":"):
        ctx.console.out("NOTE: Add to PATH: export PATH=$HOME/.local/bin:$PATH")
    ctx.console.out("")
    return dest


def olm_install(ctx: Any) -> Any:
    return ctx.runner.run(["operator-sdk", "olm", "install"])


def olm_status(ctx: Any) -> Any:
    return ctx.runner.run(["operator-sdk", "olm", "status"])


def cleanup(ctx: Any, package: str, namespace: str) -> Any:
    """``operator-sdk cleanup <package> -n <ns>`` (aap-demo.sh:755)."""
    return ctx.runner.run(["operator-sdk", "cleanup", package, "-n", namespace])


def run_bundle(ctx: Any, bundle_image: str, namespace: str) -> Any:
    """Ports ``deploy_operator_sdk`` (aap-demo.sh:2381)."""
    return ctx.runner.run(
        [
            "operator-sdk",
            "run",
            "bundle",
            bundle_image,
            "--namespace",
            namespace,
            "--security-context-config",
            "restricted",
            "--timeout",
            "10m",
            "--pull-secret-name",
            "redhat-operators-pull-secret",
        ]
    )


__all__ = [
    "RELEASE_URL",
    "SDK_VERSION",
    "cleanup",
    "download_url",
    "ensure_available",
    "olm_install",
    "olm_status",
    "platform_slug",
    "run_bundle",
]
