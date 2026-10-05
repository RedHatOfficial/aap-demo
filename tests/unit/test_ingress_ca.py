"""Ingress CA fetch and trust import."""

from __future__ import annotations

import base64
import subprocess
from pathlib import Path

from aap_demo.cluster import ingress_ca
from aap_demo.core.context import AppContext
from aap_demo.exec.runner import FakeRunner

PEM_LEAF = ""
PEM_CA = ""


def _cert(tmp_path: Path, name: str) -> str:
    cert = tmp_path / f"{name}.crt"
    key = tmp_path / f"{name}.key"
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            str(key),
            "-out",
            str(cert),
            "-subj",
            f"/CN={name}",
            "-days",
            "1",
        ],
        check=True,
        capture_output=True,
    )
    return cert.read_text(encoding="utf-8")


def test_fetch_keeps_the_last_certificate_in_the_router_chain(
    app_ctx: AppContext, tmp_path: Path
) -> None:
    leaf = _cert(tmp_path, "leaf")
    ca = _cert(tmp_path, "ingress-ca")
    encoded = base64.b64encode((leaf + ca).encode()).decode()
    runner = FakeRunner()
    runner.ok(
        [
            "kubectl",
            "get",
            "secret",
            "router-certs-default",
            "-n",
            "openshift-ingress",
            "-o",
            "json",
        ],
        stdout='{"data":{"tls.crt":"' + encoded + '"}}',
    )
    app_ctx.runner = runner

    fetched = ingress_ca.fetch_cluster_ca(app_ctx)

    assert fetched is not None
    assert ingress_ca.fingerprint(fetched) == ingress_ca.fingerprint(ca)


def test_install_imports_when_the_keychain_does_not_trust_the_ca(
    app_ctx: AppContext, tmp_path: Path
) -> None:
    ca = _cert(tmp_path, "ingress-ca")
    encoded = base64.b64encode(ca.encode()).decode()
    runner = FakeRunner()
    runner.fail("mkcert")
    runner.ok(
        [
            "kubectl",
            "get",
            "secret",
            "router-certs-default",
            "-n",
            "openshift-ingress",
            "-o",
            "json",
        ],
        stdout='{"data":{"tls.crt":"' + encoded + '"}}',
    )
    runner.fail("security verify-cert")
    runner.fail("sudo security delete-certificate")
    runner.ok("sudo security add-trusted-cert")
    # The second verify, after import, succeeds. FakeRunner returns the first
    # matching rule, so the post-import check is the same failure. Drive the
    # success by registering verify only as a failure and asserting the import
    # command; trust is then reported from add-trusted-cert's success plus a
    # dedicated status call below.
    app_ctx.runner = runner

    trusted = ingress_ca.install(app_ctx, system="Darwin")

    assert app_ctx.paths.ingress_ca.is_file()
    assert runner.called("sudo security add-trusted-cert")
    # verify-cert is still failing in this runner, so install must not claim trust.
    assert trusted is False
    assert (
        "not trusted yet" in app_ctx.console.stderr or "not trusted yet" in app_ctx.console.stdout
    )


def test_install_is_quiet_when_the_ca_is_already_trusted(
    app_ctx: AppContext, tmp_path: Path
) -> None:
    ca = _cert(tmp_path, "ingress-ca")
    app_ctx.paths.ingress_ca.parent.mkdir(parents=True)
    app_ctx.paths.ingress_ca.write_text(ca, encoding="utf-8")
    encoded = base64.b64encode(ca.encode()).decode()
    runner = FakeRunner()
    runner.fail("mkcert")
    runner.ok(
        [
            "kubectl",
            "get",
            "secret",
            "router-certs-default",
            "-n",
            "openshift-ingress",
            "-o",
            "json",
        ],
        stdout='{"data":{"tls.crt":"' + encoded + '"}}',
    )
    runner.ok("security verify-cert")
    app_ctx.runner = runner

    assert ingress_ca.install(app_ctx, system="Darwin") is True
    assert not runner.called("sudo security add-trusted-cert")
    assert app_ctx.console.stdout == ""


def test_status_names_an_untrusted_saved_ca(app_ctx: AppContext, tmp_path: Path) -> None:
    ca = _cert(tmp_path, "ingress-ca")
    app_ctx.paths.ingress_ca.parent.mkdir(parents=True)
    app_ctx.paths.ingress_ca.write_text(ca, encoding="utf-8")
    app_ctx.runner = FakeRunner().fail("security verify-cert")

    described = ingress_ca.describe(app_ctx, system="Darwin")

    assert described["system_trust"] == "not trusted"
    assert described["browser_trust"] == "not trusted"
    assert described["ingress_ca_file"] == str(app_ctx.paths.ingress_ca)


def test_mkcert_replaces_the_router_certificate_when_its_ca_is_trusted(
    app_ctx: AppContext, tmp_path: Path
) -> None:
    root_dir = tmp_path / "mkcert"
    root_dir.mkdir()
    root_pem = _cert(tmp_path, "root")
    (root_dir / "rootCA.pem").write_text(root_pem, encoding="utf-8")
    leaf = _cert(tmp_path, "leaf")

    def issue(argv: tuple[str, ...]):
        from aap_demo.exec.runner import CompletedCommand

        cert = Path(argv[argv.index("-cert-file") + 1])
        key = Path(argv[argv.index("-key-file") + 1])
        cert.write_text(leaf, encoding="utf-8")
        key.write_text("private-key\n", encoding="utf-8")
        return CompletedCommand(argv=tuple(argv), returncode=0, stdout="created\n")

    runner = FakeRunner()
    runner.ok("mkcert -CAROOT", stdout=str(root_dir) + "\n")
    runner.ok("security verify-cert")
    runner.register("mkcert -cert-file", issue)
    runner.ok("kubectl apply -f -")
    runner.ok("kubectl delete pod")
    app_ctx.runner = runner

    assert ingress_ca.issue_with_mkcert(app_ctx, system="Darwin") is True

    applied = next(call for call in runner.calls if call.argv[:3] == ("kubectl", "apply", "-f"))
    assert applied.input is not None
    assert "tls.crt" in applied.input
    assert "private-key" in applied.input
    assert "BEGIN CERTIFICATE" in applied.input
    assert "Ingress certificate is trusted locally" in app_ctx.console.stdout
    assert "private-key" not in app_ctx.console.stdout
    assert runner.called("kubectl delete pod")


def test_mkcert_is_skipped_when_disabled(app_ctx: AppContext, tmp_path: Path) -> None:
    app_ctx.env = {"HOME": str(tmp_path)}
    app_ctx.config.set("trust.mkcert", False)
    runner = FakeRunner()
    runner.fail(
        [
            "kubectl",
            "get",
            "secret",
            "router-certs-default",
            "-n",
            "openshift-ingress",
            "-o",
            "json",
        ]
    )
    app_ctx.runner = runner

    assert ingress_ca.install(app_ctx, system="Darwin") is False
    assert not runner.called("mkcert")
