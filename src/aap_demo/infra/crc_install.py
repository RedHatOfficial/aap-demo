"""Download and install the CRC release pinned in ``data/crc-release``.

The bundle version is baked into the ``crc`` binary. ``create`` uses this
module when the ``crc`` on PATH is missing or older than that pin, then puts
the new binary first on PATH for the rest of the command.
"""

from __future__ import annotations

import gzip
import hashlib
import os
import platform
import shutil
import tarfile
import zipfile
from pathlib import Path
from typing import Any, BinaryIO, Optional

from aap_demo.core.errors import AapDemoError, PrerequisiteError
from aap_demo.infra.crc import managed_crc_release

MIRROR = "https://mirror.openshift.com/pub/openshift-v4/clients/crc/{release}/{name}"

_INSTALL_NAMES = frozenset({"crc", "crc.exe", "vfkit", "crc-admin-helper-darwin"})
_ARCH = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}


def mirror_url(release: str, name: str) -> str:
    return MIRROR.format(release=release, name=name)


def archive_filename(system: str, machine: str) -> str:
    """Archive name published for one OS and CPU, matching the CRC mirror."""
    if system == "Darwin":
        return "crc-macos-installer.pkg"
    arch = _ARCH.get(machine.lower())
    if system == "Linux" and arch:
        return f"crc-linux-{arch}.tar.xz"
    if system == "Windows" and arch == "amd64":
        return "crc-windows-installer.zip"
    raise PrerequisiteError(f"Unsupported platform for CRC install: {system} {machine}")


def parse_sha256sum(text: str, filename: str) -> str:
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == filename:
            return parts[0]
    raise AapDemoError(f"Checksum for {filename} was not in sha256sum.txt")


def extract_crc_tarball(archive: Path, dest: Path) -> None:
    with tarfile.open(archive, "r:xz") as tar:
        for member in tar.getmembers():
            _extract_named_member(member, tar.extractfile(member), dest)
    _require_crc_binary(dest)


def extract_crc_zip(archive: Path, dest: Path) -> None:
    with zipfile.ZipFile(archive) as bundle:
        for info in bundle.infolist():
            name = Path(info.filename).name
            if name not in _INSTALL_NAMES or info.is_dir():
                continue
            target = dest / name
            target.write_bytes(bundle.read(info))
            target.chmod(0o755)
    _require_crc_binary(dest)


def extract_gzip_odc(payload: Path, dest: Path) -> None:
    """Unpack a macOS pkg ``Payload`` (gzip-compressed odc cpio)."""
    with gzip.open(payload, "rb") as handle:
        _extract_odc(handle, dest)


def install_managed_release(ctx: Any, *, current: Optional[str] = None) -> Path:
    """Download the pinned CRC release into the cache and prefer it on PATH."""
    release = managed_crc_release()
    system = ctx.env.get("AAP_DEMO_CRC_INSTALL_OS") or platform.system()
    machine = ctx.env.get("AAP_DEMO_CRC_INSTALL_MACHINE") or platform.machine()
    filename = archive_filename(system, machine)
    work = ctx.paths.cache_dir / "crc-install" / release
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    sums = work / "sha256sum.txt"
    archive = work / filename
    _curl(ctx, mirror_url(release, "sha256sum.txt"), sums)
    _curl(ctx, mirror_url(release, filename), archive)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    expected = parse_sha256sum(sums.read_text(encoding="utf-8"), filename)
    if digest != expected:
        raise AapDemoError(
            "CRC download checksum did not match",
            hint=f"Expected {expected}, got {digest}",
        )

    install_dir = ctx.paths.cache_dir / "crc" / release
    if install_dir.exists():
        shutil.rmtree(install_dir)
    install_dir.mkdir(parents=True)
    if filename.endswith(".tar.xz"):
        extract_crc_tarball(archive, install_dir)
    elif filename.endswith(".zip"):
        extract_crc_zip(archive, install_dir)
    else:
        _extract_macos_pkg(ctx, archive, install_dir)
    _publish(install_dir, current, Path(ctx.env.get("HOME") or Path.home()))
    _prefer_bin_dir(ctx, install_dir)
    _stop_stale_daemon(ctx)
    ctx.console.out(f"  CRC {release} installed to {install_dir}")
    return install_dir


def _stop_stale_daemon(ctx: Any) -> None:
    """CRC 2.64's client rejects an older daemon. Stop one left from the previous binary."""
    home = ctx.env.get("HOME")
    if not home:
        return
    root = Path(home) / ".crc"
    sockets = (
        root / "crc-http.sock",
        root / "crc.sock",
        root / "sockets" / "crc-http.sock",
    )
    if not any(path.exists() for path in sockets):
        return
    ctx.runner.run(["pkill", "-f", "crc daemon"])


def remove_old_bundle_cache(home: Path, version: str) -> int:
    """Delete cached bundles whose names contain ``version`` (for example 4.21.0)."""
    cache = home / ".crc" / "cache"
    if not version or not cache.is_dir():
        return 0
    removed = 0
    for child in cache.iterdir():
        if version not in child.name:
            continue
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()
        removed += 1
    return removed


def _curl(ctx: Any, url: str, dest: Path) -> None:
    result = ctx.runner.run(["curl", "-fsSL", "--retry", "3", "-o", str(dest), url])
    if not result.ok or not dest.is_file():
        raise AapDemoError(
            "Failed to download CRC",
            hint=f"Download it from {url}",
        )


def _extract_macos_pkg(ctx: Any, archive: Path, dest: Path) -> None:
    expanded = archive.parent / "pkg"
    result = ctx.runner.run(["pkgutil", "--expand", str(archive), str(expanded)])
    if not result.ok:
        raise AapDemoError(
            "Could not expand the CRC macOS package",
            hint="pkgutil --expand failed",
        )
    payloads = list(expanded.rglob("Payload"))
    if not payloads:
        raise AapDemoError("CRC macOS package did not contain a Payload")
    staging = archive.parent / "payload"
    staging.mkdir()
    extract_gzip_odc(payloads[0], staging)
    bundled = staging / "usr" / "local" / "crc"
    if not bundled.is_dir():
        raise AapDemoError("CRC macOS package did not contain /usr/local/crc")
    for name in _INSTALL_NAMES:
        source = bundled / name
        if source.is_file():
            target = dest / name
            shutil.copy2(source, target)
            target.chmod(0o755)
    _require_crc_binary(dest)


def _extract_named_member(member: tarfile.TarInfo, source: Optional[BinaryIO], dest: Path) -> None:
    name = Path(member.name).name
    if source is None or not member.isfile() or name not in _INSTALL_NAMES:
        return
    if ".." in Path(member.name).parts:
        return
    target = dest / name
    target.write_bytes(source.read())
    target.chmod(0o755)


def _extract_odc(handle: BinaryIO, dest: Path) -> None:
    while True:
        header = _read_exact(handle, 76)
        if header is None:
            break
        if header[:6] != b"070707":
            raise AapDemoError("CRC package payload is not an odc cpio archive")
        mode = int(header[18:24], 8)
        namesize = int(header[59:65], 8)
        filesize = int(header[65:76], 8)
        raw_name = _read_exact(handle, namesize)
        if raw_name is None:
            raise AapDemoError("CRC package payload ended inside a file name")
        name = raw_name.split(b"\0", 1)[0].decode("utf-8", "replace")
        data = _read_exact(handle, filesize)
        if data is None:
            raise AapDemoError("CRC package payload ended inside a file")
        if name == "TRAILER!!!":
            return
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            continue
        target = dest / relative
        if mode & 0o170000 == 0o040000:
            target.mkdir(parents=True, exist_ok=True)
            continue
        if mode & 0o170000 != 0o100000:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)


def _read_exact(handle: BinaryIO, size: int) -> Optional[bytes]:
    if size == 0:
        return b""
    chunks = []
    remaining = size
    while remaining:
        chunk = handle.read(remaining)
        if not chunk:
            return None
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _require_crc_binary(dest: Path) -> None:
    if not (dest / "crc").is_file() and not (dest / "crc.exe").is_file():
        raise AapDemoError("CRC archive did not contain a crc binary")


def _publish(install_dir: Path, current: Optional[str], home: Path) -> None:
    """Install binaries where a later shell will find them.

    The directory of the current ``crc`` is often root-owned (``/usr/local/bin``
    on macOS). ``~/.local/bin`` is the writable location pipx already puts first
    on PATH, so the new binary wins over that system symlink.
    """
    targets = [home / ".local" / "bin"]
    if current:
        system_dir = Path(current).resolve().parent
        if os.access(system_dir, os.W_OK):
            targets.append(system_dir)
    for target_dir in targets:
        target_dir.mkdir(parents=True, exist_ok=True)
        for name in _INSTALL_NAMES:
            source = install_dir / name
            if source.is_file():
                dest = target_dir / name
                shutil.copy2(source, dest)
                dest.chmod(0o755)


def _prefer_bin_dir(ctx: Any, bin_dir: Path) -> None:
    from aap_demo.exec.runner import EnvRunner

    prefix = str(bin_dir)
    current = ctx.env.get("PATH", "")
    if not current or current.split(os.pathsep)[0] != prefix:
        ctx.env["PATH"] = prefix + (os.pathsep + current if current else "")
    runner = ctx.runner
    if isinstance(runner, EnvRunner):
        runner.env["PATH"] = ctx.env["PATH"]
    else:
        ctx.runner = EnvRunner(runner, dict(ctx.env))
