"""Ingress CA trust against a real Linux trust store, certutil, sudo and browser.

These tests change the machine's trust store, so they run only when
``AAP_DEMO_TEST_HOST_TRUST=1`` is set, which the host trust workflow does on a
disposable runner. Only ``kubectl`` is faked, because no cluster is involved.
"""

from __future__ import annotations

import base64
import http.server
import json
import os
import platform
import shutil
import ssl
import subprocess
import threading
from pathlib import Path
from typing import Iterator, NamedTuple

import pytest

from aap_demo.cluster import ingress_ca
from aap_demo.core.context import AppContext
from aap_demo.exec.runner import CompletedCommand, SubprocessRunner

pytestmark = pytest.mark.skipif(
    os.environ.get("AAP_DEMO_TEST_HOST_TRUST") != "1" or platform.system() != "Linux",
    reason="changes the trust store; set AAP_DEMO_TEST_HOST_TRUST=1 on a disposable Linux host",
)

PAGE_MARKER = "aap-demo-trust-check"


class Cluster(NamedTuple):
    ca: str
    leaf: str
    leaf_key: Path


def _openssl(*args: str) -> None:
    subprocess.run(["openssl", *args], check=True, capture_output=True)


def _new_cluster(directory: Path, name: str) -> Cluster:
    """A CA named like CRC's, and a localhost certificate that it signed."""
    directory.mkdir()
    ca_key, ca_crt = directory / "ca.key", directory / "ca.crt"
    leaf_key, leaf_csr, leaf_crt = (
        directory / "leaf.key",
        directory / "leaf.csr",
        directory / "leaf.crt",
    )
    extensions = directory / "leaf.ext"
    extensions.write_text(
        "subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n",
        encoding="utf-8",
    )
    # fmt: off
    _openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(ca_key),
             "-out", str(ca_crt), "-days", "2", "-subj", f"/CN=ingress-ca/O={name}",
             "-addext", "basicConstraints=critical,CA:TRUE",
             "-addext", "keyUsage=critical,keyCertSign,cRLSign")
    _openssl("req", "-newkey", "rsa:2048", "-nodes", "-keyout", str(leaf_key),
             "-out", str(leaf_csr), "-subj", "/CN=localhost")
    _openssl("x509", "-req", "-in", str(leaf_csr), "-CA", str(ca_crt), "-CAkey", str(ca_key),
             "-CAcreateserial", "-out", str(leaf_crt), "-days", "2",
             "-extfile", str(extensions))
    # fmt: on
    return Cluster(
        ca_crt.read_text(encoding="utf-8"), leaf_crt.read_text(encoding="utf-8"), leaf_key
    )


class _ClusterRunner:
    """Real commands, except that ``kubectl`` returns this cluster's router secret."""

    def __init__(self, cluster: Cluster) -> None:
        self.cluster = cluster
        self._real = SubprocessRunner()

    def run(self, args, **kwargs):
        if args[0] == "kubectl":
            chain = (self.cluster.leaf + self.cluster.ca).encode()
            secret = {"data": {"tls.crt": base64.b64encode(chain).decode()}}
            return CompletedCommand(argv=list(args), returncode=0, stdout=json.dumps(secret))
        return self._real.run(args, **kwargs)


class _Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        body = f"<html><body>{PAGE_MARKER}</body></html>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args) -> None:
        pass


@pytest.fixture
def serve(tmp_path: Path) -> Iterator:
    servers = []

    def start(cluster: Cluster) -> str:
        chain = tmp_path / f"chain-{len(servers)}.pem"
        chain.write_text(cluster.leaf + cluster.ca, encoding="utf-8")
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(chain, cluster.leaf_key)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Page)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        servers.append(server)
        return f"https://localhost:{server.server_address[1]}/"

    yield start
    for server in servers:
        server.shutdown()


def _curl_trusts(url: str) -> bool:
    return (
        subprocess.run(["curl", "-sS", "-o", os.devnull, url], capture_output=True).returncode == 0
    )


def _chrome_trusts(url: str, home: Path, profile: Path) -> bool:
    # A certificate error page does not contain the marker.
    chrome = shutil.which("google-chrome")
    assert chrome is not None
    shown = subprocess.run(
        [
            chrome,
            "--headless=new",
            "--no-sandbox",
            "--disable-gpu",
            f"--user-data-dir={profile}",
            "--virtual-time-budget=5000",
            "--dump-dom",
            url,
        ],
        env={**os.environ, "HOME": str(home)},
        capture_output=True,
        text=True,
        timeout=120,
    )
    return PAGE_MARKER in shown.stdout


def _browser_required() -> bool:
    return os.environ.get("AAP_DEMO_TEST_REQUIRE_BROWSER") == "1"


def _use_home(app_ctx: AppContext, tmp_path: Path) -> Path:
    home = tmp_path / "home"
    home.mkdir()
    app_ctx.env = {**app_ctx.env, "HOME": str(home)}
    return home


def test_a_new_cluster_is_trusted_by_system_tools_and_the_browser(
    app_ctx: AppContext, tmp_path: Path, serve
) -> None:
    home = _use_home(app_ctx, tmp_path)
    cluster = _new_cluster(tmp_path / "cluster", "first")
    app_ctx.runner = _ClusterRunner(cluster)
    url = serve(cluster)
    assert not _curl_trusts(url)

    assert ingress_ca.install(app_ctx, system="Linux") is True

    assert _curl_trusts(url)
    described = ingress_ca.describe(app_ctx, system="Linux")
    assert described["system_trust"] == "trusted"
    assert described["browser_trust"] == "trusted (Chrome/Firefox NSS)"
    if _browser_required():
        assert _chrome_trusts(url, home, tmp_path / "chrome")


def test_a_recreated_cluster_replaces_the_old_ca_everywhere(
    app_ctx: AppContext, tmp_path: Path, serve
) -> None:
    home = _use_home(app_ctx, tmp_path)
    old = _new_cluster(tmp_path / "old", "old")
    new = _new_cluster(tmp_path / "new", "new")
    app_ctx.runner = _ClusterRunner(old)
    assert ingress_ca.install(app_ctx, system="Linux") is True

    new_url = serve(new)
    if _browser_required():
        assert not _chrome_trusts(new_url, home, tmp_path / "chrome-before")

    app_ctx.runner = _ClusterRunner(new)
    assert ingress_ca.install(app_ctx, system="Linux") is True

    assert _curl_trusts(new_url)
    listed = subprocess.run(
        ["certutil", "-d", f"sql:{home / '.pki' / 'nssdb'}", "-L", "-n", "crc-ingress-ca", "-a"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    pems = ingress_ca.pem_certificates(listed)
    assert [ingress_ca.fingerprint(pem) for pem in pems] == [ingress_ca.fingerprint(new.ca)]
    if _browser_required():
        assert _chrome_trusts(new_url, home, tmp_path / "chrome-after")
