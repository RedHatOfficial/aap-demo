"""``cluster/kubeconfig.py``: extraction, validation, and the rename (design
§2.2: ``cmd_kubeconfig`` → ``cluster/kubeconfig.py::sync()``).
"""

from __future__ import annotations

import stat
from pathlib import Path

import pytest
import yaml

from aap_demo.cluster import kubeconfig as kubeconfig_mod
from aap_demo.core.errors import AapDemoError
from aap_demo.exec.runner import FakeRunner

SAMPLE_KUBECONFIG = """\
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: QQ==
    server: https://127.0.0.1:6443
  name: microshift
contexts:
- context:
    cluster: microshift
    namespace: default
    user: user
  name: microshift
current-context: microshift
users:
- name: user
  user:
    client-certificate-data: QQ==
    client-key-data: QQ==
"""


@pytest.fixture
def ssh_key(tmp_path: Path) -> Path:
    key = tmp_path / "id_ed25519"
    key.write_text("fake-key")
    return key


def test_extract_raw_returns_the_remote_cat_output(fake_runner: FakeRunner, ssh_key: Path) -> None:
    fake_runner.ok("ssh -p 2222", stdout=SAMPLE_KUBECONFIG)
    raw = kubeconfig_mod.extract_raw(fake_runner, ssh_key)
    assert raw == SAMPLE_KUBECONFIG
    # argv shape (flags, port, ssh options) is covered by test_exec_ssh.py.
    assert fake_runner.called("ssh -p 2222")


def test_extract_raw_raises_when_ssh_fails(fake_runner: FakeRunner, ssh_key: Path) -> None:
    fake_runner.fail(
        "ssh -p 2222", stderr="ssh: connect to host 127.0.0.1 port 2222: Connection refused"
    )
    with pytest.raises(AapDemoError, match="Failed to extract kubeconfig"):
        kubeconfig_mod.extract_raw(fake_runner, ssh_key)


def test_extract_raw_raises_when_output_is_empty(fake_runner: FakeRunner, ssh_key: Path) -> None:
    fake_runner.ok("ssh -p 2222", stdout="")
    with pytest.raises(AapDemoError, match="Failed to extract kubeconfig"):
        kubeconfig_mod.extract_raw(fake_runner, ssh_key)


def test_sync_renames_cluster_context_and_user(
    fake_runner: FakeRunner, ssh_key: Path, tmp_path: Path
) -> None:
    fake_runner.ok("ssh -p 2222", stdout=SAMPLE_KUBECONFIG)
    fake_runner.ok("kubectl config view", stdout=SAMPLE_KUBECONFIG)
    destination = tmp_path / "state" / "kubeconfig.microshift"

    result_path = kubeconfig_mod.sync(fake_runner, key=ssh_key, destination=destination)

    assert result_path == destination
    written = yaml.safe_load(destination.read_text())
    assert written["current-context"] == "aap-demo"
    assert written["clusters"][0]["name"] == "aap-demo"
    assert written["clusters"][0]["cluster"]["insecure-skip-tls-verify"] is True
    assert "certificate-authority-data" not in written["clusters"][0]["cluster"]
    assert written["contexts"][0]["name"] == "aap-demo"
    assert written["contexts"][0]["context"]["cluster"] == "aap-demo"
    assert written["contexts"][0]["context"]["user"] == "aap-demo"
    assert written["users"][0]["name"] == "aap-demo"


FILE_FORM_CA_KUBECONFIG = """\
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: /var/lib/microshift/certs/ca.crt
    proxy-url: http://proxy.example.com:3128
    tls-server-name: api.example.com
    server: https://127.0.0.1:6443
  name: microshift
contexts:
- context:
    cluster: microshift
    user: user
  name: microshift
current-context: microshift
users:
- name: user
  user:
    client-certificate-data: QQ==
"""


def test_sync_drops_the_file_form_certificate_authority(
    fake_runner: FakeRunner, ssh_key: Path, tmp_path: Path
) -> None:
    """``certificate-authority`` alongside ``insecure-skip-tls-verify`` is a
    kubeconfig kubectl rejects outright. Bash never produced one: it built a
    fresh cluster entry (server + insecure flag only) instead of deleting keys
    from a copy, which also dropped proxy-url/tls-server-name."""
    fake_runner.ok("ssh -p 2222", stdout=FILE_FORM_CA_KUBECONFIG)
    fake_runner.ok("kubectl config view", stdout=FILE_FORM_CA_KUBECONFIG)
    destination = tmp_path / "kubeconfig.microshift"

    kubeconfig_mod.sync(fake_runner, key=ssh_key, destination=destination)

    cluster = yaml.safe_load(destination.read_text())["clusters"][0]["cluster"]
    assert cluster == {"server": "https://127.0.0.1:6443", "insecure-skip-tls-verify": True}


def test_write_private_never_exposes_the_file_at_the_process_umask(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The mode must be right *before* the content reaches its final path:
    ``write_text`` then ``chmod`` leaves a window in which cluster-admin
    credentials are readable at the process umask. Inspecting only the final
    mode (the test below) cannot see that window, so spy on the rename."""
    modes: list = []
    real_replace = kubeconfig_mod.os.replace

    def spy_replace(src, dst):  # type: ignore[no-untyped-def]
        modes.append(stat.S_IMODE(Path(src).stat().st_mode))
        return real_replace(src, dst)

    monkeypatch.setattr(kubeconfig_mod.os, "replace", spy_replace)

    destination = tmp_path / "nested" / "kubeconfig"
    kubeconfig_mod.write_private(destination, "secret")

    assert modes == [0o600]
    assert destination.read_text() == "secret"
    # ...and no leftover temp file beside it.
    assert [p.name for p in destination.parent.iterdir()] == ["kubeconfig"]


def test_sync_writes_the_file_with_owner_only_permissions(
    fake_runner: FakeRunner, ssh_key: Path, tmp_path: Path
) -> None:
    fake_runner.ok("ssh -p 2222", stdout=SAMPLE_KUBECONFIG)
    fake_runner.ok("kubectl config view", stdout=SAMPLE_KUBECONFIG)
    destination = tmp_path / "kubeconfig.microshift"

    kubeconfig_mod.sync(fake_runner, key=ssh_key, destination=destination)

    mode = stat.S_IMODE(destination.stat().st_mode)
    assert mode == 0o600


def test_sync_raises_when_kubectl_validation_fails(
    fake_runner: FakeRunner, ssh_key: Path, tmp_path: Path
) -> None:
    fake_runner.ok("ssh -p 2222", stdout=SAMPLE_KUBECONFIG)
    fake_runner.fail("kubectl config view", stderr="error loading config")
    destination = tmp_path / "kubeconfig.microshift"

    with pytest.raises(AapDemoError, match="Extracted kubeconfig is invalid"):
        kubeconfig_mod.sync(fake_runner, key=ssh_key, destination=destination)

    assert not destination.exists()


def test_sync_raises_on_non_yaml_output(
    fake_runner: FakeRunner, ssh_key: Path, tmp_path: Path
) -> None:
    fake_runner.ok("ssh -p 2222", stdout="not: [valid: yaml")
    fake_runner.ok("kubectl config view", stdout="")
    destination = tmp_path / "kubeconfig.microshift"

    with pytest.raises(AapDemoError, match="Extracted kubeconfig is invalid"):
        kubeconfig_mod.sync(fake_runner, key=ssh_key, destination=destination)


def test_sync_skips_kubectl_validation_when_disabled(
    fake_runner: FakeRunner, ssh_key: Path, tmp_path: Path
) -> None:
    fake_runner.ok("ssh -p 2222", stdout=SAMPLE_KUBECONFIG)
    destination = tmp_path / "kubeconfig.microshift"

    kubeconfig_mod.sync(fake_runner, key=ssh_key, destination=destination, validate=False)

    assert destination.exists()
    assert not fake_runner.called("kubectl config view")


def test_activate_context_keeps_other_contexts_and_selects_aap_demo(
    fake_runner: FakeRunner, ssh_key: Path, tmp_path: Path
) -> None:
    fake_runner.ok("ssh -p 2222", stdout=SAMPLE_KUBECONFIG)
    source = tmp_path / "kubeconfig.microshift"
    kubeconfig_mod.sync(fake_runner, key=ssh_key, destination=source, validate=False)
    target = tmp_path / ".kube" / "config"
    target.parent.mkdir()
    target.write_text(
        "apiVersion: v1\nkind: Config\ncurrent-context: other\n"
        "clusters:\n- name: other\n  cluster: {server: https://example}\n"
        "contexts:\n- name: other\n  context: {cluster: other, user: other}\n"
        "users:\n- name: other\n  user: {token: t}\n"
    )

    kubeconfig_mod.activate_context(source, target)

    loaded = yaml.safe_load(target.read_text())
    names = {entry["name"] for entry in loaded["contexts"]}
    assert names == {"other", "aap-demo"}
    assert loaded["current-context"] == "aap-demo"
