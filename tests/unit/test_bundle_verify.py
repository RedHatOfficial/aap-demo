"""The Red Hat signature check and bundle download for --ocp-version (ADR-041).

The fixtures are the real MicroShift 5.0.0 ``sha256sum.txt`` and its
clearsigned ``sha256sum.txt.sig`` from mirror.openshift.com.
"""

from __future__ import annotations

import io
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

import pytest

from aap_demo.exec.runner import CompletedCommand
from aap_demo.infra import bundle_fetch, pgp

FIXTURES = Path(__file__).parent.parent / "fixtures" / "microshift-5.0.0"
SIGNED = (FIXTURES / "sha256sum.txt.sig").read_text(encoding="utf-8")
SUMS = (FIXTURES / "sha256sum.txt").read_text(encoding="utf-8")
ARM64 = "crc_microshift_vfkit_5.0.0_arm64.crcbundle"
ARM64_SHA = "48b150b27389aee0"


@pytest.fixture(scope="module")
def key() -> pgp.RsaKey:
    return bundle_fetch.release_key()


def test_the_packaged_key_is_red_hat_release_key_2(key) -> None:
    assert key.fingerprint == "567E347AD0044ADE55BA8A5F199E2F91FD431D51"
    assert key.n.bit_length() == 4096


def test_the_real_5_0_signature_verifies(key) -> None:
    text = pgp.verify_clearsigned(SIGNED, key)
    assert text.strip() == SUMS.strip()
    assert pgp.sha256_for(text, ARM64).startswith(ARM64_SHA)


def test_a_changed_checksum_is_refused(key) -> None:
    tampered = SIGNED.replace(ARM64_SHA, "0" * len(ARM64_SHA), 1)
    with pytest.raises(pgp.SignatureError, match="does not match the signed text"):
        pgp.verify_clearsigned(tampered, key)


def test_a_changed_signature_is_refused(key) -> None:
    head, armor = SIGNED.split("-----BEGIN PGP SIGNATURE-----")
    lines = armor.splitlines()
    # Flip one character in the middle of the base64 body.
    middle = len(lines) // 2
    lines[middle] = ("A" if lines[middle][0] != "A" else "B") + lines[middle][1:]
    with pytest.raises(pgp.SignatureError):
        pgp.verify_clearsigned(head + "-----BEGIN PGP SIGNATURE-----" + "\n".join(lines), key)


def test_another_key_is_refused(key) -> None:
    other = replace(key, fingerprint="0" * 40, key_id="0" * 16)
    with pytest.raises(pgp.SignatureError, match="not 0000000000000000"):
        pgp.verify_clearsigned(SIGNED, other)


def test_a_right_issuer_with_the_wrong_modulus_is_refused(key) -> None:
    forged = replace(key, n=key.n - 2)
    with pytest.raises(pgp.SignatureError, match="does not verify"):
        pgp.verify_clearsigned(SIGNED, forged)


def test_other_hashes_and_plain_text_are_refused(key) -> None:
    with pytest.raises(pgp.SignatureError, match="Unsupported hash"):
        pgp.verify_clearsigned(SIGNED.replace("Hash: SHA256", "Hash: SHA1", 1), key)
    with pytest.raises(pgp.SignatureError, match="Not a clearsigned message"):
        pgp.verify_clearsigned(SUMS, key)


def test_checksum_lookup_needs_exactly_one_entry() -> None:
    with pytest.raises(pgp.SignatureError, match="no single entry"):
        pgp.sha256_for(SUMS, "crc_microshift_vfkit_5.0.0_arm65.crcbundle")
    doubled = SUMS + SUMS.splitlines()[0] + "\n"
    name = SUMS.splitlines()[0].split()[1]
    with pytest.raises(pgp.SignatureError, match="no single entry"):
        pgp.sha256_for(doubled, name)


def test_a_changed_key_file_is_refused(monkeypatch, key) -> None:
    monkeypatch.setattr(pgp, "load_rsa_key", lambda armored: replace(key, fingerprint="1" * 40))
    with pytest.raises(pgp.SignatureError, match="not Red Hat release key 2"):
        bundle_fetch.release_key()


# --- ensure_bundle ----------------------------------------------------------


class _Console:
    def __init__(self) -> None:
        self.lines: list = []

    def checkpoint(self, text: str) -> None:
        self.lines.append(("ok", text))

    def progress(self, text: str) -> None:
        self.lines.append(("progress", text))

    def warn(self, text: str) -> None:
        self.lines.append(("warn", text))


class _CurlRunner:
    """Writes ``payload`` to curl's ``-o`` path, like a finished download."""

    def __init__(self, payload: bytes, *, ok: bool = True) -> None:
        self.payload = payload
        self.ok = ok
        self.calls: list = []

    def run(self, argv, **_kwargs):
        self.calls.append(list(argv))
        if self.ok:
            Path(argv[argv.index("-o") + 1]).write_bytes(self.payload)
        return CompletedCommand(argv=tuple(argv), returncode=0 if self.ok else 22)


def _signed_opener(url: str, timeout: int):
    assert url.endswith("/5.0.0/sha256sum.txt.sig")
    return io.BytesIO(SIGNED.encode())


def _ctx(tmp_path: Path, runner) -> SimpleNamespace:
    return SimpleNamespace(env={"HOME": str(tmp_path)}, console=_Console(), runner=runner)


def test_a_download_that_fails_the_checksum_is_deleted(tmp_path) -> None:
    ctx = _ctx(tmp_path, _CurlRunner(b"not the bundle"))
    with pytest.raises(pgp.SignatureError, match="does not match Red Hat's signed checksum"):
        bundle_fetch.ensure_bundle(
            ctx, "5.0.0", system="Darwin", machine="arm64", opener=_signed_opener
        )
    assert list((tmp_path / ".crc" / "cache").iterdir()) == []


def test_a_failed_download_leaves_nothing(tmp_path) -> None:
    ctx = _ctx(tmp_path, _CurlRunner(b"", ok=False))
    with pytest.raises(Exception, match="Failed to download the MicroShift 5.0.0 bundle"):
        bundle_fetch.ensure_bundle(
            ctx, "5.0.0", system="Darwin", machine="arm64", opener=_signed_opener
        )
    assert list((tmp_path / ".crc" / "cache").iterdir()) == []


def test_a_verified_download_moves_into_crc_cache(tmp_path, monkeypatch) -> None:
    expected = pgp.sha256_for(pgp.verify_clearsigned(SIGNED, bundle_fetch.release_key()), ARM64)
    monkeypatch.setattr(bundle_fetch, "file_sha256", lambda path: expected)
    runner = _CurlRunner(b"bundle bytes")
    ctx = _ctx(tmp_path, runner)

    path = bundle_fetch.ensure_bundle(
        ctx, "5.0.0", system="Darwin", machine="arm64", opener=_signed_opener
    )

    assert path == tmp_path / ".crc" / "cache" / ARM64
    assert path.read_bytes() == b"bundle bytes"
    assert runner.calls[0][-1].endswith(f"/5.0.0/{ARM64}")
    assert not (tmp_path / ".crc" / "cache" / f"{ARM64}.part").exists()


def test_a_matching_cached_bundle_is_not_downloaded_again(tmp_path, monkeypatch) -> None:
    expected = pgp.sha256_for(pgp.verify_clearsigned(SIGNED, bundle_fetch.release_key()), ARM64)
    cache = tmp_path / ".crc" / "cache"
    cache.mkdir(parents=True)
    (cache / ARM64).write_bytes(b"cached")
    monkeypatch.setattr(bundle_fetch, "file_sha256", lambda path: expected)
    runner = _CurlRunner(b"new")
    ctx = _ctx(tmp_path, runner)

    bundle_fetch.ensure_bundle(
        ctx, "5.0.0", system="Darwin", machine="arm64", opener=_signed_opener
    )

    assert runner.calls == []
    assert ("ok", "Using the cached MicroShift 5.0.0 bundle") in ctx.console.lines


def test_a_bad_signature_stops_before_any_download(tmp_path) -> None:
    runner = _CurlRunner(b"x")
    ctx = _ctx(tmp_path, runner)

    def tampered(url: str, timeout: int):
        return io.BytesIO(SIGNED.replace(ARM64_SHA, "f" * len(ARM64_SHA), 1).encode())

    with pytest.raises(pgp.SignatureError):
        bundle_fetch.ensure_bundle(ctx, "5.0.0", system="Darwin", machine="arm64", opener=tampered)
    assert runner.calls == []
