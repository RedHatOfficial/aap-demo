"""Fleet addon without a cluster: registry, argv, extra-vars, and packaged files."""

from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path

import pytest
import yaml

from aap_demo.addons import get, names
from aap_demo.addons.fleet import resources
from aap_demo.cli import addons as addons_cli
from aap_demo.cli.main import build_parser
from aap_demo.core.errors import AddonError, UsageError
from aap_demo.exec.runner import CompletedCommand, FakeRunner

EE_IMAGE = "registry.redhat.io/ansible-automation-platform-26/ee-supported-rhel9@sha256:abc"
EE_PODS = json.dumps(
    {"items": [{"spec": {"containers": [{"name": "aap-controller-ee", "image": EE_IMAGE}]}}]}
)


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


def _install_bins(monkeypatch) -> None:
    monkeypatch.setattr(
        "aap_demo.addons.fleet.sshkey.shutil.which",
        _which({"ssh-keygen"}),
    )


def _cluster_runner() -> FakeRunner:
    runner = FakeRunner()
    runner.register(["/usr/bin/ssh-keygen"], _keygen)
    runner.ok(["kubectl", "get", "pods"], stdout=EE_PODS)
    runner.ok(["kubectl", "get", "svc", "router-default"], stdout="10.43.72.238")

    def get_secret(argv):
        for call in reversed(runner.calls):
            text = call.input or ""
            if "name: aap-demo-fleet-ssh" not in text:
                continue
            document = yaml.safe_load(text)
            data = document.get("stringData") or {}
            if "ssh-privatekey" not in data:
                continue
            encoded = {
                key: base64.b64encode(str(value).encode()).decode() for key, value in data.items()
            }
            return CompletedCommand(
                argv=tuple(argv),
                returncode=0,
                stdout=json.dumps({"data": encoded}),
            )
        return CompletedCommand(argv=tuple(argv), returncode=1, stderr="NotFound")

    runner.register(["kubectl", "get", "secret"], get_secret)
    runner.ok(["kubectl", "apply"])
    runner.ok(["kubectl", "wait"])
    runner.ok(["kubectl", "delete"])
    runner.ok(["kubectl", "logs"])
    return runner


def _applied(runner: FakeRunner) -> list:
    documents = []
    for call in runner.calls:
        if call.argv[:3] != ("kubectl", "apply", "-f") or not call.input:
            continue
        documents.extend(item for item in yaml.safe_load_all(call.input) if item)
    return documents


def _playbook_runs(runner: FakeRunner) -> list:
    """(playbook name, extra-vars text, job document) for each fleet Job."""
    configmaps = {}
    secrets = {}
    jobs = []
    for document in _applied(runner):
        name = document.get("metadata", {}).get("name", "")
        if not str(name).startswith("aap-demo-fleet-"):
            continue
        if document.get("kind") == "ConfigMap":
            configmaps[name] = document.get("data") or {}
        elif document.get("kind") == "Secret" and "extra-vars.yml" in (
            document.get("stringData") or {}
        ):
            secrets[name] = document["stringData"]["extra-vars.yml"]
        elif document.get("kind") == "Job":
            jobs.append(document)
    runs = []
    for job in jobs:
        name = job["metadata"]["name"]
        playbook = next(key for key in configmaps[name] if key.endswith(".yml"))
        runs.append((playbook, secrets[name], job))
    return runs


def test_registry_is_only_fleet() -> None:
    assert names() == ["fleet"]


def test_enable_portal_is_an_addon_error(app_ctx) -> None:
    with pytest.raises(AddonError, match="fleet"):
        addons_cli.enable(app_ctx, argparse.Namespace(addon="portal"))
    assert app_ctx.runner.calls == []


def test_enable_fleet_needs_the_execution_environment(app_ctx, monkeypatch) -> None:
    _install_bins(monkeypatch)
    app_ctx.runner = FakeRunner()
    app_ctx.runner.ok(["kubectl", "get", "pods"], stdout='{"items":[]}')
    with pytest.raises(AddonError, match="ee-supported"):
        get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))
    joined = [" ".join(call.argv) for call in app_ctx.runner.calls]
    assert not any("ssh-keygen" in command for command in joined)
    assert not any(command.split()[0].endswith("ansible-playbook") for command in joined)


def test_enable_writes_extra_vars_then_deletes_them(app_ctx, monkeypatch) -> None:
    _pull_secret(app_ctx)
    _install_bins(monkeypatch)
    app_ctx.runner = _cluster_runner()
    monkeypatch.setattr(
        "aap_demo.addons.fleet.gateway.gateway_url", lambda _ctx: "https://gw.example"
    )
    monkeypatch.setattr("aap_demo.cluster.aap.admin_password", lambda _ctx, _ns: "secret")

    assert get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=False)) == 0

    runs = _playbook_runs(app_ctx.runner)
    assert [name for name, _text, _job in runs] == ["provision.yml", "import.yml"]
    provision, imported = (text for _name, text, _job in runs)
    provision_job = runs[0][2]
    import_job = runs[1][2]
    assert "namespace: fleet" in provision
    assert "disk_size: 2Gi" in provision
    assert "storage_class: ''" in provision or 'storage_class: ""' in provision
    assert "fleet-ubi9" in provision and "fleet-fedora" in provision and "fleet-debian" in provision
    assert "registry.access.redhat.com/ubi9/ubi:9.6" in provision
    assert "PRIVATE-KEY" not in provision
    assert str(app_ctx.paths.pull_secret) not in provision
    assert "/opt/fleet/extra/pull-secret.json" in provision
    assert "PRIVATE-KEY" in imported
    assert "namespace: fleet" in imported
    image = provision_job["spec"]["template"]["spec"]["containers"][0]["image"]
    assert image == EE_IMAGE
    assert "hostAliases" not in provision_job["spec"]["template"]["spec"]
    alias = import_job["spec"]["template"]["spec"]["hostAliases"][0]
    assert alias["ip"] == "10.43.72.238"
    assert alias["hostnames"] == ["gw.example"]
    assert any(call.argv[1] == "delete" for call in app_ctx.runner.calls)
    assert "fleet" in app_ctx.config.get("addons.enabled")


def test_disk_size_and_storage_class_come_from_fleet_options(app_ctx, monkeypatch) -> None:
    _pull_secret(app_ctx)
    _install_bins(monkeypatch)
    app_ctx.config.set(
        "addons.options",
        {"fleet": {"disk_size": "1Gi", "storage_class": "topolvm-provisioner"}},
    )
    app_ctx.runner = _cluster_runner()

    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))

    provision = _playbook_runs(app_ctx.runner)[0][1]
    assert "disk_size: 1Gi" in provision
    assert "storage_class: topolvm-provisioner" in provision


def test_ubi_uses_the_txt_pull_secret(app_ctx, monkeypatch) -> None:
    _install_bins(monkeypatch)
    app_ctx.config.set("deploy.pull_secret_path", "")
    text = app_ctx.paths.state_dir / "pull-secret.txt"
    text.parent.mkdir(parents=True, exist_ok=True)
    text.write_text('{"auths":{}}\n', encoding="utf-8")
    app_ctx.runner = _cluster_runner()

    assert get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True)) == 0

    provision = _playbook_runs(app_ctx.runner)[0][1]
    assert "/opt/fleet/extra/pull-secret.json" in provision
    assert "pull-secret.txt" not in provision


def test_no_import_skips_the_controller_playbook(app_ctx, monkeypatch) -> None:
    _pull_secret(app_ctx)
    _install_bins(monkeypatch)
    app_ctx.runner = _cluster_runner()

    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))

    assert [name for name, _text, _job in _playbook_runs(app_ctx.runner)] == ["provision.yml"]


def test_second_enable_reuses_the_key(app_ctx, monkeypatch) -> None:
    _pull_secret(app_ctx)
    _install_bins(monkeypatch)
    app_ctx.runner = _cluster_runner()
    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))

    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))

    created = [call for call in app_ctx.runner.calls if "ssh-keygen" in call.argv[0]]
    assert len(created) == 1


def test_add_rejects_an_unknown_os(app_ctx) -> None:
    with pytest.raises(UsageError, match="unknown OS"):
        get("fleet").add(app_ctx, argparse.Namespace(os="plan9", name=None))


def test_add_rejects_a_duplicate_default_name(app_ctx, monkeypatch) -> None:
    _pull_secret(app_ctx)
    _install_bins(monkeypatch)
    app_ctx.runner = _cluster_runner()
    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))
    with pytest.raises(UsageError, match="already exists"):
        get("fleet").add(app_ctx, argparse.Namespace(os="debian", name=None))


def test_add_named_node_runs_both_playbooks(app_ctx, monkeypatch) -> None:
    _pull_secret(app_ctx)
    _install_bins(monkeypatch)
    monkeypatch.setattr(
        "aap_demo.addons.fleet.gateway.gateway_url", lambda _ctx: "https://gw.example"
    )
    monkeypatch.setattr("aap_demo.cluster.aap.admin_password", lambda _ctx, _ns: "secret")
    app_ctx.runner = _cluster_runner()
    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=False))
    app_ctx.runner = _cluster_runner()

    get("fleet").add(app_ctx, argparse.Namespace(os="debian", name="extra-debian"))

    names_run = [name for name, _text, _job in _playbook_runs(app_ctx.runner)]
    assert names_run == ["provision.yml", "import.yml"]
    nodes = app_ctx.config.get("addons.options")["fleet"]["nodes"]
    assert any(node["name"] == "extra-debian" for node in nodes)


def test_disable_stops_pods_and_leaves_the_inventory(app_ctx, monkeypatch) -> None:
    _pull_secret(app_ctx)
    _install_bins(monkeypatch)
    app_ctx.runner = _cluster_runner()
    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))
    app_ctx.runner = _cluster_runner()

    get("fleet").disable(app_ctx, argparse.Namespace(addon="fleet"))

    runs = _playbook_runs(app_ctx.runner)
    assert [name for name, _text, _job in runs] == ["provision.yml"]
    provision = runs[0][1]
    assert "replicas: 0" in provision
    assert "state: present" in provision
    assert "disk_size:" in provision
    assert "fleet" in (app_ctx.config.get("addons.enabled") or [])


def test_destroy_removes_controller_objects_before_the_namespace(app_ctx, monkeypatch) -> None:
    _pull_secret(app_ctx)
    _install_bins(monkeypatch)
    app_ctx.runner = _cluster_runner()
    monkeypatch.setattr(
        "aap_demo.addons.fleet.gateway.gateway_url", lambda _ctx: "https://gw.example"
    )
    monkeypatch.setattr("aap_demo.cluster.aap.admin_password", lambda _ctx, _ns: "secret")
    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=False))
    app_ctx.runner = _cluster_runner()

    get("fleet").destroy(app_ctx, argparse.Namespace())

    runs = _playbook_runs(app_ctx.runner)
    assert [name for name, _text, _job in runs] == ["import.yml", "provision.yml"]
    imported, provision = (text for _name, text, _job in runs)
    assert "state: absent" in imported
    assert "state: absent" in provision
    assert "fleet" not in (app_ctx.config.get("addons.enabled") or [])


def test_destroy_skips_controller_when_import_was_disabled(app_ctx, monkeypatch) -> None:
    _pull_secret(app_ctx)
    _install_bins(monkeypatch)
    app_ctx.runner = _cluster_runner()
    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))
    app_ctx.runner = _cluster_runner()

    get("fleet").destroy(app_ctx, argparse.Namespace())

    runs = _playbook_runs(app_ctx.runner)
    assert [name for name, _text, _job in runs] == ["provision.yml"]
    assert "state: absent" in runs[0][1]


def test_gateway_route_can_front_the_gateway_service(app_ctx) -> None:
    routes = {
        "items": [
            {
                "metadata": {"name": "aap"},
                "spec": {"host": "aap.apps.127.0.0.1.nip.io", "to": {"name": "aap"}},
            }
        ]
    }
    services = {
        "items": [
            {
                "metadata": {"name": "aap"},
                "spec": {"selector": {"app.kubernetes.io/component": "aap-gateway"}},
            }
        ]
    }
    app_ctx.runner = FakeRunner()
    app_ctx.runner.ok(
        ["kubectl", "get", "route", "-n", "aap-operator", "-l"],
        stdout="",
    )
    app_ctx.runner.ok(["kubectl", "get", "svc"], stdout=json.dumps(services))
    app_ctx.runner.ok(["kubectl", "get", "route"], stdout=json.dumps(routes))

    from aap_demo.addons.fleet.gateway import gateway_url

    assert gateway_url(app_ctx) == "https://aap.apps.127.0.0.1.nip.io"


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
    assert "kind: PersistentVolumeClaim" in provision
    # Keep numeric Kubernetes fields literal; use the scale module for the
    # disable path rather than templating an integer into a YAML string.
    assert "replicas: 1" in provision
    assert "kubernetes.core.k8s_scale" in provision
    assert "replicas: 0" in provision
    assert "(replicas | default(1) | int) != 0" in provision
    assert 'controller_host: "{{ aap_hostname }}"' in imported
    assert 'controller_username: "{{ aap_username }}"' in imported
    assert 'controller_password: "{{ aap_password }}"' in imported
    plays = yaml.safe_load(provision)
    deploy = next(
        task["kubernetes.core.k8s"]["definition"]
        for task in plays[0]["tasks"]
        if isinstance(task.get("kubernetes.core.k8s", {}).get("definition"), dict)
        and task["kubernetes.core.k8s"]["definition"].get("kind") == "Deployment"
    )
    assert "spec" not in deploy["metadata"]
    mounts = deploy["spec"]["template"]["spec"]["containers"][0]["volumeMounts"]
    mounted = {item["mountPath"]: item.get("subPath") for item in mounts}
    assert mounted["/usr"] == "usr"
    assert mounted["/var"] == "var"
    assert deploy["spec"]["strategy"]["type"] == "Recreate"
    disk = next(task for task in plays[0]["tasks"] if task["name"] == "Node disk")
    assert disk["when"] == "state == 'present' or scope == 'node'"
    assert "2Gi" in disk["vars"]["disk_body"]["spec"]["resources"]["requests"]["storage"]
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
