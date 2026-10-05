"""Pull-secret discovery, secret creation, and ServiceAccount patching.

Ports the second half of ``setup_namespace`` (aap-demo.sh:2350-2379) and
``patch_operator_serviceaccounts`` (aap-demo.sh:2089-2103).

The secret's *content* is never read, logged, or emitted as an event: bash
hands the file to ``kubectl create secret --from-file``, and so does this, so
the credential never enters the Python process (§5.5, R30).
"""

from __future__ import annotations

import time
from pathlib import Path
from typing import Any, Callable, List, Optional

from aap_demo.core.context import AppContext
from aap_demo.core.paths import Paths, display_path
from aap_demo.exec import kubectl

SECRET_NAME = "redhat-operators-pull-secret"

#: Drop names under the XDG state directory. The Red Hat console downloads
#: ``pull-secret.txt``; ``pull-secret.json`` is the reserved state file.
DEFAULT_FILENAMES = ("pull-secret.txt", "pull-secret.json")


def _home(ctx: AppContext) -> Path:
    return Path(ctx.env.get("HOME") or Path.home())


#: Bash sleeps 5s before patching operator SAs because the operator's own
#: ServiceAccounts are created by the CSV install and do not exist the instant
#: the CSV reports Succeeded (aap-demo.sh:2092).
OPERATOR_SA_SETTLE_SECONDS = 5


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
    entries after it (aap-demo.sh:2369-2375); order is preserved here because
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


def patch_service_accounts(
    ctx: AppContext,
    namespace: str,
    *,
    sleep: Callable[[float], None] = time.sleep,
) -> None:
    """Ports ``patch_operator_serviceaccounts`` (aap-demo.sh:2089).

    Bash filters ``kubectl get serviceaccount -o name`` through
    ``grep -E 'operator|controller'``; the same substring match is applied
    here rather than a label selector, because the operator's SAs carry no
    label that is stable across AAP releases.
    """
    ctx.console.out("")
    ctx.console.out("Patching operator ServiceAccounts with pull secret...")
    sleep(OPERATOR_SA_SETTLE_SECONDS)
    listing: Any = ctx.runner.run(
        ["kubectl", "get", "serviceaccount", "-n", namespace, "-o", "name"]
    )
    for line in listing.stdout.splitlines():
        name = line.strip()
        if not name.startswith("serviceaccount/"):
            continue
        name = name[len("serviceaccount/") :]
        if "operator" not in name and "controller" not in name:
            continue
        ctx.runner.run(
            [
                "kubectl",
                "patch",
                "serviceaccount",
                name,
                "-n",
                namespace,
                "-p",
                '{"imagePullSecrets": [{"name": "redhat-operators-pull-secret"}]}',
            ]
        )
    ctx.console.out("  ✓ Operator ServiceAccounts patched")


def attach_to_all_service_accounts(ctx: AppContext, namespace: str) -> int:
    """Give every ServiceAccount in the namespace the pull secret.

    Workload accounts such as ``aap-gateway`` are created by the operator
    after deploy and do not match the operator/controller name filter. This
    MicroShift node has no cluster-wide registry credential, so a pod with
    no imagePullSecret is refused by registry.redhat.io.
    """
    import json

    listing = ctx.runner.run(
        [
            "kubectl",
            "get",
            "serviceaccount",
            "-n",
            namespace,
            "-o",
            (
                "jsonpath={range .items[*]}{.metadata.name}"
                '{"\\t"}{.imagePullSecrets[*].name}{"\\n"}{end}'
            ),
        ]
    )
    if not listing.ok:
        return 0
    patched = 0
    for line in listing.stdout.splitlines():
        if not line.strip():
            continue
        name, _, pulls = line.partition("\t")
        existing = pulls.split()
        if SECRET_NAME in existing:
            continue
        merged = [{"name": SECRET_NAME}] + [{"name": item} for item in existing]
        ctx.runner.run(
            [
                "kubectl",
                "patch",
                "serviceaccount",
                name,
                "-n",
                namespace,
                "-p",
                json.dumps({"imagePullSecrets": merged}),
            ]
        )
        patched += 1
    return patched


_PULL_FAIL_REASONS = frozenset({"ErrImagePull", "ImagePullBackOff"})


def _container_waiting_reason(status: dict) -> str:
    waiting = (status.get("state") or {}).get("waiting") or {}
    return str(waiting.get("reason") or "")


def pull_failed_pod_names(document: dict) -> List[str]:
    """Pod names whose init or app containers are stuck pulling an image."""
    names: List[str] = []
    for pod in document.get("items") or []:
        if not isinstance(pod, dict):
            continue
        status = pod.get("status") or {}
        containers = list(status.get("initContainerStatuses") or [])
        containers.extend(status.get("containerStatuses") or [])
        if any(_container_waiting_reason(item) in _PULL_FAIL_REASONS for item in containers):
            name = str((pod.get("metadata") or {}).get("name") or "")
            if name:
                names.append(name)
    return names


def _restart_pull_failures(ctx: AppContext, namespace: str) -> int:
    import json

    listing = ctx.runner.run(["kubectl", "get", "pods", "-n", namespace, "-o", "json"])
    if not listing.ok or not listing.stdout.strip():
        return 0
    try:
        document = json.loads(listing.stdout)
    except json.JSONDecodeError:
        return 0
    names = pull_failed_pod_names(document if isinstance(document, dict) else {})
    if not names:
        return 0
    ctx.runner.run(["kubectl", "delete", "pod", "-n", namespace, "--wait=false", *names])
    return len(names)


def _cr_has_pull_secret(ctx: AppContext, namespace: str, aap_name: str) -> bool:
    current = kubectl.jsonpath(
        ctx.runner,
        "aap",
        aap_name,
        "-n",
        namespace,
        path="{.spec.image_pull_secrets}",
    )
    return SECRET_NAME in current


def reconcile(ctx: AppContext, namespace: str, aap_name: str) -> None:
    """Keep the pull secret on accounts the operator creates after deploy.

    ``image_pull_secrets`` on the AAP custom resource does not reach a
    ServiceAccount that the operator creates later. Those pods are refused
    by registry.redhat.io on a MicroShift node that has no node-wide
    credential. Restarting only the pods already stuck in a pull error lets
    the new ServiceAccount secret take effect without touching healthy pods.
    """
    import json

    if discover(ctx) is None:
        return
    if not _cr_has_pull_secret(ctx, namespace, aap_name):
        ctx.runner.run(
            [
                "kubectl",
                "patch",
                "aap",
                aap_name,
                "-n",
                namespace,
                "--type",
                "merge",
                "-p",
                json.dumps({"spec": {"image_pull_secrets": [SECRET_NAME]}}),
            ]
        )
    patched = attach_to_all_service_accounts(ctx, namespace)
    restarted = _restart_pull_failures(ctx, namespace)
    if not patched and not restarted:
        return
    accounts = f"{patched} service account" if patched == 1 else f"{patched} service accounts"
    pods = f"{restarted} pod" if restarted == 1 else f"{restarted} pods"
    if patched and restarted:
        message = (
            f"Attached the pull secret to {accounts}; restarting {pods} that could not pull images"
        )
    elif patched:
        message = f"Attached the pull secret to {accounts}"
    else:
        message = f"Restarting {pods} that could not pull images"
    ctx.console.progress(message)


def attach_to_workload(ctx: AppContext, namespace: str, aap_name: str) -> None:
    """Tell the AAP operator to put the pull secret on every pod it creates."""
    reconcile(ctx, namespace, aap_name)


__all__ = [
    "SECRET_NAME",
    "attach_to_all_service_accounts",
    "attach_to_default_sa",
    "attach_to_workload",
    "reconcile",
    "discover",
    "ensure",
    "patch_service_accounts",
]
