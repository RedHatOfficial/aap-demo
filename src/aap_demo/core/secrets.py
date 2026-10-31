"""The only module in the package that reads or writes a credential (design §5.5).

Three properties are load-bearing and must survive any refactor:

1. **Lazy resolution.** The keyring is never resolved at startup, only on first
   ``SecretStore`` access. Most commands (``create``, ``deploy``, ``status``,
   ``diagnose``) need no credential at all, and a headless box with no Secret
   Service provider must keep running them. Resolving eagerly would turn a
   keyring-less machine into a machine where ``aap-demo status`` fails (§5.5.3
   escape 2).

2. **Hard failure, never a fallback.** If the resolved backend is
   ``keyring.backends.fail.Keyring`` we exit 3 with a platform-specific message.
   There is deliberately no encrypted-file fallback: a machine-derived key next
   to its own ciphertext is obfuscation, and the mode rots into "secrets in a
   file" the first time someone makes the passphrase optional for CI (§5.5.3).

3. **No filesystem path of any kind.** This module opens no file, and
   ``tests/unit/test_secrets.py`` asserts that by inspecting its source. The
   name index below lives in the keyring itself for exactly that reason.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from typing import Dict, List, Optional

SERVICE = "aap-demo"

#: Keyring account under which the store keeps its own list of account names.
#: The OS credential APIs offer no portable enumeration, and ``list()`` must not
#: be the one thing that reintroduces a file.
_INDEX_ACCOUNT = "__index__"

_LINUX_HINT = (
    "Install and start a Secret Service provider (gnome-keyring or kwallet), "
    "or see the headless guidance in the docs."
)
_MACOS_HINT = (
    "The macOS Keychain backend is unavailable; check that the login keychain is unlocked."
)
_WINDOWS_HINT = (
    "The Windows Credential Manager backend is unavailable; check that the service is running."
)
_GENERIC_HINT = "Install a keyring backend supported on this platform."


@dataclass(frozen=True)
class SecretRef:
    """A credential's identity — never its value."""

    name: str
    backend: str


def _platform_hint() -> str:
    if sys.platform.startswith("linux"):
        return _LINUX_HINT
    if sys.platform == "darwin":
        return _MACOS_HINT
    if sys.platform.startswith("win"):
        return _WINDOWS_HINT
    return _GENERIC_HINT


class SecretStore:
    """Credential storage over the OS keyring, scoped by an optional prefix."""

    def __init__(self, *, prefix: str = "", backend: str = "auto") -> None:
        self._prefix = prefix
        self._backend_mode = backend
        self._keyring = None  # resolved lazily — see the module docstring

    # -- backend resolution -------------------------------------------------

    def _resolve(self):
        from aap_demo.core.errors import PrerequisiteError

        if self._keyring is not None:
            return self._keyring

        if self._backend_mode == "none":
            raise PrerequisiteError(
                "Credential storage is disabled (secrets.backend: none).",
                hint="Set secrets.backend to 'auto' to use the OS credential store.",
            )

        import keyring
        from keyring.backends import fail as _fail

        backend = keyring.get_keyring()
        if isinstance(backend, _fail.Keyring):
            raise PrerequisiteError(
                "No OS credential store is available, so aap-demo cannot store or read "
                "credentials on this machine.",
                hint=_platform_hint(),
            )
        self._keyring = backend
        return backend

    @property
    def backend_name(self) -> str:
        backend = self._resolve()
        return type(backend).__name__

    def available(self) -> bool:
        """Probe without raising. Used only by the migration's skip path (§12.2)."""
        from aap_demo.core.errors import PrerequisiteError

        try:
            self._resolve()
        except (PrerequisiteError, ImportError):
            return False
        return True

    # -- naming -------------------------------------------------------------

    def _account(self, name: str) -> str:
        return f"{self._prefix}{name}"

    def scoped(self, addon: str) -> "SecretStore":
        store = SecretStore(prefix=f"{self._prefix}addon:{addon}:", backend=self._backend_mode)
        store._keyring = self._keyring
        return store

    def namespaced(self, namespace: str) -> "SecretStore":
        store = SecretStore(prefix=f"{self._prefix}{namespace}:", backend=self._backend_mode)
        store._keyring = self._keyring
        return store

    # -- index --------------------------------------------------------------

    def _read_index(self) -> List[str]:
        backend = self._resolve()
        raw = backend.get_password(SERVICE, _INDEX_ACCOUNT)
        if not raw:
            return []
        try:
            names = json.loads(raw)
        except ValueError:
            return []
        return [n for n in names if isinstance(n, str)]

    def _write_index(self, names: List[str]) -> None:
        backend = self._resolve()
        backend.set_password(SERVICE, _INDEX_ACCOUNT, json.dumps(sorted(set(names))))

    # -- operations ---------------------------------------------------------

    def get(self, name: str) -> Optional[str]:
        backend = self._resolve()
        return backend.get_password(SERVICE, self._account(name))

    def set(self, name: str, value: str) -> None:
        backend = self._resolve()
        account = self._account(name)
        backend.set_password(SERVICE, account, value)
        index = self._read_index()
        if account not in index:
            self._write_index(index + [account])

    def delete(self, name: str) -> None:
        backend = self._resolve()
        account = self._account(name)
        try:
            backend.delete_password(SERVICE, account)
        except Exception:  # noqa: BLE001 - keyring raises backend-specific "not found"
            pass
        index = self._read_index()
        if account in index:
            self._write_index([n for n in index if n != account])

    def list(self) -> List[SecretRef]:
        """Names and backend, never values."""
        backend_name = self.backend_name
        accounts = self._read_index()
        if self._prefix:
            accounts = [a for a in accounts if a.startswith(self._prefix)]
        return [SecretRef(name=a, backend=backend_name) for a in sorted(accounts)]


class InMemorySecretStore(SecretStore):
    """Test double. Same contract, a dict instead of the OS keyring."""

    def __init__(self, *, prefix: str = "", store: Optional[Dict[str, str]] = None) -> None:
        super().__init__(prefix=prefix)
        self._store: Dict[str, str] = store if store is not None else {}

    def _resolve(self):
        return self

    @property
    def backend_name(self) -> str:
        return "InMemorySecretStore"

    def available(self) -> bool:
        return True

    def scoped(self, addon: str) -> "InMemorySecretStore":
        return InMemorySecretStore(prefix=f"{self._prefix}addon:{addon}:", store=self._store)

    def namespaced(self, namespace: str) -> "InMemorySecretStore":
        return InMemorySecretStore(prefix=f"{self._prefix}{namespace}:", store=self._store)

    def get(self, name: str) -> Optional[str]:
        return self._store.get(self._account(name))

    def set(self, name: str, value: str) -> None:
        self._store[self._account(name)] = value

    def delete(self, name: str) -> None:
        self._store.pop(self._account(name), None)

    def list(self) -> List[SecretRef]:
        return [
            SecretRef(name=k, backend=self.backend_name)
            for k in sorted(self._store)
            if k.startswith(self._prefix)
        ]
