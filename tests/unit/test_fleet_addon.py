"""Fleet addon without a cluster: registry, argv, extra-vars, and packaged files."""

from __future__ import annotations

import argparse
from pathlib import Path

import pytest
import yaml

from aap_demo.addons import get, names
from aap_demo.addons.fleet import resources
from aap_demo.cli import addons as addons_cli
from aap_demo.cli.main import build_parser
from aap_demo.core.errors import AddonError, PrerequisiteError, UsageError
from aap_demo.exec.runner import CompletedCommand, FakeRunner


def _which(present):
    def which(name: str):
        if name in present:
            return f"/usr/bin/{name}"
        return None

    return which


def _keygen(argv):
    path = Path(argv[argv.index("-f") + 1])
    path.write_text("PRIVATE-KEY\n", encoding="utf-8")
    Path(str(path) + ".pub").write_text("ssh-ed25519 PUBLIC\n", encoding="utf-8")
    return CompletedCommand(argv=tuple(argv), returncode=0, stdout="")


def _pull_secret(app_ctx) -> None:
    app_ctx.paths.pull_secret.parent.mkdir(parents=True, exist_ok=True)
    app_ctx.paths.pull_secret.write_text("{}\n", encoding="utf-8")


def _install_bins(monkeypatch, *bins: str) -> None:
    which = _which(set(bins))
    monkeypatch.setattr("aap_demo.addons.fleet.runner.shutil.which", which)
    monkeypatch.setattr("aap_demo.addons.fleet.sshkey.shutil.which", which)


def _play_runner(captured):
    runner = FakeRunner()
    runner.register(["/usr/bin/ssh-keygen"], _keygen)

    def play(argv):
        flag = list(argv).index("-e")
        spec = argv[flag + 1]
        captured.append((Path(argv[1]).name, Path(spec[1:]).read_text(encoding="utf-8")))
        return CompletedCommand(argv=tuple(argv), returncode=0, stdout="")

    runner.register(["/usr/bin/ansible-playbook"], play)
    return runner


def test_registry_is_only_fleet() -> None:
    assert names() == ["fleet"]


def test_enable_portal_is_an_addon_error(app_ctx) -> None:
    with pytest.raises(AddonError, match="fleet"):
        addons_cli.enable(app_ctx, argparse.Namespace(addon="portal"))
    assert app_ctx.runner.calls == []


def test_enable_fleet_requires_ansible_playbook(app_ctx, monkeypatch) -> None:
    _install_bins(monkeypatch)
    with pytest.raises(PrerequisiteError, match="ansible-playbook is required"):
        get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))
    assert app_ctx.runner.calls == []


def test_enable_writes_extra_vars_then_deletes_them(app_ctx, monkeypatch) -> None:
    _pull_secret(app_ctx)
    _install_bins(monkeypatch, "ansible-playbook", "ssh-keygen")
    captured = []
    app_ctx.runner = _play_runner(captured)
    monkeypatch.setattr(
        "aap_demo.addons.fleet.gateway.gateway_url", lambda _ctx: "https://gw.example"
    )
    monkeypatch.setattr("aap_demo.cluster.aap.admin_password", lambda _ctx, _ns: "secret")

    assert get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=False)) == 0

    assert [name for name, _text in captured] == ["provision.yml", "import.yml"]
    provision, imported = (text for _name, text in captured)
    assert "namespace: fleet" in provision
    assert "fleet-ubi9" in provision and "fleet-fedora" in provision and "fleet-debian" in provision
    assert "registry.access.redhat.com/ubi9/ubi:9.6" in provision
    assert "PRIVATE-KEY" not in provision
    assert "PRIVATE-KEY" in imported
    assert "namespace: fleet" in imported
    leftover = list(app_ctx.paths.addon_dir("fleet").glob("extra-vars.yml"))
    assert leftover == []
    assert "fleet" in app_ctx.config.get("addons.enabled")


def test_no_import_skips_the_controller_playbook(app_ctx, monkeypatch) -> None:
    _pull_secret(app_ctx)
    _install_bins(monkeypatch, "ansible-playbook", "ssh-keygen")
    captured = []
    app_ctx.runner = _play_runner(captured)

    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))

    assert [name for name, _text in captured] == ["provision.yml"]


def test_second_enable_reuses_the_key(app_ctx, monkeypatch) -> None:
    _pull_secret(app_ctx)
    _install_bins(monkeypatch, "ansible-playbook", "ssh-keygen")
    app_ctx.runner = _play_runner([])
    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))
    app_ctx.runner = _play_runner([])

    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))

    assert not any("ssh-keygen" in call.argv[0] for call in app_ctx.runner.calls)


def test_add_rejects_an_unknown_os(app_ctx) -> None:
    with pytest.raises(UsageError, match="unknown OS"):
        get("fleet").add(app_ctx, argparse.Namespace(os="plan9", name=None))


def test_add_rejects_a_duplicate_default_name(app_ctx, monkeypatch) -> None:
    _pull_secret(app_ctx)
    _install_bins(monkeypatch, "ansible-playbook", "ssh-keygen")
    app_ctx.runner = _play_runner([])
    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))
    with pytest.raises(UsageError, match="already exists"):
        get("fleet").add(app_ctx, argparse.Namespace(os="debian", name=None))


def test_add_named_node_runs_both_playbooks(app_ctx, monkeypatch) -> None:
    _pull_secret(app_ctx)
    _install_bins(monkeypatch, "ansible-playbook", "ssh-keygen")
    monkeypatch.setattr(
        "aap_demo.addons.fleet.gateway.gateway_url", lambda _ctx: "https://gw.example"
    )
    monkeypatch.setattr("aap_demo.cluster.aap.admin_password", lambda _ctx, _ns: "secret")
    app_ctx.runner = _play_runner([])
    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=False))
    captured = []
    app_ctx.runner = _play_runner(captured)

    get("fleet").add(app_ctx, argparse.Namespace(os="debian", name="extra-debian"))

    names_run = [name for name, _text in captured]
    assert names_run == ["provision.yml", "import.yml"]
    nodes = app_ctx.config.get("addons.options")["fleet"]["nodes"]
    assert any(node["name"] == "extra-debian" for node in nodes)


def test_disable_stops_pods_and_leaves_the_inventory(app_ctx, monkeypatch) -> None:
    _pull_secret(app_ctx)
    _install_bins(monkeypatch, "ansible-playbook", "ssh-keygen")
    app_ctx.runner = _play_runner([])
    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))
    captured = []
    app_ctx.runner = _play_runner(captured)

    get("fleet").disable(app_ctx, argparse.Namespace(addon="fleet"))

    assert [name for name, _text in captured] == ["provision.yml"]
    provision = captured[0][1]
    assert "replicas: 0" in provision
    assert "state: present" in provision
    assert "fleet" in (app_ctx.config.get("addons.enabled") or [])


def test_destroy_removes_controller_objects_before_the_namespace(app_ctx, monkeypatch) -> None:
    _pull_secret(app_ctx)
    _install_bins(monkeypatch, "ansible-playbook", "ssh-keygen")
    app_ctx.runner = _play_runner([])
    monkeypatch.setattr(
        "aap_demo.addons.fleet.gateway.gateway_url", lambda _ctx: "https://gw.example"
    )
    monkeypatch.setattr("aap_demo.cluster.aap.admin_password", lambda _ctx, _ns: "secret")
    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=False))
    captured = []
    app_ctx.runner = _play_runner(captured)

    get("fleet").destroy(app_ctx, argparse.Namespace())

    assert [name for name, _text in captured] == ["import.yml", "provision.yml"]
    imported, provision = (text for _name, text in captured)
    assert "state: absent" in imported
    assert "state: absent" in provision
    assert "fleet" not in (app_ctx.config.get("addons.enabled") or [])


def test_packaged_files_load_through_importlib() -> None:
    for name in (
        "playbooks/provision.yml",
        "playbooks/import.yml",
        "playbooks/ping.yml",
        "entrypoint.sh",
    ):
        assert resources.read_text(name)


def test_playbooks_parse_and_name_their_modules() -> None:
    provision = resources.read_text("playbooks/provision.yml")
    imported = resources.read_text("playbooks/import.yml")
    ping = resources.read_text("playbooks/ping.yml")
    yaml.safe_load(provision)
    yaml.safe_load(imported)
    yaml.safe_load(ping)
    assert "kubernetes.core.k8s" in provision
    assert "{{ namespace }}" in provision
    assert "aap-demo-fleet" not in provision
    for module in (
        "ansible.controller.inventory",
        "ansible.controller.host",
        "ansible.controller.credential",
        "ansible.controller.project",
        "ansible.controller.job_template",
    ):
        assert module in imported
    assert "{{ namespace }}" in imported
    assert "ansible.builtin.ping" in ping


def test_help_lists_enable_disable_and_fleet() -> None:
    help_text = build_parser().format_help()
    for command in ("enable", "disable", "fleet"):
        assert command in help_text
