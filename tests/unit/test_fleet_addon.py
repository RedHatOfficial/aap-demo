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
    {
        "items": [
            {
                "metadata": {
                    "ownerReferences": [
                        {
                            "kind": "ReplicaSet",
                            "name": "aap-controller-task-rs",
                            "controller": True,
                        }
                    ]
                },
                "status": {
                    "phase": "Running",
                    "conditions": [{"type": "Ready", "status": "True"}],
                },
                "spec": {"containers": [{"name": "aap-controller-ee", "image": EE_IMAGE}]},
            }
        ]
    }
)
EE_REPLICA_SETS = json.dumps(
    {
        "items": [
            {
                "metadata": {
                    "name": "aap-controller-task-rs",
                    "ownerReferences": [
                        {"kind": "Deployment", "name": "aap-controller-task", "controller": True}
                    ],
                }
            }
        ]
    }
)
EE_DEPLOYMENTS = json.dumps(
    {
        "items": [
            {
                "metadata": {
                    "name": "aap-controller-task",
                    "ownerReferences": [{"kind": "AutomationController", "name": "aap-controller"}],
                }
            }
        ]
    }
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


def _namespace_stdout(token: str) -> str:
    return json.dumps(
        {"metadata": {"name": "fleet", "annotations": {"aap-demo/fleet-token": token}}}
    )


def _cluster_runner(
    *,
    namespace_stdout: str | None = None,
    namespace_error: str | None = None,
    wait_ok: bool = True,
) -> FakeRunner:
    runner = FakeRunner()
    runner.register(["/usr/bin/ssh-keygen"], _keygen)
    runner.fail(["kubectl", "get", "clusterrolebinding"], stderr="NotFound")
    runner.fail(["kubectl", "get", "clusterrole", "aap-demo-fleet-runner"], stderr="NotFound")
    runner.fail(["kubectl", "get", "serviceaccount", "aap-demo-fleet-runner"], stderr="NotFound")
    runner.ok(["kubectl", "get", "pods"], stdout=EE_PODS)
    runner.ok(["kubectl", "get", "rs"], stdout=EE_REPLICA_SETS)
    runner.ok(["kubectl", "get", "deploy"], stdout=EE_DEPLOYMENTS)
    if namespace_error:
        runner.fail(["kubectl", "get", "namespace"], stderr=namespace_error)
    elif namespace_stdout is None:
        runner.fail(["kubectl", "get", "namespace"], stderr="NotFound")
    else:
        runner.ok(["kubectl", "get", "namespace"], stdout=namespace_stdout)
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
    runner.ok(["kubectl", "get", "secrets"], stdout="")
    runner.ok(["kubectl", "apply"])
    if wait_ok:
        runner.ok(["kubectl", "wait"])
    else:
        runner.fail(["kubectl", "wait"], stderr="timed out")
    runner.ok(["kubectl", "delete"])
    runner.ok(["kubectl", "logs"], stdout="boom")
    return runner


def _gateway_chain(*, owned: bool = True, spoof_route: bool = False) -> FakeRunner:
    labels = {
        "app.kubernetes.io/component": "aap-gateway",
        "app.kubernetes.io/managed-by": "aap-operator",
    }
    owner_kind = "AnsibleAutomationPlatform" if owned else "ReplicaSet"
    deploy = {
        "items": [
            {
                "metadata": {
                    "name": "aap-gateway",
                    "ownerReferences": [{"kind": owner_kind, "name": "aap", "controller": True}],
                },
                "spec": {"selector": {"matchLabels": labels}},
            }
        ]
    }
    replica_sets = {
        "items": [
            {
                "metadata": {
                    "name": "aap-gateway-rs",
                    "ownerReferences": [
                        {"kind": "Deployment", "name": "aap-gateway", "controller": True}
                    ],
                }
            }
        ]
    }
    pods = {
        "items": [
            {
                "metadata": {
                    "name": "gateway-0",
                    "ownerReferences": [
                        {"kind": "ReplicaSet", "name": "aap-gateway-rs", "controller": True}
                    ],
                },
                "status": {
                    "phase": "Running",
                    "conditions": [{"type": "Ready", "status": "True"}],
                },
            }
        ]
    }
    services = {
        "items": [
            {
                "metadata": {"name": "aap"},
                "spec": {"selector": {**labels, "app.kubernetes.io/part-of": "aap"}},
            }
        ]
    }
    routes = [
        {
            "metadata": {"name": "aap"},
            "spec": {"host": "aap.apps.127.0.0.1.nip.io", "to": {"name": "aap"}},
        }
    ]
    if spoof_route:
        routes.insert(
            0,
            {
                "metadata": {
                    "name": "evil-gateway",
                    "labels": {"app.kubernetes.io/name": "gateway"},
                },
                "spec": {"host": "evil.example", "to": {"name": "evil"}},
            },
        )
    endpoints = {
        "subsets": [
            {"addresses": [{"ip": "10.0.0.8", "targetRef": {"kind": "Pod", "name": "gateway-0"}}]}
        ]
    }
    runner = FakeRunner()
    runner.ok(["kubectl", "get", "deploy"], stdout=json.dumps(deploy))
    runner.ok(["kubectl", "get", "rs"], stdout=json.dumps(replica_sets))
    runner.ok(["kubectl", "get", "pods"], stdout=json.dumps(pods))
    runner.ok(["kubectl", "get", "svc"], stdout=json.dumps(services))
    runner.ok(["kubectl", "get", "endpoints"], stdout=json.dumps(endpoints))
    runner.ok(["kubectl", "get", "route"], stdout=json.dumps({"items": routes}))
    return runner


def _owned_runner(app_ctx) -> FakeRunner:
    token = app_ctx.config.get("addons.options")["fleet"]["namespace_token"]
    return _cluster_runner(namespace_stdout=_namespace_stdout(token))


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
    assert "fleet-ubi9" in provision and "fleet-ubi10" in provision
    assert "registry.access.redhat.com/ubi9/ubi:9.6" in provision
    assert "registry.access.redhat.com/ubi10/ubi:10.2" in provision
    assert "PRIVATE-KEY" not in provision
    assert "pull_secret_path: ''" in provision or 'pull_secret_path: ""' in provision
    assert "PRIVATE-KEY" in imported
    assert "namespace: fleet" in imported
    assert "aap_validate_certs: true" in imported
    applied = _applied(app_ctx.runner)
    kinds = [document.get("kind") for document in applied]
    assert "ClusterRole" not in kinds
    assert "ClusterRoleBinding" not in kinds
    runner_account = next(
        document
        for document in applied
        if document.get("kind") == "ServiceAccount"
        and document["metadata"]["name"] == "aap-demo-fleet-runner"
    )
    assert runner_account["metadata"]["namespace"] == "fleet-runner"
    assert runner_account["automountServiceAccountToken"] is False
    binding = next(
        document
        for document in applied
        if document.get("kind") == "RoleBinding"
        and document["metadata"]["name"] == "aap-demo-fleet-runner"
        and document["metadata"]["namespace"] == "fleet"
    )
    assert binding["subjects"][0]["namespace"] == "fleet-runner"
    runner_role = next(
        document
        for document in applied
        if document.get("kind") == "Role" and document["metadata"]["namespace"] == "fleet-runner"
    )
    assert runner_role["rules"] == [
        {"apiGroups": [""], "resources": ["secrets", "configmaps"], "verbs": ["get"]}
    ]
    anyuid = next(
        document for document in applied if document["metadata"]["name"] == "fleet-anyuid"
    )
    assert anyuid["metadata"]["namespace"] == "fleet"
    assert anyuid["subjects"][0]["name"] == "fleet-node"
    assert provision_job["metadata"]["namespace"] == "fleet-runner"
    image = provision_job["spec"]["template"]["spec"]["containers"][0]["image"]
    assert image == EE_IMAGE
    assert "hostAliases" not in provision_job["spec"]["template"]["spec"]
    alias = import_job["spec"]["template"]["spec"]["hostAliases"][0]
    assert alias["ip"] == "10.43.72.238"
    assert alias["hostnames"] == ["gw.example"]
    assert any(call.argv[1] == "delete" for call in app_ctx.runner.calls)
    cleanup = next(
        call.argv
        for call in app_ctx.runner.calls
        if call.argv[1] == "delete" and any(arg.startswith("job/") for arg in call.argv)
    )
    assert any(arg.startswith("configmap/") for arg in cleanup)
    assert any(arg.startswith("secret/") for arg in cleanup)
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


def test_enable_does_not_need_a_pull_secret(app_ctx, monkeypatch) -> None:
    _install_bins(monkeypatch)
    app_ctx.config.set("deploy.pull_secret_path", "")
    app_ctx.runner = _cluster_runner()

    assert get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True)) == 0

    provision = _playbook_runs(app_ctx.runner)[0][1]
    assert "pull_secret_path: ''" in provision or 'pull_secret_path: ""' in provision


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
        get("fleet").add(app_ctx, argparse.Namespace(os="ubi10", name=None))


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

    get("fleet").add(app_ctx, argparse.Namespace(os="ubi10", name="extra-ubi10"))

    names_run = [name for name, _text, _job in _playbook_runs(app_ctx.runner)]
    assert names_run == ["provision.yml", "import.yml"]
    nodes = app_ctx.config.get("addons.options")["fleet"]["nodes"]
    assert any(node["name"] == "extra-ubi10" for node in nodes)


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
    app_ctx.runner = _owned_runner(app_ctx)

    get("fleet").destroy(app_ctx, argparse.Namespace())

    runs = _playbook_runs(app_ctx.runner)
    assert [name for name, _text, _job in runs] == ["import.yml", "provision.yml"]
    imported, provision = (text for _name, text, _job in runs)
    assert "state: absent" in imported
    assert "state: absent" in provision
    assert "fleet" not in (app_ctx.config.get("addons.enabled") or [])
    assert app_ctx.runner.called(["kubectl", "delete", "namespace"])
    assert "namespace_token" not in (app_ctx.config.get("addons.options")["fleet"])


def test_destroy_skips_controller_when_import_was_disabled(app_ctx, monkeypatch) -> None:
    _pull_secret(app_ctx)
    _install_bins(monkeypatch)
    app_ctx.runner = _cluster_runner()
    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))
    app_ctx.runner = _owned_runner(app_ctx)

    get("fleet").destroy(app_ctx, argparse.Namespace())

    runs = _playbook_runs(app_ctx.runner)
    assert [name for name, _text, _job in runs] == ["provision.yml"]
    assert "state: absent" in runs[0][1]


def test_no_import_after_import_still_destroys_controller_objects(app_ctx, monkeypatch) -> None:
    _pull_secret(app_ctx)
    _install_bins(monkeypatch)
    app_ctx.runner = _cluster_runner()
    monkeypatch.setattr(
        "aap_demo.addons.fleet.gateway.gateway_url", lambda _ctx: "https://gw.example"
    )
    monkeypatch.setattr("aap_demo.cluster.aap.admin_password", lambda _ctx, _ns: "secret")
    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=False))
    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))
    assert app_ctx.config.get("addons.options")["fleet"]["import"] is True
    app_ctx.runner = _owned_runner(app_ctx)

    get("fleet").destroy(app_ctx, argparse.Namespace())

    runs = _playbook_runs(app_ctx.runner)
    assert [name for name, _text, _job in runs] == ["import.yml", "provision.yml"]


def test_gateway_route_can_front_the_gateway_service(app_ctx) -> None:
    app_ctx.runner = _gateway_chain()

    from aap_demo.addons.fleet.gateway import gateway_url

    assert gateway_url(app_ctx) == "https://aap.apps.127.0.0.1.nip.io"


def test_gateway_ignores_a_route_that_is_only_named_gateway(app_ctx) -> None:
    app_ctx.runner = _gateway_chain(spoof_route=True)

    from aap_demo.addons.fleet.gateway import gateway_url

    assert gateway_url(app_ctx) == "https://aap.apps.127.0.0.1.nip.io"


def test_gateway_refuses_a_name_suffix_without_the_service(app_ctx) -> None:
    app_ctx.runner = FakeRunner()
    app_ctx.runner.ok(["kubectl", "get", "deploy"], stdout='{"items":[]}')

    from aap_demo.addons.fleet.gateway import gateway_url

    with pytest.raises(AddonError, match="gateway deployment not found"):
        gateway_url(app_ctx)


def test_gateway_refuses_a_replicaset_the_operator_does_not_own(app_ctx) -> None:
    app_ctx.runner = _gateway_chain(owned=False)

    from aap_demo.addons.fleet.gateway import gateway_url

    with pytest.raises(AddonError, match="gateway deployment not found"):
        gateway_url(app_ctx)


def test_runner_namespace_stays_within_the_dns_limit() -> None:
    from aap_demo.addons.fleet.job import runner_namespace

    assert runner_namespace("fleet") == "fleet-runner"
    name = runner_namespace("n" * 63)
    assert len(name) <= 63
    assert name.startswith("fleet-runner-")


def test_ee_image_rejects_a_lookalike() -> None:
    from aap_demo.addons.fleet.ee import _ee_image

    lookalike = {
        "items": [
            {
                "status": {
                    "phase": "Running",
                    "conditions": [{"type": "Ready", "status": "True"}],
                },
                "spec": {
                    "containers": [
                        {"name": "evil", "image": "registry.redhat.io/x/ee-supported-rhel9:latest"},
                        {
                            "name": "aap-controller-ee",
                            "image": "quay.io/someone/ee-supported-rhel9:latest",
                        },
                    ]
                },
            }
        ]
    }
    assert _ee_image(json.dumps(lookalike)) == ""
    trusted = {
        "items": [
            {
                "metadata": {
                    "ownerReferences": [
                        {"kind": "ReplicaSet", "name": "aap-controller-task-rs", "controller": True}
                    ]
                },
                "status": {
                    "phase": "Running",
                    "conditions": [{"type": "Ready", "status": "True"}],
                },
                "spec": {"containers": [{"name": "aap-controller-ee", "image": EE_IMAGE}]},
            }
        ]
    }
    assert _ee_image(json.dumps(trusted), EE_REPLICA_SETS, EE_DEPLOYMENTS) == EE_IMAGE
    assert _ee_image(json.dumps(trusted)) == ""


def test_enable_refuses_a_namespace_it_does_not_own(app_ctx, monkeypatch) -> None:
    _install_bins(monkeypatch)
    labeled = json.dumps({"metadata": {"labels": {"aap-demo/fleet": "true"}}})
    app_ctx.runner = _cluster_runner(namespace_stdout=labeled)

    with pytest.raises(AddonError, match="refusing to use namespace"):
        get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))

    assert "fleet" not in (app_ctx.config.get("addons.enabled") or [])


def test_ssh_key_read_failure_does_not_create_a_new_key(app_ctx) -> None:
    from aap_demo.addons.fleet import sshkey

    app_ctx.runner = FakeRunner()
    app_ctx.runner.fail(["kubectl", "get", "secret"], stderr="connection timed out")

    with pytest.raises(AddonError, match="could not read the fleet SSH key"):
        sshkey.load_or_create(app_ctx)

    assert [call.argv[1] for call in app_ctx.runner.calls] == ["get"]


def test_import_rejects_a_custom_scm_url(app_ctx, monkeypatch) -> None:
    _install_bins(monkeypatch)
    monkeypatch.setattr(
        "aap_demo.addons.fleet.gateway.gateway_url", lambda _ctx: "https://gw.example"
    )
    monkeypatch.setattr("aap_demo.cluster.aap.admin_password", lambda _ctx, _ns: "secret")
    app_ctx.config.set(
        "addons.options",
        {"fleet": {"scm_url": "https://evil.example/repo.git"}},
    )
    app_ctx.runner = _cluster_runner()

    with pytest.raises(AddonError, match="official repository"):
        get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=False))


def test_enable_does_not_record_success_when_the_playbook_fails(app_ctx, monkeypatch) -> None:
    _install_bins(monkeypatch)
    app_ctx.runner = _cluster_runner(wait_ok=False)

    with pytest.raises(AddonError, match="playbook failed"):
        get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))

    assert "fleet" not in (app_ctx.config.get("addons.enabled") or [])
    fleet = (app_ctx.config.get("addons.options") or {}).get("fleet") or {}
    assert not fleet.get("nodes")
    assert fleet.get("namespace_token")


def test_destroy_refuses_an_unowned_namespace(app_ctx, monkeypatch) -> None:
    _install_bins(monkeypatch)
    app_ctx.runner = _cluster_runner()
    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))
    foreign = json.dumps({"metadata": {"annotations": {"aap-demo/fleet-token": "someone-else"}}})
    app_ctx.runner = _cluster_runner(namespace_stdout=foreign)

    with pytest.raises(AddonError, match="refusing to use namespace"):
        get("fleet").destroy(app_ctx, argparse.Namespace())

    assert "fleet" in (app_ctx.config.get("addons.enabled") or [])
    assert not app_ctx.runner.called(["kubectl", "delete", "namespace"])


def test_destroy_refuses_a_copied_namespace_token(app_ctx, monkeypatch) -> None:
    _install_bins(monkeypatch)
    app_ctx.runner = _cluster_runner()
    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))
    fleet = dict(app_ctx.config.get("addons.options")["fleet"])
    fleet["namespace_uid"] = "uid-1"
    app_ctx.config.set("addons.options", {"fleet": fleet})
    app_ctx.config.set("addons.enabled", ["fleet"])
    stolen = json.dumps(
        {
            "metadata": {
                "uid": "uid-2",
                "annotations": {"aap-demo/fleet-token": fleet["namespace_token"]},
            }
        }
    )
    app_ctx.runner = _cluster_runner(namespace_stdout=stolen)

    with pytest.raises(AddonError, match="refusing to use namespace"):
        get("fleet").destroy(app_ctx, argparse.Namespace())

    assert "fleet" in (app_ctx.config.get("addons.enabled") or [])


def test_destroy_keeps_state_when_the_namespace_cannot_be_read(app_ctx, monkeypatch) -> None:
    _install_bins(monkeypatch)
    app_ctx.runner = _cluster_runner()
    get("fleet").enable(app_ctx, argparse.Namespace(addon="fleet", no_import=True))
    app_ctx.runner = _cluster_runner(namespace_error="connection timed out")

    with pytest.raises(AddonError, match="could not read namespace"):
        get("fleet").destroy(app_ctx, argparse.Namespace())

    assert "fleet" in (app_ctx.config.get("addons.enabled") or [])


def test_destroy_removes_controller_objects_after_the_last_node(app_ctx, monkeypatch) -> None:
    _install_bins(monkeypatch)
    monkeypatch.setattr(
        "aap_demo.addons.fleet.gateway.gateway_url", lambda _ctx: "https://gw.example"
    )
    monkeypatch.setattr("aap_demo.cluster.aap.admin_password", lambda _ctx, _ns: "secret")
    app_ctx.config.set(
        "addons.options",
        {"fleet": {"import": True, "nodes": [], "namespace": "fleet", "namespace_token": "tok"}},
    )
    app_ctx.config.set("addons.enabled", ["fleet"])
    app_ctx.runner = _cluster_runner(namespace_stdout=_namespace_stdout("tok"))

    get("fleet").destroy(app_ctx, argparse.Namespace())

    runs = [name for name, _text, _job in _playbook_runs(app_ctx.runner)]
    assert runs[0] == "import.yml"
    assert "fleet" not in (app_ctx.config.get("addons.enabled") or [])


def test_packaged_files_load_through_importlib() -> None:
    for name in (
        "playbooks/provision.yml",
        "playbooks/import.yml",
        "playbooks/ping.yml",
        "entrypoint.sh",
    ):
        assert resources.read_text(name)
    script = resources.read_text("entrypoint.sh")
    assert "dnf reinstall -y openssh-server sudo" in script
    assert "apt-get install -y --reinstall openssh-server sudo" in script
    assert "ETC_SAVE=/var/lib/fleet-etc" in script
    assert "groupadd --system" in script
    assert "mkdir -p /etc/ssh /etc/sudoers.d" in script


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
    assert "system:serviceaccounts" not in provision
    assert "scc:anyuid" not in provision
    assert "name: fleet-node" in provision
    assert "aap_validate_certs | default(true)" in imported
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
        "ansible.controller.project_update",
        "ansible.controller.job_template",
    ):
        assert module in imported
    assert "{{ namespace }}" in imported
    assert "ansible.builtin.ping" in ping
    imported_tasks = yaml.safe_load(imported)[0]["tasks"]
    imported_names = [task["name"] for task in imported_tasks]
    assert imported_names.index("Inventory") < imported_names.index("Hosts")
    assert imported_names.index("Ping job template") < imported_names.index("Remove inventory")
    assert imported_names.index("Hosts") < imported_names.index("Remove inventory")


def test_help_lists_enable_disable_and_fleet() -> None:
    help_text = build_parser().format_help()
    for command in ("enable", "disable", "fleet"):
        assert command in help_text
