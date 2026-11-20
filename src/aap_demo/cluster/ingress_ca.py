"""Trust the MicroShift ingress CA on the machine running aap-demo.

Ports ``includes/ingress-ca-trust.sh``. CRC issues a new ``ingress-ca``
whenever the VM is recreated. A browser that still trusts the previous CA
reports the current ``*.apps.127.0.0.1.nip.io`` certificate as invalid even
though the leaf chains to the CA that is serving it.

Chrome, Chromium and Firefox on Linux read NSS databases instead of the system
store, so Linux needs both. System trust needs sudo. NSS trust does not.
"""

from __future__ import annotations

import base64
import ctypes
import hashlib
import json
import platform
import re
import shlex
import shutil
import ssl
import subprocess
import sys
from pathlib import Path
from typing import List, Optional

from aap_demo.core.context import AppContext
from aap_demo.exec import ssh as ssh_mod

ROUTER_SECRET = "router-certs-default"
ROUTER_NAMESPACE = "openshift-ingress"
CA_COMMON_NAME = "ingress-ca"
SERVER_AUTH_OID = "1.3.6.1.5.5.7.3.1"
SYSTEM_KEYCHAIN = "/Library/Keychains/System.keychain"
RHEL_ANCHOR = Path("/etc/pki/ca-trust/source/anchors/crc-ingress-ca.crt")
DEBIAN_ANCHOR = Path("/usr/local/share/ca-certificates/crc-ingress-ca.crt")
NSS_NICKNAME = "crc-ingress-ca"
_SHA1_LINE = re.compile(r"^SHA-1 hash: ([0-9A-Fa-f]{40})$", re.MULTILINE)
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
    if kind == "Windows":
        try:
            pem = path.read_text(encoding="utf-8")
        except OSError:
            return False
        return _windows_store_contains(ctx, _windows_thumbprint(pem))
    for candidate in (RHEL_ANCHOR, DEBIAN_ANCHOR):
        if not candidate.is_file():
            continue
        try:
            return fingerprint(candidate.read_text(encoding="utf-8")) == fingerprint(
                path.read_text(encoding="utf-8")
            )
        except (OSError, ValueError):
            return False
    return False


def _certutil_available(system: str) -> bool:
    """Windows ships an unrelated ``certutil``, so only Linux counts."""
    return system == "Linux" and shutil.which("certutil") is not None


def _windows_thumbprint(pem: str) -> str:
    """Windows certificate stores identify certificates by their SHA-1 thumbprint."""
    body = pem.replace("-----BEGIN CERTIFICATE-----", "")
    body = body.replace("-----END CERTIFICATE-----", "")
    der = base64.b64decode("".join(body.split()))
    # SHA-1 is used only for the Windows store's certificate identifier.
    return hashlib.sha1(der).hexdigest().upper()


def _windows_store_contains(_ctx: AppContext, thumbprint: str) -> bool:
    """Check the Current User Root store using Python's Windows SSL bindings."""
    enum_certificates = getattr(ssl, "enum_certificates", None)
    if enum_certificates is None:
        return False
    try:
        certificates = enum_certificates("ROOT")
    except (OSError, ValueError):
        return False
    return any(
        encoding == "x509_asn"
        and hashlib.sha1(der).hexdigest().upper() == thumbprint
        and (trust is True or SERVER_AUTH_OID in trust)
        for der, encoding, trust in certificates
    )


def _windows_add_certificate(path: Path) -> bool:
    """Use a bounded Python worker to add a certificate through CryptoAPI."""
    worker = (
        "from pathlib import Path; import sys; "
        "from aap_demo.cluster.ingress_ca import _windows_add_certificate_in_process; "
        "sys.exit(0 if _windows_add_certificate_in_process(Path(sys.argv[1])) else 1)"
    )
    try:
        result = subprocess.run(
            [sys.executable, "-c", worker, str(path)],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def _windows_add_certificate_in_process(path: Path) -> bool:
    """Add a DER-encoded certificate to Current User Root through CryptoAPI."""
    win_dll = getattr(ctypes, "WinDLL", None)
    if win_dll is None:
        return False
    try:
        pem = path.read_text(encoding="utf-8")
        body = pem.replace("-----BEGIN CERTIFICATE-----", "")
        body = body.replace("-----END CERTIFICATE-----", "")
        der = base64.b64decode("".join(body.split()), validate=True)
        crypt32 = win_dll("crypt32", use_last_error=True)
        open_store = crypt32.CertOpenStore
        open_store.argtypes = [
            ctypes.c_void_p,
            ctypes.c_uint32,
            ctypes.c_void_p,
            ctypes.c_uint32,
            ctypes.c_void_p,
        ]
        open_store.restype = ctypes.c_void_p
        store = open_store(
            ctypes.c_void_p(10),
            0x00010001,
            None,
            0x00010000,
            ctypes.cast(ctypes.c_wchar_p("ROOT"), ctypes.c_void_p),
        )
        if not store:
            return False
        try:
            add_certificate = crypt32.CertAddEncodedCertificateToStore
            add_certificate.argtypes = [
                ctypes.c_void_p,
                ctypes.c_uint32,
                ctypes.POINTER(ctypes.c_ubyte),
                ctypes.c_uint32,
                ctypes.c_uint32,
                ctypes.c_void_p,
            ]
            add_certificate.restype = ctypes.c_int
            encoded = ctypes.create_string_buffer(der)
            return bool(
                add_certificate(
                    store,
                    0x00010001,
                    ctypes.cast(encoded, ctypes.POINTER(ctypes.c_ubyte)),
                    len(der),
                    3,
                    None,
                )
            )
        finally:
            close_store = crypt32.CertCloseStore
            close_store.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
            close_store.restype = ctypes.c_int
            close_store(store, 0)
    except (OSError, ValueError, TypeError, AttributeError):
        return False


def _default_nss_database(ctx: AppContext) -> Path:
    return Path(ctx.env.get("HOME") or Path.home()) / ".pki" / "nssdb"


def _nss_databases(ctx: AppContext) -> List[Path]:
    """Chromium's databases and every Firefox profile on this machine."""
    home = Path(ctx.env.get("HOME") or Path.home())
    found = [
        candidate
        for candidate in (_default_nss_database(ctx), home / ".local" / "share" / "pki" / "nssdb")
        if (candidate / "cert9.db").is_file()
    ]
    firefox = home / ".mozilla" / "firefox"
    if firefox.is_dir():
        found.extend(
            profile for profile in sorted(firefox.iterdir()) if (profile / "cert9.db").is_file()
        )
    return found


def _nss_holds(ctx: AppContext, database: Path, expected: str) -> bool:
    """True when the nickname names only the expected CA and may issue server certs."""
    listed = ctx.runner.run(["certutil", "-d", f"sql:{database}", "-L", "-n", NSS_NICKNAME, "-a"])
    if not listed.ok:
        return False
    pems = pem_certificates(listed.stdout)
    if not pems or any(fingerprint(pem) != expected for pem in pems):
        return False
    table = ctx.runner.run(["certutil", "-d", f"sql:{database}", "-L"])
    for line in table.stdout.splitlines() if table.ok else []:
        fields = line.split()
        if len(fields) == 2 and fields[0] == NSS_NICKNAME:
            # In the first field, only C trusts a CA to issue server certificates.
            return "C" in fields[1].split(",")[0]
    return False


def _browser_trust(ctx: AppContext, path: Path, *, system: str) -> str:
    """Status wording. Trust is reported only after every database was read."""
    if system == "Windows":
        return (
            "trusted (Windows Current User Root)"
            if system_trusts(ctx, path, system=system)
            else "not trusted"
        )
    databases = _nss_databases(ctx)
    if not _certutil_available(system):
        return "unknown (install nss-tools to check Chrome and Firefox)"
    if not databases:
        return "unknown (no Chrome or Firefox certificate database found)"
    expected = fingerprint(path.read_text(encoding="utf-8"))
    if all(_nss_holds(ctx, database, expected) for database in databases):
        return "trusted (Chrome/Firefox NSS)"
    return "not trusted"


def _linux_trust_complete(ctx: AppContext, path: Path, *, system: str) -> bool:
    if not system_trusts(ctx, path, system=system):
        return False
    if _certutil_available(system):
        return _browser_trust(ctx, path, system=system).startswith("trusted")
    # No certutil and no browser database is a machine without a browser.
    return not _nss_databases(ctx)


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
    if saved == current and _trust_complete(ctx, destination, system=kind):
        return True
    ctx.console.step("Trusting the ingress CA")
    problems = _import(ctx, destination, system=kind)
    if not problems:
        ctx.console.checkpoint("Ingress CA trusted")
        ctx.console.out("  Quit the browser and reopen the AAP URL if it still warns.")
        return True
    for problem in problems:
        ctx.console.warn(f"Ingress CA saved but not trusted yet. {problem}")
    return False


def _trust_complete(ctx: AppContext, path: Path, *, system: str) -> bool:
    if system == "Darwin":
        return system_trusts(ctx, path, system=system)
    if system == "Windows":
        return system_trusts(ctx, path, system=system)
    return _linux_trust_complete(ctx, path, system=system)


def _import(ctx: AppContext, path: Path, *, system: str) -> List[str]:
    """Import the CA and return what still needs the user. Empty means trusted."""
    if system == "Windows":
        thumbprint = _windows_thumbprint(path.read_text(encoding="utf-8"))
        if _windows_store_contains(ctx, thumbprint):
            return []
        if _windows_add_certificate(path) and _windows_store_contains(ctx, thumbprint):
            return []
        return [
            "Could not add the CA to the Current User certificate store. "
            "Re-run 'aap-demo trust-ca' from an interactive Windows user session."
        ]
    if system == "Darwin":
        if _import_macos(ctx, path):
            return []
        ca = shlex.quote(str(path))
        return [
            "From a terminal in this Mac's desktop session, approve it with: "
            f"sudo security add-trusted-cert -d -r trustRoot -k {SYSTEM_KEYCHAIN} {ca}"
        ]
    problems = [
        _import_linux_system(ctx, path, system=system),
        _import_nss(ctx, path, system=system),
    ]
    return [problem for problem in problems if problem]


def _import_macos(ctx: AppContext, path: Path) -> bool:
    """Replace the keychain's ingress CA when sudo needs no password.

    ``CommandRunner`` captures output and leaves stdin on the terminal, so a
    sudo password prompt would hang behind the checklist. ``sudo -n`` fails
    instead, and ``install`` then prints the command for the user to run.
    """
    if not ctx.runner.run(["sudo", "-n", "true"]).ok:
        return False
    # ``delete-certificate -c`` refuses a name that matches more than one
    # certificate, so each old CA is removed by its hash.
    listed = ctx.runner.run(
        ["security", "find-certificate", "-a", "-Z", "-c", CA_COMMON_NAME, SYSTEM_KEYCHAIN]
    )
    for sha1 in _SHA1_LINE.findall(listed.stdout if listed.ok else ""):
        ctx.runner.run(
            ["sudo", "-n", "security", "delete-certificate", "-Z", sha1, SYSTEM_KEYCHAIN]
        )
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


def _import_linux_system(ctx: AppContext, path: Path, *, system: str) -> Optional[str]:
    """Update the system store with ``sudo -n``, or say which command to run."""
    if system_trusts(ctx, path, system=system):
        return None
    if RHEL_ANCHOR.parent.is_dir():
        anchor, update = RHEL_ANCHOR, "update-ca-trust"
    elif DEBIAN_ANCHOR.parent.is_dir():
        anchor, update = DEBIAN_ANCHOR, "update-ca-certificates"
    else:
        return "This system has no known CA trust directory. Add the file to its trust store."
    ca = shlex.quote(str(path))
    fix = f"For curl and other system tools, run: sudo cp {ca} {anchor} && sudo {update}"
    if not ctx.runner.run(["sudo", "-n", "true"]).ok:
        return fix
    if not ctx.runner.run(["sudo", "-n", "cp", str(path), str(anchor)]).ok:
        return fix
    return None if ctx.runner.run(["sudo", "-n", update]).ok else fix


def _import_nss(ctx: AppContext, path: Path, *, system: str) -> Optional[str]:
    """Replace a missing or stale CA in each browser database, then read it back."""
    databases = _nss_databases(ctx)
    if not _certutil_available(system):
        if not databases:
            return None
        return (
            "Chrome and Firefox need certutil. Install nss-tools "
            "(libnss3-tools on Debian and Ubuntu), then run aap-demo deploy again."
        )
    if not databases:
        database = _default_nss_database(ctx)
        database.mkdir(parents=True, exist_ok=True)
        created = ctx.runner.run(["certutil", "-d", f"sql:{database}", "-N", "--empty-password"])
        if not created.ok:
            return f"Could not create the browser certificate database in {database}."
        databases = [database]
    expected = fingerprint(path.read_text(encoding="utf-8"))
    failed = []
    for database in databases:
        if _nss_holds(ctx, database, expected):
            continue
        target = f"sql:{database}"
        ctx.runner.run(["certutil", "-d", target, "-D", "-n", NSS_NICKNAME])
        ctx.runner.run(
            ["certutil", "-d", target, "-A", "-t", "C,,", "-n", NSS_NICKNAME, "-i", str(path)]
        )
        if not _nss_holds(ctx, database, expected):
            failed.append(database)
    if not failed:
        return None
    ca = shlex.quote(str(path))
    commands = "; ".join(
        f"certutil -d {shlex.quote(f'sql:{database}')} -D -n {NSS_NICKNAME}; "
        f'certutil -d {shlex.quote(f"sql:{database}")} -A -t "C,," -n {NSS_NICKNAME} -i {ca}'
        for database in failed
    )
    return f"Quit the browser, then run: {commands}"


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
    elif kind == "Windows":
        browser = "trusted (Windows Current User Root)" if trusted else "not trusted"
    else:
        try:
            browser = _browser_trust(ctx, path, system=kind)
        except (OSError, ValueError):
            browser = "not trusted"
    return {
        "ingress_ca_file": str(path),
        "system_trust": "trusted" if trusted else "not trusted",
        "browser_trust": browser,
    }
