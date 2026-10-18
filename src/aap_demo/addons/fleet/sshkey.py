"""Generate the fleet SSH key once and keep it in a cluster Secret.

The macOS keychain refuses writes from a pipx Python (``-25308``).
The key lives in the AAP namespace instead, and the playbook Job is
the only reader of the private half.
"""

from __future__ import annotations

import base64
import json
import shutil
import tempfile
from pathlib import Path

import yaml

from aap_demo.addons.fleet.gateway import aap_namespace
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError, AddonError, PrerequisiteError
from aap_demo.exec import kubectl

SECRET = "aap-demo-fleet-ssh"


def load_or_create(ctx: AppContext) -> tuple:
    existing = _read(ctx)
    if existing:
        return existing
    binary = shutil.which("ssh-keygen")
    if not binary:
        raise PrerequisiteError(
            "ssh-keygen is not on PATH",
            hint="Install OpenSSH, then run aap-demo enable fleet again.",
        )
    directory = Path(tempfile.mkdtemp(prefix="aap-demo-fleet-"))
    key = directory / "id_ed25519"
    try:
        result = ctx.runner.run([binary, "-t", "ed25519", "-N", "", "-f", str(key)])
        if not result.ok:
            raise AapDemoError("ssh-keygen failed", hint=(result.stderr or "").strip() or None)
        private = key.read_text(encoding="utf-8")
        public = Path(str(key) + ".pub").read_text(encoding="utf-8")
    finally:
        shutil.rmtree(directory, ignore_errors=True)
    _store(ctx, private, public)
    return private, public


def _read(ctx: AppContext) -> tuple:
    namespace = aap_namespace(ctx)
    result = ctx.runner.run(
        ["kubectl", "get", "secret", SECRET, "-n", namespace, "-o", "json"],
    )
    if not result.ok:
        detail = result.stderr or result.stdout or ""
        if "notfound" in detail.lower() or "not found" in detail.lower():
            return ()
        raise AddonError(
            "could not read the fleet SSH key",
            hint=detail.strip() or None,
        )
    if not (result.stdout or "").strip():
        raise AddonError("could not read the fleet SSH key")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise AddonError("could not read the fleet SSH key", hint=str(exc)) from exc
    data = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(data, dict):
        raise AddonError("could not read the fleet SSH key")
    private = _b64(data.get("ssh-privatekey"))
    public = _b64(data.get("ssh-publickey"))
    if not private or not public:
        raise AddonError("fleet SSH key secret is incomplete")
    return private, public


def _store(ctx: AppContext, private: str, public: str) -> None:
    namespace = aap_namespace(ctx)
    body = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": SECRET, "namespace": namespace},
        "stringData": {"ssh-privatekey": private, "ssh-publickey": public},
    }
    applied = kubectl.apply_stdin(ctx.runner, yaml.safe_dump(body, sort_keys=False))
    if not applied.ok:
        raise AapDemoError(
            "could not store the fleet SSH key",
            hint=(applied.stderr or applied.stdout or "").strip() or None,
        )


def _b64(value: object) -> str:
    if not isinstance(value, str) or not value:
        return ""
    try:
        return base64.b64decode(value).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return ""
