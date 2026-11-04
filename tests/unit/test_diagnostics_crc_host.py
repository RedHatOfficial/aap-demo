"""``diagnostics/crc_host.py``: host-side CRC checks for ``aap-demo diagnose``."""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from aap_demo.diagnostics import checks as diagnose_checks
from aap_demo.diagnostics import crc_host

CRC = "/usr/local/bin/crc"


def _probe(**overrides: Any) -> crc_host.HostProbe:
    values: Dict[str, Any] = dict(
        system="Darwin",
        which_crc=lambda: CRC,
        crc_version=lambda: "CRC version: 2.64.0+abc\nMicroShift version: 4.22.13\n",
        status=lambda: {"crcStatus": "Running"},
        machine_exists=lambda: True,
        daemons=lambda: [f"{CRC} daemon --log-level debug"],
        port_open=lambda host, port: True,
        resolve=lambda path: path,
    )
    values.update(overrides)
    return crc_host.HostProbe(**values)


def _run(probe: crc_host.HostProbe) -> List[Any]:
    rec = diagnose_checks._Recorder()
    crc_host.check(probe, rec)
    return rec.section.checks


def _levels(checks: List[Any]) -> List[str]:
    return [c.level for c in checks]


def _text(checks: List[Any]) -> str:
    return "\n".join(c.message for c in checks)


def test_a_healthy_host_passes_every_check() -> None:
    checks = _run(_probe())
    assert _levels(checks) == ["pass", "pass", "pass"]
    assert "crc 2.64.0+abc: /usr/local/bin/crc" in _text(checks)
    assert crc_host.FIX_HINT not in _text(checks)


def test_missing_crc_stops_the_section() -> None:
    checks = _run(_probe(which_crc=lambda: None))
    assert _levels(checks) == ["fail"]
    assert "crc not found on PATH" in _text(checks)


def test_a_hung_crc_with_a_vm_is_reported_with_the_fix() -> None:
    # Brian's case: `crc start` stuck on SSH, so `crc status` never answers.
    checks = _run(_probe(status=lambda: {}, daemons=lambda: [], port_open=lambda h, p: False))
    text = _text(checks)
    assert "a 'crc start' may be hung" in text
    assert "crc daemon is not running" in text
    assert "Nothing answers on 127.0.0.1:2222" in text
    assert crc_host.FIX_HINT in text


def test_a_daemon_from_another_crc_binary_fails() -> None:
    checks = _run(_probe(daemons=lambda: ["/Users/me/.local/bin/crc daemon"]))
    text = _text(checks)
    assert "crc daemon runs /Users/me/.local/bin/crc" in text
    assert "but crc on PATH is /usr/local/bin/crc" in text
    assert crc_host.FIX_HINT in text


def test_the_daemon_link_crc_setup_made_matches_crc() -> None:
    # `crc setup` links ~/.crc/bin/crc to the crc on PATH; the daemon runs that link.
    real = "/usr/local/crc/crc"
    link = "/Users/me/.crc/bin/crc"
    targets = {CRC: real, link: real, real: real}
    checks = _run(_probe(daemons=lambda: [f"{link} daemon"], resolve=lambda p: targets.get(p, p)))
    assert "fail" not in _levels(checks)


def test_a_daemon_link_left_by_another_install_fails() -> None:
    link = "/Users/me/.crc/bin/crc"
    targets = {CRC: "/usr/local/crc/crc", link: "/Users/me/old/crc"}
    checks = _run(_probe(daemons=lambda: [f"{link} daemon"], resolve=lambda p: targets.get(p, p)))
    assert "(/Users/me/old/crc)" in _text(checks)
    assert crc_host.FIX_HINT in _text(checks)


def test_no_vm_and_no_daemon_is_not_a_problem() -> None:
    stopped = _probe(
        status=lambda: {"crcStatus": "Stopped"}, machine_exists=lambda: False, daemons=lambda: []
    )
    checks = _run(stopped)
    assert "fail" not in _levels(checks)
    assert "no VM yet" in _text(checks)


def test_the_ssh_forward_is_only_checked_on_macos() -> None:
    called: List[Optional[int]] = []

    def port_open(host: str, port: int) -> bool:
        called.append(port)
        return False

    checks = _run(_probe(system="Linux", port_open=port_open))
    assert called == []
    assert "fail" not in _levels(checks)


def test_platforms_without_ps_skip_the_daemon_check() -> None:
    checks = _run(_probe(system="Windows", daemons=lambda: None))
    assert "not checked on this platform" in _text(checks)


def test_daemon_lines_matches_only_the_crc_daemon() -> None:
    ps = "\n".join(
        [
            "/usr/local/crc/crc daemon --log-level debug",
            "/usr/local/crc/vfkit --cpus 12",
            "grep crc daemon",
            "crc start",
        ]
    )
    assert crc_host.daemon_lines(ps) == ["/usr/local/crc/crc daemon --log-level debug"]


def test_diagnose_without_a_host_probe_keeps_the_old_sections(fake_runner: Any) -> None:
    fake_runner.fail("crc status -o json")
    fake_runner.fail("kubectl cluster-info")
    report = diagnose_checks.run(fake_runner, "aap-operator")
    assert [s.name for s in report.sections] == ["Cluster"]
