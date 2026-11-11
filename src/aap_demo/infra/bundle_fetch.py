"""Download and verify a MicroShift bundle CRC doesn't ship (ADR-041).

Order, stopping at the first failure:

1. Fetch ``sha256sum.txt.sig`` and verify it against Red Hat release key 2.
2. Take the bundle's sha256 from the verified text only.
3. Reuse ``~/.crc/cache/<bundle>`` when it already matches, otherwise download
   to a ``.part`` file, check it, and move it into place.

A file that fails the check is deleted. CRC starts the result with
``crc start -b``.
"""

from __future__ import annotations

import hashlib
import urllib.request
from importlib.resources import files
from pathlib import Path
from typing import Any, Callable

from aap_demo.exec import download
from aap_demo.infra import bundle_mirror, pgp

#: Red Hat, Inc. (release key 2) <security@redhat.com>. Checked every time the
#: packaged key is loaded, so a changed key file fails instead of being trusted.
RED_HAT_RELEASE_KEY_2 = "567E347AD0044ADE55BA8A5F199E2F91FD431D51"
KEY_FILE = "redhat-release-key-2.asc"
SIGNED_SUMS = "sha256sum.txt.sig"
_CHUNK = 1 << 20
Opener = Callable[..., Any]


def release_key() -> pgp.RsaKey:
    armored = files("aap_demo.data.openshift").joinpath(KEY_FILE).read_text(encoding="utf-8")
    key = pgp.load_rsa_key(armored)
    if key.fingerprint != RED_HAT_RELEASE_KEY_2:
        raise pgp.SignatureError(
            f"The packaged release key is {key.fingerprint}, not Red Hat release key 2",
            hint="Reinstall aap-demo.",
        )
    return key


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(_CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def signed_sha256(version: str, name: str, *, opener: Opener = urllib.request.urlopen) -> str:
    """The bundle's sha256 from Red Hat's signed checksum file."""
    url = bundle_mirror.version_url(version, SIGNED_SUMS)
    try:
        with opener(url, timeout=bundle_mirror.TIMEOUT_SECONDS) as response:
            message = response.read().decode("utf-8")
    except OSError as exc:
        raise download.failed(f"the MicroShift {version} checksums", url) from exc
    text = pgp.verify_clearsigned(message, release_key())
    return pgp.sha256_for(text, name)


def ensure_bundle(
    ctx: Any,
    version: str,
    *,
    system: str = "",
    machine: str = "",
    opener: Opener = urllib.request.urlopen,
) -> Path:
    """A verified bundle for ``version`` in CRC's cache, downloading it if needed."""
    name = bundle_mirror.bundle_name(version, system=system, machine=machine)
    expected = signed_sha256(version, name, opener=opener)
    ctx.console.checkpoint(f"Red Hat signature verified for MicroShift {version} checksums")

    home = Path(ctx.env.get("HOME") or Path.home())
    cache = home / ".crc" / "cache"
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / name
    if target.is_file():
        if file_sha256(target) == expected:
            ctx.console.checkpoint(f"Using the cached MicroShift {version} bundle")
            return target
        ctx.console.warn(f"The cached {name} does not match its checksum; downloading it again")
        target.unlink()

    partial = cache / f"{name}.part"
    partial.unlink(missing_ok=True)
    url = bundle_mirror.version_url(version, name)
    ctx.console.progress(f"Downloading the MicroShift {version} bundle")
    result = ctx.runner.run(download.curl_argv(url, str(partial)))
    if not result.ok or not partial.is_file():
        partial.unlink(missing_ok=True)
        raise download.failed(f"the MicroShift {version} bundle", url)
    actual = file_sha256(partial)
    if actual != expected:
        partial.unlink(missing_ok=True)
        raise pgp.SignatureError(
            f"The MicroShift {version} bundle does not match Red Hat's signed checksum",
            hint=f"Expected {expected}, got {actual}. The file was deleted. Run create again.",
        )
    partial.replace(target)
    ctx.console.checkpoint(f"MicroShift {version} bundle downloaded and verified")
    return target


__all__ = ["RED_HAT_RELEASE_KEY_2", "ensure_bundle", "file_sha256", "release_key", "signed_sha256"]
