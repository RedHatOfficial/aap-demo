"""Kubeconfig extraction and renaming (design §2.2: ``cmd_kubeconfig`` →
``cluster/kubeconfig.py::sync()``).

Bash performs the rename — the generic ``microshift``/``user`` names CRC ships
collide across clusters, so it renames them to a unique ``aap-demo`` context —
via a dozen individual ``kubectl config ...`` subcommands run against a
scratch ``KUBECONFIG``, including two uses of process substitution to decode
embedded cert/key data (aap-demo.sh:1606-1683). This port does the equivalent
rewrite as a single in-memory dict edit (PyYAML is already a base dependency
for the config layer) instead: same outcome — one cluster/context/user named
``aap-demo``, TLS verification disabled the same way bash's
``--insecure-skip-tls-verify=true`` did — with no dependency on shell process
substitution and far fewer subprocess calls. ``kubectl config view`` is still
invoked once, against the raw extracted file, to validate it parses as a real
kubeconfig before rewriting it, mirroring bash's own validation step.
"""

from __future__ import annotations

import copy
import os
import tempfile
from pathlib import Path
from typing import Any, Dict

import yaml

from aap_demo.core.errors import AapDemoError
from aap_demo.exec import ssh as ssh_mod

CONTEXT_NAME = "aap-demo"
REMOTE_KUBECONFIG_PATH = "/var/lib/microshift/resources/kubeadmin/kubeconfig"


def extract_raw(runner: Any, key: Path) -> str:
    """Ports ``_infra_crc_get_kubeconfig`` (includes/infra-crc.sh:111).

    Bash falls back to copying a previously-saved aap-demo kubeconfig, then
    to CRC's own machine kubeconfig, if the SSH ``cat`` fails. Those
    fallbacks exist for when SSH itself is unavailable but an earlier
    extraction already succeeded; ``sync()``'s caller already requires the
    cluster to be running, so that fallback chain is not reproduced here.
    """
    result = ssh_mod.exec_remote(runner, key, "cat", REMOTE_KUBECONFIG_PATH, sudo=True)
    if not result.ok or not result.stdout.strip():
        raise AapDemoError(
            "Failed to extract kubeconfig",
            hint="OpenShift Local may still be initializing. Wait and retry.",
        )
    return result.stdout


def _rename(raw: Dict[str, Any]) -> Dict[str, Any]:
    data = copy.deepcopy(raw)
    clusters = data.get("clusters") or []
    contexts = data.get("contexts") or []
    users = data.get("users") or []

    if clusters:
        # Bash builds a *fresh* cluster entry — ``kubectl config set-cluster
        # aap-demo --server=... --insecure-skip-tls-verify=true`` against a
        # name that does not exist yet — then unsets the original
        # (aap-demo.sh:1653-1657). The result therefore carries the server and
        # the insecure flag and nothing else: no certificate-authority-data,
        # no file-form ``certificate-authority`` (which kubectl rejects
        # outright next to insecure-skip-tls-verify), no proxy-url, no
        # tls-server-name. Whitelist by construction, not blacklist by
        # deletion, so nothing bash dropped can survive here either.
        cluster_entry = clusters[0]
        server = (cluster_entry.get("cluster") or {}).get("server")
        cluster_entry["name"] = CONTEXT_NAME
        cluster_entry["cluster"] = {"server": server, "insecure-skip-tls-verify": True}
    if users:
        users[0]["name"] = CONTEXT_NAME
    if contexts:
        context_entry = contexts[0]
        context_entry["name"] = CONTEXT_NAME
        context_body = context_entry.setdefault("context", {})
        context_body["cluster"] = CONTEXT_NAME
        context_body["user"] = CONTEXT_NAME

    data["clusters"] = clusters
    data["contexts"] = contexts
    data["users"] = users
    data["current-context"] = CONTEXT_NAME
    return data


def _validate(runner: Any, raw_text: str) -> None:
    """Mirrors bash's ``KUBECONFIG=$tmp kubectl config view`` validation step."""
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as tmp:
        tmp.write(raw_text)
        tmp_path = tmp.name
    try:
        result = runner.run(["kubectl", "config", "view"], env={"KUBECONFIG": tmp_path})
    finally:
        Path(tmp_path).unlink(missing_ok=True)
    if not result.ok:
        raise AapDemoError(
            "Extracted kubeconfig is invalid",
            hint="OpenShift Local may still be initializing. Wait and retry.",
        )


def write_private(destination: Path, text: str) -> Path:
    """Write ``text`` to ``destination`` so it is never world-readable.

    Ports bash's ``mktemp`` + ``chmod 600`` + ``mv`` (aap-demo.sh:1631-1673):
    the file is created 0600 *before* any content is written and then renamed
    into place, so cluster-admin credentials never exist at the process umask,
    not even for the instant between ``write_text`` and ``chmod``.
    """
    destination.parent.mkdir(parents=True, exist_ok=True)
    # mkstemp creates the file 0600 (O_EXCL, mode 0600) — there is no moment
    # at which it exists at the process umask.
    fd, tmp_name = tempfile.mkstemp(dir=str(destination.parent), prefix=".kubeconfig.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp_name, 0o600)  # explicit, and a no-op on POSIX
        os.replace(tmp_name, destination)
    except BaseException:
        Path(tmp_name).unlink(missing_ok=True)
        raise
    return destination


def sync(runner: Any, *, key: Path, destination: Path, validate: bool = True) -> Path:
    """Ports ``cmd_kubeconfig`` (aap-demo.sh:1606-1683). Returns ``destination``."""
    raw_text = extract_raw(runner, key)

    if validate:
        _validate(runner, raw_text)

    try:
        parsed = yaml.safe_load(raw_text)
    except yaml.YAMLError as exc:
        raise AapDemoError("Extracted kubeconfig is invalid", hint=str(exc)) from exc
    if not isinstance(parsed, dict):
        raise AapDemoError("Extracted kubeconfig is invalid")

    renamed = _rename(parsed)

    return write_private(destination, yaml.safe_dump(renamed, sort_keys=False))


def default_kubeconfig_file(home: Path) -> Path:
    """The file ``oc`` and ``kubectl`` read when ``KUBECONFIG`` is unset."""
    return home / ".kube" / "config"


def activate_context(source: Path, target: Path) -> Path:
    """Install the ``aap-demo`` context into ``target`` and make it current.

    Other clusters, users, and contexts in ``target`` stay. A previous
    ``aap-demo`` entry is replaced, because the client certificate changes
    every time the cluster is recreated.
    """
    fresh = yaml.safe_load(source.read_text(encoding="utf-8"))
    if not isinstance(fresh, dict):
        raise AapDemoError("Extracted kubeconfig is invalid")

    existing: Dict[str, Any] = {}
    if target.is_file():
        try:
            loaded = yaml.safe_load(target.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError as exc:
            raise AapDemoError(
                f"Cannot read {target}",
                hint="Fix that kubeconfig, or move it aside and run aap-demo kubeconfig again.",
            ) from exc
        if isinstance(loaded, dict):
            existing = loaded

    for key in ("clusters", "contexts", "users"):
        current = existing.get(key) or []
        if not isinstance(current, list):
            current = []
        kept = [
            entry
            for entry in current
            if isinstance(entry, dict) and entry.get("name") != CONTEXT_NAME
        ]
        incoming = [entry for entry in (fresh.get(key) or []) if isinstance(entry, dict)]
        existing[key] = kept + incoming

    existing["apiVersion"] = existing.get("apiVersion") or "v1"
    existing["kind"] = existing.get("kind") or "Config"
    existing["current-context"] = CONTEXT_NAME
    return write_private(target, yaml.safe_dump(existing, sort_keys=False))
