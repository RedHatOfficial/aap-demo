"""Generate the fleet SSH key once and keep it in the keyring."""

from __future__ import annotations

import shutil
import tempfile
from pathlib import Path

from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError, PrerequisiteError

PRIVATE = "fleet-ssh-private"
PUBLIC = "fleet-ssh-public"


def load_or_create(ctx: AppContext) -> tuple:
    private = ctx.secrets.get(PRIVATE)
    public = ctx.secrets.get(PUBLIC)
    if private and public:
        return private, public
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
    ctx.secrets.set(PRIVATE, private)
    ctx.secrets.set(PUBLIC, public)
    return private, public
