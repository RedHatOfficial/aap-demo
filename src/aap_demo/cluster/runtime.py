"""Day-2 cluster operations that are not deploy or create (design §12.4 phase 2).

``start`` and ``stop`` move the CRC VM. ``idle`` scales the AAP CR.
``repair`` re-grants SCCs, fixes CoreDNS, and restarts stuck pods.
``must-gather`` writes a local diagnostic bundle and then runs
``oc adm must-gather``. ``watch`` waits for the AAP Successful condition.
"""

from __future__ import annotations

import shutil
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

from aap_demo.cluster import aap as aap_mod
from aap_demo.cluster import coredns, preflight
from aap_demo.cluster import scc as scc_mod
from aap_demo.core.context import AppContext
from aap_demo.exec import kubectl

MUST_GATHER_IMAGE = "registry.redhat.io/ansible-automation-platform-26/aap-must-gather-rhel9:latest"
PROBLEM_POD_TOKENS = ("CrashLoopBackOff", "Error", "ImagePullBackOff")


def start(ctx: AppContext, *, sleep: Callable[[float], None] = time.sleep) -> None:
    """Ports ``cmd_start``: ``crc start``, then re-apply CoreDNS."""
    ctx.console.out("")
    ctx.console.step("aap-demo start - Starting CRC cluster...")
    ctx.runner.run(["crc", "start"], sink=ctx.console.log_sink())
    preflight.setup_kubeconfig(ctx)
    coredns.configure(ctx, sleep=sleep)
    ctx.console.success("CRC cluster started")
    ctx.console.out("")
    ctx.console.out("Run 'aap-demo status' to check cluster health")


def stop(ctx: AppContext) -> None:
    """Ports ``cmd_stop``. A failed ``crc stop`` still reports the attempt, as bash does."""
    ctx.console.out("")
    ctx.console.step("aap-demo stop - Stopping CRC cluster...")
    ctx.runner.run(["crc", "stop"], sink=ctx.console.log_sink())
    ctx.console.success("CRC cluster stopped")
    ctx.console.out("To restart: aap-demo start")


def idle(ctx: AppContext, state: Optional[str]) -> int:
    """Ports ``cmd_idle``. No argument prints the current idle state."""
    ns = ctx.namespace
    name = kubectl.jsonpath(ctx.runner, "aap", "-n", ns, path="{.items[0].metadata.name}")
    if not name:
        ctx.console.failure(f"No AAP instance found in namespace {ns}")
        return 1
    current = kubectl.jsonpath(ctx.runner, "aap", name, "-n", ns, path="{.spec.idle_aap}")
    if not state:
        if current == "true":
            ctx.console.out(f"AAP '{name}' is idle (scaled down)")
            ctx.console.out("  Resume with: aap-demo idle false")
        else:
            ctx.console.out(f"AAP '{name}' is running")
            ctx.console.out("  Scale down with: aap-demo idle true")
        return 0
    if state == "true":
        if current == "true":
            ctx.console.out(f"AAP '{name}' is already idle")
            return 0
        ctx.console.out("")
        ctx.console.step("aap-demo idle true - Scaling down AAP deployment...")
        _patch_idle(ctx, name, ns, True)
        ctx.console.out("")
        ctx.console.success(f"AAP '{name}' set to idle")
        ctx.console.out("  The operator will scale down all components (this may take a minute)")
        ctx.console.out("  Resume with: aap-demo idle false")
        return 0
    if current != "true":
        ctx.console.out(f"AAP '{name}' is already running")
        return 0
    ctx.console.out("")
    ctx.console.step("aap-demo idle false - Scaling up AAP deployment...")
    _patch_idle(ctx, name, ns, False)
    ctx.console.out("")
    ctx.console.success(f"AAP '{name}' waking up")
    ctx.console.out("  The operator will scale up all components (this may take a few minutes)")
    ctx.console.out("  Monitor with: aap-demo watch")
    return 0


def _patch_idle(ctx: AppContext, name: str, namespace: str, idle_aap: bool) -> None:
    payload = "true" if idle_aap else "false"
    ctx.runner.run(
        [
            "kubectl",
            "patch",
            "aap",
            name,
            "-n",
            namespace,
            "--type",
            "merge",
            "-p",
            f'{{"spec":{{"idle_aap":{payload}}}}}',
        ]
    )


def repair(
    ctx: AppContext,
    *,
    sleep: Callable[[float], None] = time.sleep,
    which: Callable[[str], Optional[str]] = shutil.which,
) -> None:
    """Ports ``cmd_repair``: SCCs, CoreDNS, and a restart of stuck pods.

    ``install_ingress_ca_trust`` is still the phase-4 ``trust/`` package and is
    not called here.
    """
    ctx.console.out("Running repair...")
    ctx.console.out("")
    scc_mod.grant_namespace_sccs(ctx, which=which)
    coredns.verify(ctx, sleep=sleep)
    listing = ctx.runner.run(["kubectl", "get", "pods", "-n", ctx.namespace, "--no-headers"])
    restarted = False
    for line in (listing.stdout or "").splitlines():
        if not any(token in line for token in PROBLEM_POD_TOKENS):
            continue
        pod = line.split()[0]
        if not restarted:
            ctx.console.out("  Restarting problem pods...")
            restarted = True
        ctx.runner.run(["kubectl", "delete", "pod", pod, "-n", ctx.namespace])
    ctx.console.out("")
    ctx.console.success("In-cluster repair complete")
    ctx.console.out("")
    ctx.console.out("If issues persist (ImagePullBackOff, NFS/storage, wedged VM):")
    ctx.console.out("  crc stop && crc start")


def watch(
    ctx: AppContext,
    *,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> int:
    """Ports ``watch_aap``'s completion wait and its success summary.

    The bash dashboard clears the terminal every interval. This prints progress
    through the event sink and the same success or timeout summary.
    """
    readiness = aap_mod.wait_ready(ctx, sleep=sleep, clock=clock)
    if not readiness.ready:
        ctx.console.warn("Deployment not complete after 60 minutes")
        ctx.console.out(f"Check: kubectl get aap -n {ctx.namespace} -o yaml")
        return 1
    ctx.console.success("AAP deployment successful!")
    ctx.console.out("")
    if readiness.csv:
        ctx.console.out(f"CSV: {readiness.csv}")
    ctx.console.out(f"Namespace: {ctx.namespace}")
    ctx.console.out("")
    ctx.console.out(f"AAP UI: https://{readiness.route or '(route not found)'}")
    ctx.console.out("")
    ctx.console.out("Username: admin")
    if readiness.password:
        ctx.console.out(f"Password: {readiness.password}")
    else:
        ctx.console.out(
            "Password: (run: kubectl get secret -n "
            f"{ctx.namespace} aap-admin-password -o jsonpath='{{.data.password}}' | base64 -d)"
        )
    return 0


def must_gather(ctx: AppContext, dest: Optional[str] = None) -> int:
    """Ports ``cmd_must_gather``. Local files are always collected.

    ``oc adm must-gather`` failing does not discard that bundle. Bash ends on
    the directory listing, so this returns 0 after a failed image gather too.
    """
    ctx.console.out("")
    ctx.console.step("aap-demo must-gather - Collecting diagnostic information...")
    ctx.console.out("")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    dest_dir = Path(dest) if dest else Path(f"must-gather.local.{stamp}")
    bundle = dest_dir / "aap-demo"
    bundle.mkdir(parents=True, exist_ok=True)
    ctx.console.out(f"Output directory: {dest_dir}")
    ctx.console.out("")
    ctx.console.out("Collecting aap-demo diagnostics...")

    config_path = ctx.paths.config_file
    if config_path.is_file():
        (bundle / "config").write_text(config_path.read_text(encoding="utf-8"), encoding="utf-8")
    _capture(ctx, bundle / "crc-status.txt", ["crc", "status"])
    _capture(ctx, bundle / "crc-version.txt", ["crc", "version"])
    ns = ctx.namespace
    _capture(ctx, bundle / "storageclasses.yaml", ["kubectl", "get", "sc", "-o", "yaml"])
    _capture(ctx, bundle / "pvcs.yaml", ["kubectl", "get", "pvc", "-n", ns, "-o", "yaml"])
    _capture(ctx, bundle / "pods.txt", ["kubectl", "get", "pods", "-n", ns, "-o", "wide"])
    _capture(
        ctx,
        bundle / "events.txt",
        ["kubectl", "get", "events", "-n", ns, "--sort-by=.lastTimestamp"],
    )
    _capture(ctx, bundle / "aap-cr.yaml", ["kubectl", "get", "aap", "-n", ns, "-o", "yaml"])
    _capture(
        ctx,
        bundle / "nfs-pods.txt",
        ["kubectl", "get", "pods", "-n", "nfs-storage", "-o", "wide"],
    )
    _capture(
        ctx,
        bundle / "coredns-config.yaml",
        ["kubectl", "get", "configmap", "-n", "openshift-dns", "dns-default", "-o", "yaml"],
    )
    ctx.console.out("  ✓ aap-demo diagnostics collected")
    ctx.console.out("")
    ctx.console.out("Running AAP must-gather...")
    ctx.console.out("  This will launch a pod to collect AAP-specific diagnostics.")
    ctx.console.out("  It may take several minutes to complete.")
    ctx.console.out("")
    gathered = ctx.runner.run(
        [
            "oc",
            "adm",
            "must-gather",
            f"--image={MUST_GATHER_IMAGE}",
            f"--dest-dir={dest_dir}",
        ]
    )
    for line in (gathered.stdout or "").splitlines():
        ctx.console.out(f"  {line}")
    ctx.console.out("")
    if gathered.ok:
        ctx.console.success(f"Must-gather complete: {dest_dir}")
    else:
        ctx.console.warn(f"AAP must-gather failed (exit code: {gathered.returncode})")
        ctx.console.out("  aap-demo diagnostics were still collected successfully.")
    ctx.console.out("")
    ctx.console.out("Contents:")
    for child in sorted(dest_dir.iterdir()):
        ctx.console.out(f"  {child.name}")
    ctx.console.out("")
    ctx.console.out(f"To share: tar czf must-gather.tar.gz {dest_dir}")
    return 0


def _capture(ctx: AppContext, path: Path, argv: list) -> None:
    result = ctx.runner.run(argv)
    text = result.stdout or ""
    if not result.ok and result.stderr:
        text = text + result.stderr
    path.write_text(text, encoding="utf-8")


def claude_available(which: Callable[[str], Optional[str]] = shutil.which) -> bool:
    return which("claude") is not None


def analyze(ctx: AppContext, *, which: Optional[Callable[[str], Optional[str]]] = None) -> int:
    """Ports the ``--ai`` tail of ``cmd_diagnose``.

    Diagnostic text is sent to the ``claude`` CLI on stdin. A missing CLI is
    an error. A failing CLI is a warning and does not discard the diagnose
    report already printed.
    """
    finder = which if which is not None else shutil.which
    if not claude_available(finder):
        ctx.console.failure("'claude' CLI not found")
        ctx.console.out("  Install: https://docs.anthropic.com/en/docs/claude-code")
        return 1
    ctx.console.out("")
    ctx.console.out("AI Analysis (powered by Claude)")
    ctx.console.out("")
    ctx.console.out("(Diagnostic data is sent to the Claude API for analysis)")
    ctx.console.out("")
    ns = ctx.namespace
    pods = ctx.runner.run(["kubectl", "get", "pods", "-n", ns, "-o", "wide", "--no-headers"])
    pod_output = pods.stdout.strip() if pods.ok and pods.stdout.strip() else "No pods"
    logs = []
    for line in pod_output.splitlines():
        if not any(token in line for token in (*PROBLEM_POD_TOKENS, "Pending")):
            continue
        pod = line.split()[0]
        logged = ctx.runner.run(["kubectl", "logs", pod, "-n", ns, "--tail=20"])
        logs.append(f"--- {pod} ---\n{logged.stdout or ''}")
    pvcs = ctx.runner.run(["kubectl", "get", "pvc", "-n", ns])
    classes = ctx.runner.run(["kubectl", "get", "sc"])
    events = ctx.runner.run(["kubectl", "get", "events", "-n", ns, "--sort-by=.lastTimestamp"])
    context = "\n".join(
        [
            "AAP Demo Diagnose Results:",
            f"Namespace: {ns}",
            "",
            "Cluster State:",
            pod_output,
            "",
            "PVC State:",
            pvcs.stdout.strip() or "No PVCs",
            "",
            "Storage Classes:",
            classes.stdout.strip() or "No storage classes",
            "",
            "Recent Events:",
            "\n".join((events.stdout or "").splitlines()[-20:]) or "No events",
            "",
            "Problem Pod Logs:",
            "\n".join(logs) or "None",
        ]
    )
    prompt = (
        "You are an AAP Demo troubleshooting assistant. Analyze the diagnostic "
        "output below and identify the root cause, then give specific fix commands. "
        "Be concise."
    )
    result = ctx.runner.run(["claude", "-p", prompt], input=context)
    if result.stdout:
        ctx.console.out(result.stdout.rstrip("\n"))
    if not result.ok:
        ctx.console.out("")
        ctx.console.warn(
            "AI analysis failed. The diagnostic data above should help with manual troubleshooting."
        )
    return 0
