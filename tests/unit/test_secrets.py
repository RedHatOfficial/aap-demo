"""SecretStore contract tests (design §5.5).

The two that must never be deleted: the no-backend hard-failure path, and the
assertion that this module has no filesystem write path at all.
"""

from __future__ import annotations

import ast
import inspect
from typing import Dict, Optional

import pytest

from aap_demo.core import secrets as secrets_mod
from aap_demo.core.errors import PrerequisiteError
from aap_demo.core.secrets import SERVICE, InMemorySecretStore, SecretStore


class _DictBackend:
    def __init__(self) -> None:
        self.data: Dict[str, str] = {}
        self.resolved = 0

    def get_password(self, service: str, account: str) -> Optional[str]:
        assert service == SERVICE
        return self.data.get(account)

    def set_password(self, service: str, account: str, value: str) -> None:
        self.data[account] = value

    def delete_password(self, service: str, account: str) -> None:
        if account not in self.data:
            raise KeyError(account)
        del self.data[account]


@pytest.fixture
def backed_store() -> SecretStore:
    store = SecretStore()
    store._keyring = _DictBackend()
    return store


# -- lazy resolution --------------------------------------------------------


def test_construction_never_resolves_the_keyring(monkeypatch: pytest.MonkeyPatch) -> None:
    """A keyring-less machine must still be able to run `status` and `deploy` (§5.5.3)."""
    import keyring

    def explode() -> None:
        raise AssertionError("the keyring was resolved at construction time")

    monkeypatch.setattr(keyring, "get_keyring", explode)
    SecretStore()  # must not raise
    SecretStore().scoped("portal")  # scoping must not resolve either


def test_resolution_happens_once(monkeypatch: pytest.MonkeyPatch) -> None:
    import keyring

    backend = _DictBackend()
    calls = {"n": 0}

    def get_keyring():
        calls["n"] += 1
        return backend

    monkeypatch.setattr(keyring, "get_keyring", get_keyring)
    store = SecretStore()
    store.set("admin-password", "s3cret")
    store.get("admin-password")
    assert calls["n"] == 1


# -- the no-backend hard-failure path ---------------------------------------


def test_no_backend_fails_loudly_with_exit_code_3(monkeypatch: pytest.MonkeyPatch) -> None:
    import keyring
    from keyring.backends import fail

    monkeypatch.setattr(keyring, "get_keyring", lambda: fail.Keyring())
    store = SecretStore()

    with pytest.raises(PrerequisiteError) as excinfo:
        store.get("admin-password")

    assert excinfo.value.exit_code == 3
    assert "credential store" in excinfo.value.message
    assert excinfo.value.hint  # platform-specific, and always present


@pytest.mark.parametrize(
    ("platform", "needle"),
    [
        ("linux", "Secret Service"),
        ("darwin", "Keychain"),
        ("win32", "Credential Manager"),
    ],
)
def test_no_backend_message_names_the_platform(
    monkeypatch: pytest.MonkeyPatch, platform: str, needle: str
) -> None:
    import keyring
    from keyring.backends import fail

    monkeypatch.setattr(secrets_mod.sys, "platform", platform)
    monkeypatch.setattr(keyring, "get_keyring", lambda: fail.Keyring())

    with pytest.raises(PrerequisiteError) as excinfo:
        SecretStore().get("x")
    assert needle in (excinfo.value.hint or "")


def test_available_probes_without_raising(monkeypatch: pytest.MonkeyPatch) -> None:
    import keyring
    from keyring.backends import fail

    monkeypatch.setattr(keyring, "get_keyring", lambda: fail.Keyring())
    assert SecretStore().available() is False


def test_backend_none_is_an_explicit_refusal() -> None:
    with pytest.raises(PrerequisiteError):
        SecretStore(backend="none").get("x")


# -- no filesystem path -----------------------------------------------------

_FILESYSTEM_CALLS = {
    "open",
    "read_text",
    "write_text",
    "read_bytes",
    "write_bytes",
    "mkdir",
    "unlink",
    "chmod",
    "remove",
    "rename",
    "replace",
}
_FILESYSTEM_MODULES = {"os", "io", "shutil", "pathlib", "tempfile", "os.path"}


def test_secrets_module_has_no_filesystem_write_path() -> None:
    """§5.5 is explicit: SecretStore must have no code path that opens a file.

    The name index therefore lives in the keyring itself. This test is the thing
    that stops a future 'small' cache file from reintroducing plaintext secrets
    on disk.
    """
    tree = ast.parse(inspect.getsource(secrets_mod))

    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            imported.add(node.module)
    assert not (imported & _FILESYSTEM_MODULES), (
        f"core/secrets.py imports filesystem modules: {sorted(imported & _FILESYSTEM_MODULES)}"
    )

    called = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        name = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", None)
        if name:
            called.add(name)
    assert not (called & _FILESYSTEM_CALLS), (
        f"core/secrets.py performs filesystem calls: {sorted(called & _FILESYSTEM_CALLS)}"
    )


# -- contract ---------------------------------------------------------------


def test_get_set_delete_round_trip(backed_store: SecretStore) -> None:
    assert backed_store.get("admin-password") is None
    backed_store.set("admin-password", "s3cret")
    assert backed_store.get("admin-password") == "s3cret"
    backed_store.delete("admin-password")
    assert backed_store.get("admin-password") is None


def test_delete_is_idempotent(backed_store: SecretStore) -> None:
    backed_store.delete("never-existed")  # must not raise


def test_scoped_store_prefixes_addon_names(backed_store: SecretStore) -> None:
    portal = backed_store.scoped("portal")
    portal.set("oauth-refresh-token", "tok")

    assert portal.get("oauth-refresh-token") == "tok"
    assert backed_store.get("oauth-refresh-token") is None
    assert backed_store.get("addon:portal:oauth-refresh-token") == "tok"


def test_namespaced_store_prefixes_cluster_secrets(backed_store: SecretStore) -> None:
    ns = backed_store.namespaced("aap-operator")
    ns.set("admin-password", "s3cret")
    assert backed_store.get("aap-operator:admin-password") == "s3cret"


def test_list_returns_names_and_backend_never_values(backed_store: SecretStore) -> None:
    backed_store.set("admin-password", "s3cret")
    backed_store.scoped("portal").set("oauth-refresh-token", "rEfrEshV4lue")

    refs = backed_store.list()
    names = [ref.name for ref in refs]
    assert names == ["addon:portal:oauth-refresh-token", "admin-password"]
    assert all(ref.backend == "_DictBackend" for ref in refs)
    assert not any("s3cret" in repr(ref) or "rEfrEshV4lue" in repr(ref) for ref in refs)


def test_list_is_scoped(backed_store: SecretStore) -> None:
    backed_store.set("admin-password", "s3cret")
    portal = backed_store.scoped("portal")
    portal.set("oauth-refresh-token", "tok")
    assert [r.name for r in portal.list()] == ["addon:portal:oauth-refresh-token"]


def test_index_survives_a_corrupt_entry(backed_store: SecretStore) -> None:
    backed_store._keyring.data["__index__"] = "not json"
    backed_store.set("admin-password", "s3cret")
    assert [r.name for r in backed_store.list()] == ["admin-password"]


def test_in_memory_store_matches_the_contract() -> None:
    store = InMemorySecretStore()
    store.set("a", "1")
    store.scoped("portal").set("b", "2")
    assert store.get("a") == "1"
    assert store.scoped("portal").get("b") == "2"
    assert [r.name for r in store.list()] == ["a", "addon:portal:b"]
    store.delete("a")
    assert store.get("a") is None
