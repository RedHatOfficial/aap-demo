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
import shutil
import tempfile
from pathlib import Path
from typing import List, Optional

import yaml

from aap_demo.core.context import AppContext
from aap_demo.exec import kubectl
from aap_demo.exec import ssh as ssh_mod

#: One label under this suffix, which is what ``*.apps.127.0.0.1.nip.io`` covers.
NIPIO_SUFFIX = "127.0.0.1.nip.io"
ROUTER_POD_LABEL = "ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default"

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


def issue_with_mkcert(ctx: AppContext, *, system: Optional[str] = None) -> bool:
    """Serve ingress with a certificate signed by the local mkcert CA.

    That CA is already in the login or system trust store on a machine where
    ``mkcert -install`` has been run, so the route verifies without a second
    approval dialog. Returns False when mkcert is absent or its CA is not
    trusted, and leaves the current router certificate alone.
    """
    if not bool(ctx.config.get("trust.mkcert", True)):
        return False
    caroot = ctx.runner.run(["mkcert", "-CAROOT"])
    if not caroot.ok or not caroot.stdout.strip():
        return False
    root = Path(caroot.stdout.strip()) / "rootCA.pem"
    if not root.is_file():
        return False
    kind = system or platform.system()
    if kind == "Darwin" and not system_trusts(ctx, root, system=kind):
        return False
    work = Path(tempfile.mkdtemp(prefix="aap-ingress-"))
    cert_path = work / "tls.crt"
    key_path = work / "tls.key"
    try:
        issued = ctx.runner.run(
            [
                "mkcert",
                "-cert-file",
                str(cert_path),
                "-key-file",
                str(key_path),
                f"*.apps.{NIPIO_SUFFIX}",
                f"apps.{NIPIO_SUFFIX}",
            ]
        )
        if not issued.ok or not cert_path.is_file() or not key_path.is_file():
            return False
        chain = cert_path.read_text(encoding="utf-8")
        root_pem = root.read_text(encoding="utf-8")
        if "BEGIN CERTIFICATE" not in chain:
            return False
        if root_pem.strip() not in chain:
            chain = chain.rstrip() + "\n" + root_pem
            if not chain.endswith("\n"):
                chain += "\n"
        secret = {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {"name": ROUTER_SECRET, "namespace": ROUTER_NAMESPACE},
            "type": "Opaque",
            "stringData": {"tls.crt": chain, "tls.key": key_path.read_text(encoding="utf-8")},
        }
        applied = kubectl.apply_stdin(ctx.runner, yaml.safe_dump(secret))
        if not applied.ok:
            return False
        ctx.runner.run(
            [
                "kubectl",
                "delete",
                "pod",
                "-n",
                ROUTER_NAMESPACE,
                "-l",
                ROUTER_POD_LABEL,
                "--wait=false",
            ]
        )
        ctx.console.checkpoint("Ingress certificate is trusted locally")
        return True
    finally:
        shutil.rmtree(work, ignore_errors=True)


def install(ctx: AppContext, *, system: Optional[str] = None) -> bool:
    """Prefer a mkcert ingress certificate, otherwise trust CRC's ingress CA.

    Returns True when the certificate the router will present is trusted.
    A missing router secret is quiet: create can run this before ingress
    exists, and deploy will try again.
    """
    if not _enabled(ctx):
        return False
    if issue_with_mkcert(ctx, system=system):
        return True
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
    while True:
        removed = ctx.runner.run(
            [
                "sudo",
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
