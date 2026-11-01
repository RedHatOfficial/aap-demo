"""Pull-secret discovery and the namespace secret.

Ports the second half of ``setup_namespace``. Pods pull images with CRI-O's
global auth file, so the AAP resource and its service accounts need no secret.

The secret's *content* is never read, logged, or emitted as an event: bash
hands the file to ``kubectl create secret --from-file``, and so does this, so
the credential never enters the Python process.
"""

from __future__ import annotations

from pathlib import Path
from typing import List, Optional

from aap_demo.core.context import AppContext
from aap_demo.core.paths import Paths, display_path
from aap_demo.exec import kubectl

SECRET_NAME = "redhat-operators-pull-secret"

#: Drop names under the XDG state directory. The Red Hat console downloads
#: ``pull-secret.txt``; ``pull-secret.json`` is the reserved state file.
DEFAULT_FILENAMES = ("pull-secret.txt", "pull-secret.json")


def _home(ctx: AppContext) -> Path:
    return Path(ctx.env.get("HOME") or Path.home())


def locate(configured: str, paths: Paths) -> Optional[Path]:
    """The pull-secret file to use, or None when nothing is available.

    An explicit path (config, ``--pull-secret``, or ``AAP_DEMO_PULL_SECRET``)
    wins and is not replaced by a default when that file is missing. An empty
    setting uses the first file that exists under the state directory:
    ``pull-secret.txt``, then ``pull-secret.json``. ``~/.aap-demo`` is not
    searched.
    """
    raw = configured.strip()
    if raw:
        path = Path(raw).expanduser()
        return path if path.is_file() else None
    for name in DEFAULT_FILENAMES:
        candidate = paths.state_dir / name
        if candidate.is_file():
            return candidate
    return None


def discover(ctx: AppContext) -> Optional[Path]:
    """The pull-secret file for this run, or None when it is unset or missing."""
    raw = str(ctx.config.get("deploy.pull_secret_path", "") or "")
    return locate(raw, ctx.paths)


def configured_path(ctx: AppContext) -> Optional[Path]:
    """The path from config, expanded, even when the file is not there yet."""
    raw = str(ctx.config.get("deploy.pull_secret_path", "") or "").strip()
    if not raw:
        return None
    return Path(raw).expanduser()


def unset_hint(ctx: AppContext) -> str:
    """Where to drop the file, and the command for a path kept somewhere else."""
    home = _home(ctx)
    drop = display_path(ctx.paths.state_dir / DEFAULT_FILENAMES[0], home)
    return (
        f"Save it as {drop} and it is used automatically.\n"
        "pull-secret.json in that directory is also accepted.\n"
        "Or run: aap-demo config set pull-secret ~/path/to/pull-secret.txt"
    )


def welcome_note(paths: Paths, configured: str, home: Path) -> str:
    """Extra welcome lines when no pull secret can be found yet."""
    if locate(configured, paths) is not None:
        return ""
    drop = display_path(paths.state_dir / DEFAULT_FILENAMES[0], home)
    return (
        "\n"
        "Pull secret (download from "
        "https://console.redhat.com/openshift/install/pull-secret):\n"
        f"    Save it as {drop} and it is used automatically.\n"
        "    pull-secret.json in that directory is also accepted.\n"
        "    Or: aap-demo config set pull-secret ~/path/to/pull-secret.txt"
    )


def _existing_image_pull_secrets(ctx: AppContext, namespace: str) -> List[str]:
    raw = kubectl.jsonpath(
        ctx.runner,
        "serviceaccount",
        "default",
        "-n",
        namespace,
        path="{.imagePullSecrets[*].name}",
    )
    return [name for name in raw.split() if name]


def attach_to_default_sa(ctx: AppContext, namespace: str) -> None:
    """Merge, never replace — pods on the default SA (postgres, redis) need it.

    Bash builds the merged array with the new secret *first* and the existing
    entries after it; order is preserved here because
    the kubelet tries pull secrets in list order.
    """
    ctx.console.progress("Adding the pull secret to the default ServiceAccount")
    existing = _existing_image_pull_secrets(ctx, namespace)
    if SECRET_NAME in existing:
        ctx.console.progress("Pull secret already attached to the default ServiceAccount")
        return
    merged = [{"name": SECRET_NAME}] + [{"name": name} for name in existing]
    import json

    ctx.runner.run(
        [
            "kubectl",
            "patch",
            "serviceaccount",
            "default",
            "-n",
            namespace,
            "-p",
            json.dumps({"imagePullSecrets": merged}),
        ]
    )
    ctx.console.progress("Pull secret added to the default ServiceAccount")


def ensure(ctx: AppContext, namespace: str) -> Optional[Path]:
    """Create ``redhat-operators-pull-secret`` and wire it to the default SA."""
    path = discover(ctx)
    if path is None:
        missing = configured_path(ctx)
        if missing is None:
            ctx.console.out("WARNING: Pull secret is not set")
        else:
            ctx.console.out(
                f"WARNING: Pull secret file not found: {display_path(missing, _home(ctx))}"
            )
        for line in unset_hint(ctx).splitlines():
            ctx.console.out(f"  {line}")
        return None

    ctx.console.progress(f"Using pull secret: {display_path(path, _home(ctx))}")
    # Delete-then-create, as bash does: `kubectl create secret` has no --force
    # and a stale secret from a previous pull-secret file must not survive.
    kubectl.delete(ctx.runner, "secret", SECRET_NAME, "-n", namespace)
    ctx.runner.run(
        [
            "kubectl",
            "create",
            "secret",
            "generic",
            SECRET_NAME,
            f"--from-file=.dockerconfigjson={path}",
            "--type=kubernetes.io/dockerconfigjson",
            "-n",
            namespace,
        ]
    )
    attach_to_default_sa(ctx, namespace)
    return path


__all__ = [
    "SECRET_NAME",
    "attach_to_default_sa",
    "discover",
    "ensure",
]
