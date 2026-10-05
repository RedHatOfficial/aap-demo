"""CRC download, checksum, and archive extraction. No network."""

from __future__ import annotations

import gzip
import hashlib
import io
import os
import tarfile
from pathlib import Path

from aap_demo.exec.runner import CompletedCommand, FakeRunner
from aap_demo.infra import crc_install
from aap_demo.infra.crc import managed_crc_release


def _tarball() -> bytes:
    payload = b"#!/bin/sh\n"
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:xz") as tar:
        info = tarfile.TarInfo("crc-linux-2.64.0-amd64/crc")
        info.size = len(payload)
        info.mode = 0o755
        tar.addfile(info, io.BytesIO(payload))
    return buffer.getvalue()


def _odc_header(*, name: str, mode: int, data: bytes) -> bytes:
    raw_name = name.encode() + b"\0"
    fields = [
        f"{0o070707:06o}",
        f"{0:06o}",
        f"{0:06o}",
        f"{mode:06o}",
        f"{0:06o}",
        f"{0:06o}",
        f"{1:06o}",
        f"{0:06o}",
        f"{0:011o}",
        f"{len(raw_name):06o}",
        f"{len(data):011o}",
    ]
    return "".join(fields).encode() + raw_name + data


def test_install_linux_tarball_verifies_the_checksum_and_prefers_the_binary(
    app_ctx, fake_runner: FakeRunner, tmp_path: Path
) -> None:
    blob = _tarball()
    digest = hashlib.sha256(blob).hexdigest()
    filename = "crc-linux-amd64.tar.xz"
    app_ctx.env["HOME"] = str(tmp_path)
    app_ctx.env["AAP_DEMO_CRC_INSTALL_OS"] = "Linux"
    app_ctx.env["AAP_DEMO_CRC_INSTALL_MACHINE"] = "x86_64"

    def curl(argv):
        dest = Path(argv[argv.index("-o") + 1])
        url = argv[-1]
        if url.endswith("sha256sum.txt"):
            dest.write_text(f"{digest}  {filename}\n", encoding="utf-8")
        else:
            dest.write_bytes(blob)
        return CompletedCommand(argv=tuple(argv), returncode=0, stdout="")

    fake_runner.register("curl", curl)
    install_dir = crc_install.install_managed_release(app_ctx, current=None)

    assert (install_dir / "crc").read_bytes() == b"#!/bin/sh\n"
    assert (tmp_path / ".local" / "bin" / "crc").read_bytes() == b"#!/bin/sh\n"
    assert app_ctx.env["PATH"].split(os.pathsep)[0] == str(install_dir)
    assert managed_crc_release() in str(install_dir)


def test_extract_gzip_odc_unpacks_the_macos_payload_layout(tmp_path: Path) -> None:
    directory = _odc_header(name="usr/local/crc", mode=0o040755, data=b"")
    binary = _odc_header(name="usr/local/crc/crc", mode=0o100755, data=b"crc-bin")
    trailer = _odc_header(name="TRAILER!!!", mode=0, data=b"")
    payload = tmp_path / "Payload"
    payload.write_bytes(gzip.compress(directory + binary + trailer))

    dest = tmp_path / "out"
    crc_install.extract_gzip_odc(payload, dest)

    assert (dest / "usr" / "local" / "crc" / "crc").read_bytes() == b"crc-bin"


def test_remove_old_bundle_cache_deletes_only_the_named_version(tmp_path: Path) -> None:
    cache = tmp_path / ".crc" / "cache"
    cache.mkdir(parents=True)
    old = cache / "crc_microshift_vfkit_4.21.0_arm64"
    old.mkdir()
    (old / "bundle").write_text("old", encoding="utf-8")
    keep = cache / "crc_microshift_vfkit_4.22.13_arm64"
    keep.mkdir()

    assert crc_install.remove_old_bundle_cache(tmp_path, "4.21.0") == 1
    assert not old.exists()
    assert keep.is_dir()
