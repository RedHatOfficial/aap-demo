"""Ingress CA fetch and trust import."""

from __future__ import annotations

import base64
import subprocess
from pathlib import Path

from aap_demo.cluster import ingress_ca
from aap_demo.core.context import AppContext
from aap_demo.exec.runner import CompletedCommand, FakeRunner

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
    runner.fail("security find-certificate")
    runner.ok("sudo -n true")
    runner.ok("sudo -n security add-trusted-cert")
    # The second verify, after import, succeeds. FakeRunner returns the first
    # matching rule, so the post-import check is the same failure. Drive the
    # success by registering verify only as a failure and asserting the import
    # command; trust is then reported from add-trusted-cert's success plus a
    # dedicated status call below.
    app_ctx.runner = runner

    trusted = ingress_ca.install(app_ctx, system="Darwin")

    assert app_ctx.paths.ingress_ca.is_file()
    assert runner.called("sudo -n security add-trusted-cert")
    # verify-cert is still failing in this runner, so install must not claim trust.
    assert trusted is False
    assert (
        "not trusted yet" in app_ctx.console.stderr or "not trusted yet" in app_ctx.console.stdout
    )


def _router_secret(runner: FakeRunner, ca: str) -> None:
    encoded = base64.b64encode(ca.encode()).decode()
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


def test_install_never_prompts_when_sudo_needs_a_password(
    app_ctx: AppContext, tmp_path: Path
) -> None:
    """A captured sudo prompt hangs deploy, so the probe is the only sudo call."""
    runner = FakeRunner()
    _router_secret(runner, _cert(tmp_path, "ingress-ca"))
    runner.fail("security verify-cert")
    runner.fail("sudo -n true", stderr="sudo: a password is required")
    app_ctx.runner = runner

    assert ingress_ca.install(app_ctx, system="Darwin") is False

    sudo_calls = [command for command in runner.commands if command.startswith("sudo")]
    assert sudo_calls == ["sudo -n true"]
    assert app_ctx.paths.ingress_ca.is_file()
    assert "sudo security add-trusted-cert" in app_ctx.console.stderr


def test_install_removes_each_old_ca_by_hash_when_sudo_is_passwordless(
    app_ctx: AppContext, tmp_path: Path
) -> None:
    """``delete-certificate -c`` is ambiguous once two old CAs exist."""
    old = ["A" * 40, "B" * 40]
    listing = "".join(f"SHA-256 hash: {'C' * 64}\nSHA-1 hash: {sha1}\n" for sha1 in old)
    runner = FakeRunner()
    _router_secret(runner, _cert(tmp_path, "ingress-ca"))
    runner.ok("security verify-cert")
    runner.ok("security find-certificate", stdout=listing)
    runner.ok("sudo -n true")
    runner.ok("sudo -n security delete-certificate")
    runner.ok("sudo -n security add-trusted-cert")
    app_ctx.runner = runner

    assert ingress_ca.install(app_ctx, system="Darwin") is True

    sudo_calls = [command for command in runner.commands if command.startswith("sudo")]
    assert all(command.startswith("sudo -n ") for command in sudo_calls)
    for sha1 in old:
        assert any(f"delete-certificate -Z {sha1}" in command for command in sudo_calls)
    assert "Ingress CA trusted" in app_ctx.console.stdout


def test_install_is_quiet_when_the_ca_is_already_trusted(
    app_ctx: AppContext, tmp_path: Path
) -> None:
    ca = _cert(tmp_path, "ingress-ca")
    app_ctx.paths.ingress_ca.parent.mkdir(parents=True)
    app_ctx.paths.ingress_ca.write_text(ca, encoding="utf-8")
    encoded = base64.b64encode(ca.encode()).decode()
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
    runner.ok("security verify-cert")
    app_ctx.runner = runner

    assert ingress_ca.install(app_ctx, system="Darwin") is True
    assert not runner.called("sudo")
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


def test_install_trusts_the_cluster_ca_when_mkcert_is_missing(
    app_ctx: AppContext, tmp_path: Path, monkeypatch
) -> None:
    """A missing mkcert binary must not abort before the CRC CA import.

    ``SubprocessRunner`` raises ``PrerequisiteError`` for a command that is
    not on PATH. Deploy used to call ``mkcert`` first, so that error stopped
    the checklist. The cluster CA import is the only path now.
    """
    from aap_demo.core.errors import PrerequisiteError

    ca = _cert(tmp_path, "ingress-ca")
    encoded = base64.b64encode(ca.encode()).decode()
    runner = FakeRunner()
    runner.register("mkcert", PrerequisiteError("required command not found: mkcert"))
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
    runner.ok("sudo -n true")
    runner.ok("sudo -n cp")
    runner.ok("sudo -n update-ca-trust")
    app_ctx.runner = runner
    _linux_host(app_ctx, tmp_path, monkeypatch, certutil=False)

    assert ingress_ca.install(app_ctx, system="Linux") is True
    assert not runner.called("mkcert")
    assert runner.called(["sudo", "-n", "cp"])
    assert runner.called(["sudo", "-n", "update-ca-trust"])
    assert app_ctx.paths.ingress_ca.read_text(encoding="utf-8") == ca
    assert "kubectl apply" not in " ".join(runner.commands)


class _Nss:
    """certutil against in-memory databases, keyed by the ``sql:`` target."""

    def __init__(self, runner: FakeRunner, *, accept_import: bool = True) -> None:
        self.databases: dict = {}
        self.created: list = []
        self.accept_import = accept_import
        runner.register("certutil", self._run)

    def _run(self, argv: list) -> CompletedCommand:
        target = argv[argv.index("-d") + 1]
        if "-N" in argv:
            self.created.append(target)
        elif "-L" in argv and target in self.databases:
            return CompletedCommand(argv=argv, returncode=0, stdout=self.databases[target])
        elif "-D" in argv and target in self.databases:
            del self.databases[target]
        elif "-A" in argv and self.accept_import:
            self.databases[target] = Path(argv[argv.index("-i") + 1]).read_text(encoding="utf-8")
        else:
            return CompletedCommand(argv=argv, returncode=1)
        return CompletedCommand(argv=argv, returncode=0)


def _linux_host(
    app_ctx: AppContext, tmp_path: Path, monkeypatch, *, certutil: bool = True
) -> tuple:
    """An isolated home and RHEL-style anchor directory. Returns (home, anchor)."""
    home = tmp_path / "home"
    home.mkdir(exist_ok=True)
    app_ctx.env = {**app_ctx.env, "HOME": str(home)}
    anchor = tmp_path / "anchors" / "crc-ingress-ca.crt"
    anchor.parent.mkdir(exist_ok=True)
    monkeypatch.setattr(ingress_ca, "RHEL_ANCHOR", anchor)
    monkeypatch.setattr(ingress_ca, "DEBIAN_ANCHOR", tmp_path / "absent" / "crc-ingress-ca.crt")
    monkeypatch.setattr(
        ingress_ca.shutil, "which", lambda name: "/usr/bin/certutil" if certutil else None
    )
    return home, anchor


def _saved(app_ctx: AppContext, pem: str) -> None:
    app_ctx.paths.ingress_ca.parent.mkdir(parents=True, exist_ok=True)
    app_ctx.paths.ingress_ca.write_text(pem, encoding="utf-8")


def test_recreated_cluster_replaces_a_stale_ca_in_every_browser_database(
    app_ctx: AppContext, tmp_path: Path, monkeypatch
) -> None:
    old, new = _cert(tmp_path, "old-ca"), _cert(tmp_path, "new-ca")
    home, anchor = _linux_host(app_ctx, tmp_path, monkeypatch)
    chromium = home / ".local" / "share" / "pki" / "nssdb"
    chromium.mkdir(parents=True)
    profile = home / ".mozilla" / "firefox" / "abc.default"
    profile.mkdir(parents=True)
    (profile / "cert9.db").touch()
    (home / ".mozilla" / "firefox" / "not-a-profile").mkdir()
    anchor.write_text(old, encoding="utf-8")
    _saved(app_ctx, old)
    runner = FakeRunner()
    _router_secret(runner, new)
    runner.ok("sudo -n")
    nss = _Nss(runner)
    nss.databases = {f"sql:{chromium}": old, f"sql:{profile}": old}
    app_ctx.runner = runner

    assert ingress_ca.install(app_ctx, system="Linux") is True

    assert nss.databases == {f"sql:{chromium}": new, f"sql:{profile}": new}
    assert runner.called(["sudo", "-n", "cp"])


def test_system_trust_does_not_hide_a_stale_browser_database(
    app_ctx: AppContext, tmp_path: Path, monkeypatch
) -> None:
    old, new = _cert(tmp_path, "old-ca"), _cert(tmp_path, "new-ca")
    home, anchor = _linux_host(app_ctx, tmp_path, monkeypatch)
    database = home / ".pki" / "nssdb"
    database.mkdir(parents=True)
    anchor.write_text(new, encoding="utf-8")
    _saved(app_ctx, new)
    runner = FakeRunner()
    _router_secret(runner, new)
    nss = _Nss(runner)
    nss.databases = {f"sql:{database}": old}
    app_ctx.runner = runner

    assert ingress_ca.describe(app_ctx, system="Linux")["browser_trust"] == "not trusted"
    assert ingress_ca.describe(app_ctx, system="Linux")["system_trust"] == "trusted"
    assert ingress_ca.install(app_ctx, system="Linux") is True

    assert nss.databases == {f"sql:{database}": new}
    assert not runner.called("sudo")
    described = ingress_ca.describe(app_ctx, system="Linux")
    assert described["browser_trust"] == "trusted (Chrome/Firefox NSS)"


def test_linux_never_prompts_for_sudo_and_still_updates_the_browser(
    app_ctx: AppContext, tmp_path: Path, monkeypatch
) -> None:
    ca = _cert(tmp_path, "ca")
    home, anchor = _linux_host(app_ctx, tmp_path, monkeypatch)
    database = home / ".pki" / "nssdb"
    database.mkdir(parents=True)
    runner = FakeRunner()
    _router_secret(runner, ca)
    runner.fail("sudo -n true", stderr="sudo: a password is required")
    nss = _Nss(runner)
    app_ctx.runner = runner

    assert ingress_ca.install(app_ctx, system="Linux") is False

    assert [c for c in runner.commands if c.startswith("sudo")] == ["sudo -n true"]
    assert nss.databases == {f"sql:{database}": ca}
    assert f"sudo cp {app_ctx.paths.ingress_ca} {anchor} && sudo update-ca-trust" in (
        app_ctx.console.stderr
    )
    assert "On this Mac" not in app_ctx.console.stderr


def test_missing_certutil_with_a_browser_database_is_not_reported_as_trusted(
    app_ctx: AppContext, tmp_path: Path, monkeypatch
) -> None:
    ca = _cert(tmp_path, "ca")
    home, anchor = _linux_host(app_ctx, tmp_path, monkeypatch, certutil=False)
    (home / ".pki" / "nssdb").mkdir(parents=True)
    anchor.write_text(ca, encoding="utf-8")
    runner = FakeRunner()
    _router_secret(runner, ca)
    app_ctx.runner = runner

    assert ingress_ca.install(app_ctx, system="Linux") is False

    assert "Install nss-tools" in app_ctx.console.stderr
    assert ingress_ca.describe(app_ctx, system="Linux")["browser_trust"].startswith("unknown")


def test_a_machine_without_a_browser_only_needs_system_trust(
    app_ctx: AppContext, tmp_path: Path, monkeypatch
) -> None:
    ca = _cert(tmp_path, "ca")
    _, anchor = _linux_host(app_ctx, tmp_path, monkeypatch, certutil=False)
    anchor.write_text(ca, encoding="utf-8")
    _saved(app_ctx, ca)
    runner = FakeRunner()
    _router_secret(runner, ca)
    app_ctx.runner = runner

    assert ingress_ca.install(app_ctx, system="Linux") is True

    assert app_ctx.console.stdout == ""
    assert app_ctx.console.stderr == ""
    assert ingress_ca.describe(app_ctx, system="Linux")["browser_trust"].startswith("unknown")


def test_first_browser_database_is_created_before_the_import(
    app_ctx: AppContext, tmp_path: Path, monkeypatch
) -> None:
    ca = _cert(tmp_path, "ca")
    home, anchor = _linux_host(app_ctx, tmp_path, monkeypatch)
    anchor.write_text(ca, encoding="utf-8")
    runner = FakeRunner()
    _router_secret(runner, ca)
    nss = _Nss(runner)
    app_ctx.runner = runner

    assert ingress_ca.install(app_ctx, system="Linux") is True

    target = f"sql:{home / '.pki' / 'nssdb'}"
    assert nss.created == [target]
    assert nss.databases == {target: ca}


def test_a_failed_browser_import_is_a_warning_with_the_command(
    app_ctx: AppContext, tmp_path: Path, monkeypatch
) -> None:
    ca = _cert(tmp_path, "ca")
    home, anchor = _linux_host(app_ctx, tmp_path, monkeypatch)
    database = home / ".pki" / "nssdb"
    database.mkdir(parents=True)
    anchor.write_text(ca, encoding="utf-8")
    runner = FakeRunner()
    _router_secret(runner, ca)
    _Nss(runner, accept_import=False)
    app_ctx.runner = runner

    assert ingress_ca.install(app_ctx, system="Linux") is False

    assert f"certutil -d sql:{database} -A" in app_ctx.console.stderr
    assert "Ingress CA trusted" not in app_ctx.console.stdout
