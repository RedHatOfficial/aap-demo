"""Trust the MicroShift ingress CA on the machine running aap-demo.

Ports ``includes/ingress-ca-trust.sh``. CRC issues a new ``ingress-ca``
whenever the VM is recreated. A browser that still trusts the previous CA
reports the current ``*.apps.127.0.0.1.nip.io`` certificate as invalid even
though the leaf chains to the CA that is serving it.
"""

from __future__ import annotations

import base64
import hashlib
import json
import platform
import re
from pathlib import Path
from typing import List, Optional

from aap_demo.core.context import AppContext
from aap_demo.exec import ssh as ssh_mod

ROUTER_SECRET = "router-certs-default"
ROUTER_NAMESPACE = "openshift-ingress"
CA_COMMON_NAME = "ingress-ca"
SYSTEM_KEYCHAIN = "/Library/Keychains/System.keychain"
_PEM = re.compile(
    r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
    re.DOTALL,
)


def pem_certificates(text: str) -> List[str]:
    return [match.group(0).strip() + "\n" for match in _PEM.finditer(text)]


def fingerprint(pem: str) -> str:
    """SHA-256 of the certificate's DER body, lowercase hex."""
    body = pem
    body = body.replace("-----BEGIN CERTIFICATE-----", "")
    body = body.replace("-----END CERTIFICATE-----", "")
    der = base64.b64decode("".join(body.split()))
    return hashlib.sha256(der).hexdigest()


def _enabled(ctx: AppContext) -> bool:
    return bool(ctx.config.get("trust.install_ca", True))


def fetch_cluster_ca(ctx: AppContext) -> Optional[str]:
    """The self-signed ingress CA, which is the last certificate in the router chain."""
    result = ctx.runner.run(
        [
            "kubectl",
            "get",
            "secret",
            ROUTER_SECRET,
            "-n",
            ROUTER_NAMESPACE,
            "-o",
            "json",
        ]
    )
    pems = _certs_from_secret(result.stdout if result.ok else "")
    if pems:
        return pems[-1]
    key = ssh_mod.detect_ssh_key(ssh_mod.crc_machines_dir(ctx.env))
    if key is None:
        return None
    remote = ssh_mod.exec_remote(
        ctx.runner,
        key,
        "cat",
        "/var/lib/microshift/certs/ingress-ca/ca.crt",
        sudo=True,
    )
    if not remote.ok:
        return None
    found = pem_certificates(remote.stdout)
    return found[-1] if found else None


def _certs_from_secret(raw: str) -> List[str]:
    if not raw.strip():
        return []
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return []
    encoded = str((payload.get("data") or {}).get("tls.crt") or "")
    if not encoded:
        return []
    try:
        text = base64.b64decode(encoded).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return []
    return pem_certificates(text)


def system_trusts(ctx: AppContext, path: Path, *, system: Optional[str] = None) -> bool:
    """True when the OS trust store accepts ``path`` for TLS."""
    kind = system or platform.system()
    if kind == "Darwin":
        result = ctx.runner.run(["security", "verify-cert", "-p", "ssl", "-c", str(path)])
        return bool(result.ok)
    for candidate in (
        Path("/etc/pki/ca-trust/source/anchors/crc-ingress-ca.crt"),
        Path("/usr/local/share/ca-certificates/crc-ingress-ca.crt"),
    ):
        if not candidate.is_file():
            continue
        try:
            return fingerprint(candidate.read_text(encoding="utf-8")) == fingerprint(
                path.read_text(encoding="utf-8")
            )
        except (OSError, ValueError):
            return False
    return False


def install(ctx: AppContext, *, system: Optional[str] = None) -> bool:
    """Import the cluster ingress CA into the OS trust store.

    The CA is the one CRC already issued for the router. Bash deploy trusts
    that same certificate in ``install_ingress_ca_trust`` and leaves the
    router secret alone.

    Returns True when that CA is trusted. A missing router secret is quiet:
    create can run this before ingress exists, and deploy will try again.
    """
    if not _enabled(ctx):
        return False
    pem = fetch_cluster_ca(ctx)
    if pem is None:
        return False
    destination = ctx.paths.ingress_ca
    destination.parent.mkdir(parents=True, exist_ok=True)
    current = fingerprint(pem)
    if destination.is_file():
        try:
            saved = fingerprint(destination.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            saved = ""
    else:
        saved = ""
    destination.write_text(pem, encoding="utf-8")
    destination.chmod(0o644)
    kind = system or platform.system()
    if saved == current and system_trusts(ctx, destination, system=kind):
        return True
    ctx.console.step("Trusting the ingress CA")
    trusted = _import(ctx, destination, system=kind)
    if trusted:
        ctx.console.checkpoint("Ingress CA trusted")
        ctx.console.out("  Quit the browser and reopen the AAP URL if it still warns.")
        return True
    ctx.console.warn(
        "Ingress CA saved but not trusted yet. "
        f"On this Mac, approve it with: sudo security add-trusted-cert -d -r trustRoot "
        f"-k {SYSTEM_KEYCHAIN} {destination}"
    )
    return False


def _import(ctx: AppContext, path: Path, *, system: str) -> bool:
    if system == "Darwin":
        return _import_macos(ctx, path)
    return _import_linux(ctx, path)


def _import_macos(ctx: AppContext, path: Path) -> bool:
    """Replace the keychain's ingress CA when sudo needs no password.

    ``CommandRunner`` captures output and leaves stdin on the terminal, so a
    sudo password prompt would hang behind the checklist. ``sudo -n`` fails
    instead, and ``install`` then prints the command for the user to run.
    """
    if not ctx.runner.run(["sudo", "-n", "true"]).ok:
        return False
    while True:
        removed = ctx.runner.run(
            [
                "sudo",
                "-n",
                "security",
                "delete-certificate",
                "-c",
                CA_COMMON_NAME,
                SYSTEM_KEYCHAIN,
            ]
        )
        if not removed.ok:
            break
    added = ctx.runner.run(
        [
            "sudo",
            "-n",
            "security",
            "add-trusted-cert",
            "-d",
            "-r",
            "trustRoot",
            "-k",
            SYSTEM_KEYCHAIN,
            str(path),
        ]
    )
    return bool(added.ok) and system_trusts(ctx, path, system="Darwin")


def _import_linux(ctx: AppContext, path: Path) -> bool:
    anchor = Path("/etc/pki/ca-trust/source/anchors/crc-ingress-ca.crt")
    if anchor.parent.is_dir():
        copied = ctx.runner.run(["sudo", "cp", str(path), str(anchor)])
        updated = ctx.runner.run(["sudo", "update-ca-trust"])
        return bool(copied.ok and updated.ok)
    debian = Path("/usr/local/share/ca-certificates/crc-ingress-ca.crt")
    if debian.parent.is_dir():
        copied = ctx.runner.run(["sudo", "cp", str(path), str(debian)])
        updated = ctx.runner.run(["sudo", "update-ca-certificates"])
        return bool(copied.ok and updated.ok)
    return False


def describe(ctx: AppContext, *, system: Optional[str] = None) -> dict:
    """Status fields for the TLS block. Missing file keeps the historical wording."""
    path = ctx.paths.ingress_ca
    if not path.is_file():
        return {
            "ingress_ca_file": "not saved",
            "browser_trust": "unknown (run aap-demo deploy or create)",
        }
    kind = system or platform.system()
    trusted = False
    try:
        trusted = system_trusts(ctx, path, system=kind)
    except OSError:
        trusted = False
    if kind == "Darwin":
        browser = "trusted (macOS keychain)" if trusted else "not trusted"
    else:
        browser = "trusted (system ca-trust)" if trusted else "not trusted"
    return {
        "ingress_ca_file": str(path),
        "system_trust": "trusted" if trusted else "not trusted",
        "browser_trust": browser,
    }
