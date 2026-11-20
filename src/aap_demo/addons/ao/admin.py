"""AO's initial admin password. Ports addons/ao/lib/admin-password.sh.

AO writes the admin record from the referenced Secret only when its database is
first created, so a retained database must get back the password it was
created with. The host copy is that record. It lives in the Python state
directory, and the first run copies it from the Bash command's
``~/.aap-demo/ao/initial-admin-password`` (ADR-045), which stays for
``aap-demo-v1``.
"""

from __future__ import annotations

import base64
import json
import os
import secrets
from pathlib import Path
from typing import Optional

from aap_demo.addons.ao import postgres
from aap_demo.addons.common.kube import output_of
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError
from aap_demo.exec import kubectl

SECRET = "automation-orchestrator-initial-admin-password"  # pragma: allowlist secret
FILENAME = "initial-admin-password"


def path(ctx: AppContext) -> Path:
    return ctx.paths.addon_dir("ao") / FILENAME


def legacy_path(ctx: AppContext) -> Path:
    return ctx.paths.legacy_dir / "ao" / FILENAME


def _write(target: Path, value: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(target), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(value)
    os.chmod(target, 0o600)


def saved(ctx: AppContext) -> Optional[str]:
    """The saved password, copying the Bash command's file in on first use."""
    for candidate in (path(ctx), legacy_path(ctx)):
        try:
            value = candidate.read_text(encoding="utf-8").strip()
        except FileNotFoundError:
            continue
        except OSError as exc:
            raise AddonError("could not read the saved AO admin password", hint=str(exc)) from exc
        if not value:
            continue
        if candidate != path(ctx):
            _write(path(ctx), value)
        return value
    return None


def retained_database(ctx: AppContext) -> bool:
    """PostgreSQL data that outlived AO: the StatefulSet PVC or a CNPG one."""
    ns = postgres.NAMESPACE
    return (
        kubectl.exists(ctx.runner, "pvc", postgres.PVC, "-n", ns)
        or kubectl.exists(ctx.runner, "pvc", postgres.CNPG_PVC, "-n", ns)
        or kubectl.exists(
            ctx.runner, "clusters.postgresql.cnpg.io", postgres.CNPG_CLUSTER, "-n", ns
        )
    )


def _cluster_value(ctx: AppContext) -> str:
    encoded = kubectl.jsonpath(
        ctx.runner, "secret", SECRET, "-n", postgres.NAMESPACE, path="{.data.password}"
    )
    if not encoded:
        return ""
    try:
        return base64.b64decode(encoded).decode("utf-8").strip()
    except (ValueError, UnicodeDecodeError):
        return ""


def _apply(ctx: AppContext, value: str) -> None:
    """Replace the Secret, so a partial reinstall's generated one cannot win.

    The value goes on stdin, never in argv where other processes can read it.
    """
    kubectl.run(
        ctx.runner, "delete", "secret", SECRET, "-n", postgres.NAMESPACE, "--ignore-not-found"
    )
    manifest = json.dumps(
        {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {"name": SECRET, "namespace": postgres.NAMESPACE},
            "type": "Opaque",
            "stringData": {"password": value},
        }
    )
    created = kubectl.apply_stdin(ctx.runner, manifest)
    if not created.ok:
        raise AddonError(
            "could not write the AO admin password Secret", hint=output_of(created) or None
        )


def generate(ctx: AppContext) -> None:
    """A fresh password for a fresh database."""
    value = secrets.token_hex(16)
    _write(path(ctx), value)
    _apply(ctx, value)
    ctx.console.success("Fresh AO admin password generated")


def save(ctx: AppContext) -> None:
    """Keep the cluster's password on the host before AO is removed."""
    value = _cluster_value(ctx)
    if not value:
        if retained_database(ctx):
            raise AddonError(
                "Refusing to remove AO: PostgreSQL exists but its admin password is unavailable."
            )
        return
    _write(path(ctx), value)
    ctx.console.success("AO admin password kept for the next enable")


def forget(ctx: AppContext) -> None:
    """Drop the host copy. The Bash command's file is left for aap-demo-v1."""
    try:
        path(ctx).unlink()
    except FileNotFoundError:
        pass


def ensure(ctx: AppContext) -> None:
    """Make the Secret match the database AO is about to use."""
    value = saved(ctx)
    if value:
        _apply(ctx, value)
        ctx.console.success("AO admin password restored")
        return
    if retained_database(ctx):
        # A Secret can outlive a namespace purge on some local clusters. Trust
        # it only when retained data exists too.
        if _cluster_value(ctx):
            save(ctx)
            return
        raise AddonError(
            "Retained AO PostgreSQL data has no recoverable admin password.",
            hint=f"Restore {path(ctx)}, or run aap-demo enable ao --force to reset AO's data.",
        )
    generate(ctx)
