"""Check a clearsigned OpenPGP message from Red Hat, with the standard library (ADR-041).

The MicroShift bundle checksums are published as ``sha256sum.txt.sig``: a
cleartext-signed text (RFC 9580 section 7) with a v4 RSA signature over SHA-256.
This module checks exactly that format against a pinned key and refuses
everything else. It is not a general OpenPGP implementation.
"""

from __future__ import annotations

import base64
import hashlib
import re
from dataclasses import dataclass
from typing import Dict, Iterator, List, Optional, Tuple

from aap_demo.core.errors import AapDemoError

_SIG_TEXT = 0x01
_RSA = 1
_SHA256 = 8
_TAG_SIGNATURE = 2
_TAG_PUBLIC_KEY = 6
_SUB_ISSUER = 16
_SUB_ISSUER_FPR = 33
#: DER prefix of a SHA-256 DigestInfo (RFC 8017 section 9.2).
_SHA256_DIGEST_INFO = bytes.fromhex("3031300d060960864801650304020105000420")


class SignatureError(AapDemoError):
    """The signature is missing, malformed, from another key, or does not verify."""


@dataclass(frozen=True)
class RsaKey:
    fingerprint: str
    key_id: str
    n: int
    e: int


def _dearmor(block: str, kind: str) -> bytes:
    begin = f"-----BEGIN PGP {kind}-----"
    end = f"-----END PGP {kind}-----"
    if begin not in block or end not in block:
        raise SignatureError(f"No PGP {kind.lower()} found")
    body = block.split(begin, 1)[1].split(end, 1)[0]
    # Armor headers end at the first blank line.
    parts = re.split(r"\r?\n\r?\n", body.lstrip("\r\n"), maxsplit=1)
    data = parts[1] if len(parts) == 2 else parts[0]
    lines = [line.strip() for line in data.splitlines() if line.strip()]
    if lines and lines[-1].startswith("="):
        lines = lines[:-1]
    try:
        return base64.b64decode("".join(lines), validate=True)
    except ValueError as exc:
        raise SignatureError(f"Bad base64 in the PGP {kind.lower()}") from exc


def _packets(data: bytes) -> Iterator[Tuple[int, bytes]]:
    """``(tag, body)`` for each packet. Old and new header formats."""
    pos = 0
    while pos < len(data):
        header = data[pos]
        if not header & 0x80:
            raise SignatureError("Not an OpenPGP packet")
        if header & 0x40:
            tag = header & 0x3F
            first = data[pos + 1]
            if first < 192:
                length, pos = first, pos + 2
            elif first < 224:
                length, pos = ((first - 192) << 8) + data[pos + 2] + 192, pos + 3
            elif first == 255:
                length, pos = int.from_bytes(data[pos + 2 : pos + 6], "big"), pos + 6
            else:
                raise SignatureError("Partial-length packets are not supported")
        else:
            tag = (header >> 2) & 0x0F
            size = {0: 1, 1: 2, 2: 4}.get(header & 0x03)
            if size is None:
                raise SignatureError("Indeterminate-length packets are not supported")
            length = int.from_bytes(data[pos + 1 : pos + 1 + size], "big")
            pos += 1 + size
        body = data[pos : pos + length]
        if len(body) != length:
            raise SignatureError("Truncated OpenPGP packet")
        yield tag, body
        pos += length


def _mpi(data: bytes, pos: int) -> Tuple[int, int]:
    bits = int.from_bytes(data[pos : pos + 2], "big")
    size = (bits + 7) // 8
    return int.from_bytes(data[pos + 2 : pos + 2 + size], "big"), pos + 2 + size


def load_rsa_key(armored: str) -> RsaKey:
    """The primary key of an armored public key block. Must be v4 RSA."""
    for tag, body in _packets(_dearmor(armored, "PUBLIC KEY BLOCK")):
        if tag != _TAG_PUBLIC_KEY:
            continue
        if body[0] != 4 or body[5] != _RSA:
            raise SignatureError("Only v4 RSA keys are supported")
        n, pos = _mpi(body, 6)
        e, _ = _mpi(body, pos)
        digest = hashlib.sha1(b"\x99" + len(body).to_bytes(2, "big") + body).hexdigest().upper()
        return RsaKey(fingerprint=digest, key_id=digest[-16:], n=n, e=e)
    raise SignatureError("No public key in the key block")


def _subpackets(data: bytes) -> Dict[int, bytes]:
    out: Dict[int, bytes] = {}
    pos = 0
    while pos < len(data):
        first = data[pos]
        if first < 192:
            length, pos = first, pos + 1
        elif first < 255:
            length, pos = ((first - 192) << 8) + data[pos + 1] + 192, pos + 2
        else:
            length, pos = int.from_bytes(data[pos + 1 : pos + 5], "big"), pos + 5
        kind = data[pos] & 0x7F
        out[kind] = data[pos + 1 : pos + length]
        pos += length
    return out


def _canonical(text: str) -> bytes:
    """Lines joined with CRLF, trailing spaces and tabs removed (RFC 9580 7.2)."""
    lines = text.split("\n")
    return "\r\n".join(line.rstrip(" \t\r") for line in lines).encode("utf-8")


def _split_clearsigned(message: str) -> Tuple[str, str]:
    head = "-----BEGIN PGP SIGNED MESSAGE-----"
    sig = "-----BEGIN PGP SIGNATURE-----"
    if head not in message or sig not in message:
        raise SignatureError("Not a clearsigned message")
    after = message.split(head, 1)[1]
    headers, _, rest = after.lstrip("\r\n").partition("\n\n")
    hashes = [h.split(":", 1)[1].strip() for h in headers.splitlines() if h.startswith("Hash:")]
    if hashes and any(h.upper() != "SHA256" for h in hashes):
        raise SignatureError(f"Unsupported hash: {', '.join(hashes)}")
    text, _, signature = rest.partition(sig)
    # The line ending before the signature armor is not part of the signed text.
    if text.endswith("\r\n"):
        text = text[:-2]
    elif text.endswith("\n"):
        text = text[:-1]
    lines = [line[2:] if line.startswith("- ") else line for line in text.split("\n")]
    return "\n".join(lines), sig + signature


def verify_clearsigned(message: str, key: RsaKey) -> str:
    """The signed text when ``key`` made a valid signature over it. Raises otherwise."""
    text, armored = _split_clearsigned(message)
    signatures = [b for t, b in _packets(_dearmor(armored, "SIGNATURE")) if t == _TAG_SIGNATURE]
    if len(signatures) != 1:
        raise SignatureError("Expected exactly one signature")
    body = signatures[0]
    version, sig_type, pub_algo, hash_algo = body[0], body[1], body[2], body[3]
    if (version, sig_type, pub_algo, hash_algo) != (4, _SIG_TEXT, _RSA, _SHA256):
        raise SignatureError("Only v4 RSA SHA-256 text signatures are supported")
    hashed_len = int.from_bytes(body[4:6], "big")
    hashed = body[6 : 6 + hashed_len]
    pos = 6 + hashed_len
    unhashed_len = int.from_bytes(body[pos : pos + 2], "big")
    unhashed = body[pos + 2 : pos + 2 + unhashed_len]
    pos += 2 + unhashed_len
    left16 = body[pos : pos + 2]
    value, _ = _mpi(body, pos + 2)

    issuer = _issuer(_subpackets(hashed), _subpackets(unhashed))
    if issuer is None or not key.fingerprint.endswith(issuer):
        raise SignatureError(f"Signed by {issuer or 'an unknown key'}, not {key.key_id}")

    prefix = body[: 6 + hashed_len]
    trailer = b"\x04\xff" + len(prefix).to_bytes(4, "big")
    digest = hashlib.sha256(_canonical(text) + prefix + trailer).digest()
    if digest[:2] != left16:
        raise SignatureError("Signature does not match the signed text")
    size = (key.n.bit_length() + 7) // 8
    encoded = pow(value, key.e, key.n).to_bytes(size, "big")
    padding = size - 3 - len(_SHA256_DIGEST_INFO) - len(digest)
    expected = b"\x00\x01" + b"\xff" * padding + b"\x00" + _SHA256_DIGEST_INFO + digest
    if padding < 8 or encoded != expected:
        raise SignatureError("Signature does not verify")
    return text


def _issuer(hashed: Dict[int, bytes], unhashed: Dict[int, bytes]) -> Optional[str]:
    for packets in (hashed, unhashed):
        if _SUB_ISSUER_FPR in packets and len(packets[_SUB_ISSUER_FPR]) == 21:
            return packets[_SUB_ISSUER_FPR][1:].hex().upper()
        if _SUB_ISSUER in packets:
            return packets[_SUB_ISSUER].hex().upper()
    return None


def sha256_for(text: str, filename: str) -> str:
    """The checksum for ``filename`` in a verified ``sha256sum.txt``."""
    matches: List[str] = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].lstrip("*") == filename:
            matches.append(parts[0].lower())
    if len(matches) != 1 or not re.fullmatch(r"[0-9a-f]{64}", matches[0]):
        raise SignatureError(f"The signed checksums have no single entry for {filename}")
    return matches[0]


__all__ = ["RsaKey", "SignatureError", "load_rsa_key", "sha256_for", "verify_clearsigned"]
