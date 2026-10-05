"""MicroShift ``create`` and ``destroy`` (design §12.4 phase 4).

Ports ``includes/crc-create.sh`` for the MicroShift preset and ``cmd_destroy``.
The OpenShift preset is phase 4b and is refused here. Step order matches bash,
including the CoreDNS configuration at the end and the post-create stability
wait from upstream #199.
"""

from __future__ import annotations

import json
import os
import platform
import shutil
import time
from pathlib import Path
from typing import Any, Callable, Optional, Tuple

from aap_demo import data as packaged
from aap_demo.cluster import coredns, pull_secret
from aap_demo.cluster import kubeconfig as kubeconfig_mod
from aap_demo.core import prompts
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError, PrerequisiteError
from aap_demo.core.paths import display_path
from aap_demo.exec import kubectl
from aap_demo.exec import ssh as ssh_mod
from aap_demo.infra import crc as infra_crc

CRIO_PULL_SECRET = "/etc/crio/openshift-pull-secret"
SSH_ATTEMPTS = 60
SSH_PAUSE_SECONDS = 3.0
API_ATTEMPTS = 60
API_PAUSE_SECONDS = 5.0
DESTROY_CONFIRM_SECONDS = 10
METRICS_SERVER_URL = (
    "https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
)
NIPIO_DOMAIN = "127.0.0.1.nip.io"

HostResources = Tuple[int, int]


def _which(name: str) -> Optional[str]:
    return shutil.which(name)


def _host_resources(runner: Any) -> HostResources:
    system = platform.system()
    if system == "Darwin":
        cpus = runner.run(["sysctl", "-n", "hw.ncpu"])
        mem = runner.run(["sysctl", "-n", "hw.memsize"])
        try:
            cpu_count = int((cpus.stdout or "0").strip() or "0")
            memory_mb = int((mem.stdout or "0").strip() or "0") // 1024 // 1024
        except ValueError:
            return 0, 0
        return cpu_count, memory_mb
    if system == "Linux":
        cpus = runner.run(["nproc"])
        try:
            cpu_count = int((cpus.stdout or "0").strip() or "0")
        except ValueError:
            cpu_count = 0
        memory_mb = 0
        meminfo = Path("/proc/meminfo")
        if meminfo.is_file():
            for line in meminfo.read_text(encoding="utf-8").splitlines():
                if line.startswith("MemTotal:"):
                    memory_mb = int(line.split()[1]) // 1024
                    break
        return cpu_count, memory_mb
    return 0, 0


def _positive(name: str, value: int) -> None:
    if value <= 0:
        raise AapDemoError(f"Invalid {name}: '{value}' (must be a positive integer)")


def _resources(ctx: AppContext) -> Tuple[int, int, int, int]:
    cpus = int(ctx.config.get("crc.cpus"))
    memory_mb = int(ctx.config.get("crc.memory_mb"))
    disk_gb = int(ctx.config.get("crc.disk_gb"))
    pv_gb = int(ctx.config.get("crc.pv_size_gb"))
    for name, value in (
        ("crc.cpus", cpus),
        ("crc.memory_mb", memory_mb),
        ("crc.disk_gb", disk_gb),
        ("crc.pv_size_gb", pv_gb),
    ):
        _positive(name, value)
    if pv_gb >= disk_gb:
        raise AapDemoError(
            f"crc.pv_size_gb ({pv_gb}GB) must be less than crc.disk_gb ({disk_gb}GB)"
        )
    return cpus, memory_mb, disk_gb, pv_gb


def _persistent_store_ok(ctx: AppContext) -> bool:
    """Opt-in host disk. Disabled is success. macOS cannot attach one."""
    if ctx.env.get("AAP_PERSISTENT_IMAGE_STORE", "false") != "true":
        return True
    system = ctx.env.get("AAP_PERSISTENT_IMAGE_STORE_OS") or platform.system()
    if system == "Darwin":
        ctx.console.err(
            "Persistent CRI-O storage is unavailable on macOS/vfkit; using the OCI image cache"
        )
        return True
    ctx.console.warn("Continuing with the OCI image-cache fallback")
    return True


def _start_crc(ctx: AppContext, secret: Path) -> None:
    ctx.console.step("Starting CRC")
    started = ctx.runner.run(["crc", "start", "-p", str(secret)], sink=ctx.console.log_sink())
    if started.ok:
        ctx.console.checkpoint("CRC is running")
        return
    ctx.console.warn("CRC post-start did not finish; retrying")
    retried = ctx.runner.run(
        ["crc", "start", "--pull-secret-file", str(secret)], sink=ctx.console.log_sink()
    )
    if not retried.ok:
        raise AapDemoError("crc start failed", hint="See the crc output above.")
    ctx.console.checkpoint("CRC is running")


def _wait_ssh(ctx: AppContext, key: Path, *, sleep: Callable[[float], None]) -> None:
    ctx.console.step("Waiting for CRC SSH")
    for _attempt in range(SSH_ATTEMPTS):
        result = ssh_mod.exec_remote(ctx.runner, key, "true", sudo=False, connect_timeout=2)
        if result.ok:
            ctx.console.checkpoint("CRC SSH is ready")
            return
        sleep(SSH_PAUSE_SECONDS)
    raise AapDemoError(
        "CRC SSH not available after 3 minutes",
        hint="Check CRC status: crc status",
    )


def _crio_pull_secret_configured(ctx: AppContext, key: Path) -> bool:
    """True when CRI-O's global auth file exists and has registry credentials.

    The probe prints ``configured`` or nothing. It does not print the file.
    """
    script = (
        f"f={CRIO_PULL_SECRET}; "
        '[ -s "$f" ] || exit 1; '
        "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); "
        'a=d.get("auths"); sys.exit(0 if isinstance(a, dict) and a else 1)\' "$f" '
        "&& echo configured"
    )
    result = ssh_mod.exec_remote(ctx.runner, key, "bash", "-c", script, sudo=True)
    return bool(result.ok and "configured" in result.stdout)


def _assert_crio_pull_secret(ctx: AppContext, key: Path, secret: Path) -> None:
    """Require CRI-O's global pull secret before create continues.

    CRC post-start is supposed to write ``/etc/crio/openshift-pull-secret``
    from ``crc start --pull-secret-file``. When that step fails, MicroShift
    still boots and image pulls have no registry credentials. Install the
    file from the same pull secret, then fail create if it is still absent
    or has no ``auths`` entries.
    """
    ctx.console.step("Checking the CRI-O pull secret")
    if _crio_pull_secret_configured(ctx, key):
        ctx.console.checkpoint("CRI-O pull secret is configured")
        return
    try:
        payload = secret.read_text(encoding="utf-8")
        parsed = json.loads(payload)
    except (OSError, json.JSONDecodeError) as exc:
        raise AapDemoError(
            "Pull secret is not a registry auth file",
            hint=pull_secret.unset_hint(ctx),
        ) from exc
    auths = parsed.get("auths") if isinstance(parsed, dict) else None
    if not isinstance(auths, dict) or not auths:
        raise AapDemoError(
            "Pull secret is not a registry auth file",
            hint=pull_secret.unset_hint(ctx),
        )
    ctx.console.progress("Installing the pull secret into CRI-O")
    # CRI-O is not running yet at this point in create, so reload must not
    # decide success. The file is what MicroShift reads when it starts.
    install = f"tee {CRIO_PULL_SECRET} >/dev/null && chmod 600 {CRIO_PULL_SECRET}"
    wrote = ctx.runner.run(
        ssh_mod.remote_argv(key, "bash", "-c", install, sudo=True),
        input=payload,
    )
    ctx.runner.run(
        ssh_mod.remote_argv(
            key,
            "bash",
            "-c",
            "systemctl is-active --quiet crio && systemctl reload crio || true",
            sudo=True,
        )
    )
    if not wrote.ok or not _crio_pull_secret_configured(ctx, key):
        raise AapDemoError(
            "CRI-O global pull secret is not configured",
            hint=f"Expected {CRIO_PULL_SECRET} to contain registry credentials.",
        )
    ctx.console.checkpoint("CRI-O pull secret is configured")


def _grow_root(ctx: AppContext, key: Path) -> None:
    """Give the CRC root filesystem room for the AAP images.

    The MicroShift disk image leaves the root logical volume near 20G and
    the rest of the volume group free. A full AAP pull, including the
    execution-environment image, does not fit. Extending the root volume
    to 40G uses that free space and does not touch the data volume.
    """
    script = (
        "size=$(sudo lvs --noheadings -o lv_size --units g --nosuffix rhel/root "
        "2>/dev/null | awk '{print int($1)}'); "
        "free=$(sudo vgs --noheadings -o vg_free --units g --nosuffix rhel "
        "2>/dev/null | awk '{print int($1)}'); "
        'if [ -z "$size" ] || [ "$size" -ge 40 ]; then echo unchanged; exit 0; fi; '
        'if [ -z "$free" ] || [ "$free" -lt 20 ]; then echo unchanged; exit 0; fi; '
        "sudo lvextend -L 40G /dev/rhel/root && sudo xfs_growfs /sysroot && echo grown"
    )
    result = ssh_mod.exec_remote(ctx.runner, key, "bash", "-c", script, sudo=False)
    if result.ok and "grown" in result.stdout:
        ctx.console.checkpoint("CRC root filesystem extended to 40G")


def _configure_nipio(ctx: AppContext, key: Path, *, sleep: Callable[[float], None]) -> None:
    ctx.console.step("Configuring the nip.io base domain")
    script = (
        "mkdir -p /etc/microshift/config.d && "
        "tee /etc/microshift/config.d/99-aap-demo-dns.yaml >/dev/null <<'EOF'\n"
        "dns:\n"
        f"  baseDomain: {NIPIO_DOMAIN}\n"
        "EOF"
    )
    wrote = ssh_mod.exec_remote(ctx.runner, key, "bash", "-c", script, sudo=True)
    if not wrote.ok:
        raise AapDemoError(
            "Failed to write nip.io config via SSH",
            hint="Try manually: aap-demo ssh",
        )
    ctx.console.progress("Restarting MicroShift with the nip.io domain")
    ssh_mod.exec_remote(
        ctx.runner,
        key,
        "bash",
        "-c",
        "systemctl stop microshift; rm -rf /var/lib/microshift; systemctl start microshift",
        sudo=True,
    )
    ctx.console.step("Waiting for the MicroShift API")
    remote = "kubectl --kubeconfig /var/lib/microshift/resources/kubeadmin/kubeconfig cluster-info"
    for _attempt in range(API_ATTEMPTS):
        result = ssh_mod.exec_remote(ctx.runner, key, "bash", "-c", remote, sudo=True)
        if result.ok:
            ctx.console.checkpoint("MicroShift API is ready")
            return
        sleep(API_PAUSE_SECONDS)
    ctx.console.warn("MicroShift API not ready after 5 minutes — continuing anyway")


def _install_metrics(ctx: AppContext) -> None:
    ctx.console.step("Installing metrics-server")
    if ctx.runner.run(["kubectl", "get", "deployment", "metrics-server", "-n", "kube-system"]).ok:
        ctx.console.checkpoint("metrics-server already installed")
        return
    ctx.runner.run(["kubectl", "apply", "-f", METRICS_SERVER_URL])
    ctx.runner.run(
        [
            "kubectl",
            "patch",
            "deployment",
            "metrics-server",
            "-n",
            "kube-system",
            "--type=json",
            "-p",
            '[{"op":"add","path":"/spec/template/spec/containers/0/args/-",'
            '"value":"--kubelet-insecure-tls"}]',
        ]
    )
    ctx.console.checkpoint("metrics-server installed")


def _install_nfs(ctx: AppContext) -> None:
    ctx.console.step("Setting up NFS storage")
    if ctx.runner.run(["kubectl", "get", "sc", "nfs-local-rwx"]).ok:
        ctx.console.checkpoint("nfs-local-rwx StorageClass already exists")
        return
    ctx.console.progress("Granting the privileged SCC")
    ctx.runner.run(
        [
            "oc",
            "adm",
            "policy",
            "add-scc-to-group",
            "privileged",
            "system:serviceaccounts:nfs-storage",
        ]
    )
    listed = ctx.runner.run(
        [
            "kubectl",
            "get",
            "sc",
            "-o",
            'jsonpath={.items[?(@.metadata.annotations.storageclass\\.kubernetes\\.io/is-default-class=="true")].metadata.name}',
        ]
    )
    storage_class = (listed.stdout or "").split()[0] if (listed.stdout or "").strip() else ""
    if not storage_class:
        storage_class = "topolvm-provisioner"
    server = packaged.read(packaged.MANIFESTS, "nfs-server.yaml").replace(
        "__DEFAULT_SC__", storage_class
    )
    ctx.console.progress("Applying the NFS server")
    kubectl.apply_stdin(ctx.runner, server)
    ctx.console.progress("Waiting for the NFS server")
    # Detach so kubectl's watch cannot draw on the terminal and leave a
    # second copy of the live checklist line behind.
    ctx.runner.run(
        [
            "kubectl",
            "wait",
            "--for=condition=Available",
            "deployment/nfs-server",
            "-n",
            "nfs-storage",
            "--timeout=120s",
        ],
        detach=True,
    )
    nfs_ip = kubectl.jsonpath(
        ctx.runner,
        "svc",
        "nfs-server",
        "-n",
        "nfs-storage",
        path="{.spec.clusterIP}",
    )
    if not nfs_ip:
        raise AapDemoError("NFS server did not get a ClusterIP")
    provisioner = packaged.read(packaged.MANIFESTS, "nfs-provisioner.yaml").replace(
        "__NFS_SERVER_IP__", nfs_ip
    )
    ctx.console.progress("Applying the NFS provisioner")
    kubectl.apply_stdin(ctx.runner, provisioner)
    ctx.console.progress("Waiting for the NFS provisioner")
    ctx.runner.run(
        [
            "kubectl",
            "wait",
            "--for=condition=Available",
            "deployment/nfs-provisioner",
            "-n",
            "nfs-storage",
            "--timeout=120s",
        ],
        detach=True,
    )
    ctx.console.checkpoint("nfs-local-rwx StorageClass created")


def _ensure_stable(ctx: AppContext, secret: Path, *, sleep: Callable[[float], None]) -> None:
    attempts = int(ctx.env.get("AAP_DEMO_CRC_STABILITY_ATTEMPTS", infra_crc.STABILITY_ATTEMPTS))
    pause = float(ctx.env.get("AAP_DEMO_CRC_STABILITY_SLEEP", infra_crc.STABILITY_SLEEP_SECONDS))
    if infra_crc.wait_until_stable(ctx.runner, attempts=attempts, sleep_seconds=pause, sleep=sleep):
        return
    ctx.console.warn("CRC did not remain healthy after setup; restarting CRC once...")
    restarted = ctx.runner.run(["crc", "start", "-p", str(secret)], sink=ctx.console.log_sink())
    if restarted.ok and infra_crc.wait_until_stable(
        ctx.runner, attempts=attempts, sleep_seconds=pause, sleep=sleep
    ):
        return
    raise AapDemoError(
        "CRC did not remain running after create",
        hint="Check: crc status",
    )


def create(
    ctx: AppContext,
    *,
    sleep: Callable[[float], None] = time.sleep,
    host: Optional[HostResources] = None,
    which: Callable[[str], Optional[str]] = _which,
) -> None:
    """Create a MicroShift CRC cluster. Raises where bash called ``exit 1``."""
    preset = str(ctx.config.get("crc.preset", "microshift") or "microshift")
    if preset != "microshift":
        raise AapDemoError(
            "The OpenShift preset is not available in this release",
            hint="Use the MicroShift preset. Full OpenShift support is a later phase.",
        )

    home = Path(ctx.env.get("HOME") or Path.home())
    if platform.system() == "Linux" and not (home / ".crc" / "crc-http.sock").is_socket():
        ctx.console.warn("CRC daemon socket is missing. Start it with: crc daemon")

    if which("crc") is None:
        state = infra_crc.STATE_NOT_CREATED
    else:
        state = infra_crc.get_state(ctx.runner)
        if state == infra_crc.STATE_RUNNING:
            raise AapDemoError(
                "CRC is already running",
                hint=(
                    "Use 'aap-demo destroy' to remove it first, or 'aap-demo deploy' to deploy AAP"
                ),
            )

    bundled, upgraded = infra_crc.ensure_managed_crc(ctx, which=which)
    if upgraded and state != infra_crc.STATE_NOT_CREATED:
        ctx.console.out(
            "Deleting the existing cluster; its bundle cannot move to the new CRC release."
        )
        deleted = ctx.runner.run(["crc", "delete", "-f"])
        if not deleted.ok:
            raise AapDemoError(
                "CRC delete failed while upgrading CRC",
                hint="Run 'aap-demo destroy --yes' and then 'aap-demo create'.",
            )
        state = infra_crc.STATE_NOT_CREATED
    steps = [
        "MicroShift",
        "Checking host resources",
        "Preflight",
        "Checking the pull secret",
        "Starting CRC",
        "Waiting for CRC SSH",
        "Checking the CRI-O pull secret",
        "Configuring the nip.io base domain",
        "Waiting for the MicroShift API",
        "Configuring kubeconfig",
    ]
    if which("podman"):
        steps.append("Registering the podman remote connection")
    steps.extend(
        [
            "Installing metrics-server",
            "Setting up NFS storage",
            "Configuring CoreDNS",
            "Setting inotify limits",
            "Trusting the ingress certificate",
        ]
    )
    ctx.console.tasks(steps, title="Creating aap-demo crc cluster")
    ctx.console.step("MicroShift")
    ctx.console.checkpoint(f"MicroShift: {bundled}")
    ctx.console.step("Checking host resources")
    cpus, memory_mb = host if host is not None else _host_resources(ctx.runner)
    if cpus > 0 and memory_mb > 0:
        if cpus < 4 or memory_mb < 10240:
            ctx.console.warn("MicroShift requires at least 4 CPUs and 10GB RAM.")
            ctx.console.note(f"Your host has {cpus} CPUs and {memory_mb // 1024}GB RAM.")
        ctx.console.checkpoint(f"Host has {cpus} CPUs and {memory_mb // 1024}GB RAM")
    else:
        ctx.console.checkpoint("Host resources could not be read")

    ctx.console.step("Preflight")

    ctx.runner.run(["crc", "config", "set", "preset", "microshift"])
    ctx.console.progress("CRC preset: microshift")

    vm_cpus, vm_memory, disk_gb, pv_gb = _resources(ctx)
    if state == infra_crc.STATE_NOT_CREATED:
        ctx.console.progress("Running CRC setup...")
        ctx.runner.run(["crc", "setup"], sink=ctx.console.log_sink())

    for key, value in (
        ("cpus", str(vm_cpus)),
        ("memory", str(vm_memory)),
        ("disk-size", str(disk_gb)),
        ("persistent-volume-size", str(pv_gb)),
    ):
        ctx.runner.run(["crc", "config", "set", key, value])
    ctx.console.progress(
        f"Resources: {vm_cpus} CPUs, {vm_memory // 1024}GB RAM, "
        f"{disk_gb}GB disk ({pv_gb}GB for PVs)"
    )
    # CRC post-start writes api.crc.testing into /etc/hosts with its admin
    # helper. That helper exits 1 on macOS when it cannot authorize, and CRC
    # then stops with "Error running post start: exit status 1". Routes here
    # use nip.io, so those hosts entries are unused.
    ctx.runner.run(["crc", "config", "set", "modify-hosts-file", "false"])
    ctx.console.checkpoint("Completed Preflight")

    ctx.console.step("Checking the pull secret")
    secret = pull_secret.discover(ctx)
    if secret is None:
        configured = pull_secret.configured_path(ctx)
        if configured is None:
            raise AapDemoError(
                "Pull secret is not set",
                hint=pull_secret.unset_hint(ctx),
            )
        raise AapDemoError(
            f"Pull secret file not found: {display_path(configured, home)}",
            hint=pull_secret.unset_hint(ctx),
        )
    ctx.console.checkpoint(f"Pull secret: {display_path(secret, home)}")

    _start_crc(ctx, secret)
    if not _persistent_store_ok(ctx):
        raise AapDemoError("Persistent CRI-O storage setup failed")

    resolver = Path("/etc/resolver/testing")
    if resolver.is_file() and os.access("/etc/resolver", os.W_OK):
        resolver.unlink()
        ctx.console.note("Removed broken /etc/resolver/testing")

    key = ssh_mod.detect_ssh_key(ssh_mod.crc_machines_dir(ctx.env))
    if key is None:
        raise AapDemoError("No CRC SSH key found. Cannot configure nip.io baseDomain.")

    _wait_ssh(ctx, key, sleep=sleep)
    _assert_crio_pull_secret(ctx, key, secret)
    _grow_root(ctx, key)
    _configure_nipio(ctx, key, sleep=sleep)

    ctx.console.step("Configuring kubeconfig")
    ctx.runner.run(["crc", "oc-env"])
    destination = kubeconfig_mod.sync(ctx.runner, key=key, destination=ctx.kubeconfig)
    kubeconfig_mod.activate_context(destination, kubeconfig_mod.default_kubeconfig_file(home))
    ctx.console.checkpoint(f"Kubeconfig saved to {display_path(destination, home)}")

    podman = which("podman")
    if podman:
        ctx.console.step("Registering the podman remote connection")
        ctx.runner.run(
            [
                "podman",
                "system",
                "connection",
                "add",
                "aap-demo",
                "--identity",
                str(key),
                "ssh://core@127.0.0.1:2222/run/podman/podman.sock",
            ]
        )
        ctx.console.progress("podman --connection aap-demo build .")
        ctx.console.checkpoint("Podman remote connection registered")

    _install_metrics(ctx)
    _install_nfs(ctx)
    coredns.configure(ctx, sleep=sleep)

    ctx.console.step("Setting inotify limits")
    ssh_mod.exec_remote(
        ctx.runner,
        key,
        "sysctl",
        "-w",
        "fs.inotify.max_user_watches=2099999999",
        "fs.inotify.max_user_instances=2099999999",
        "fs.inotify.max_queued_events=2099999999",
        sudo=True,
    )
    ctx.console.checkpoint("inotify limits configured")

    _ensure_stable(ctx, secret, sleep=sleep)
    from aap_demo.cluster import ingress_ca

    ctx.console.step("Trusting the ingress certificate")
    trusted = ingress_ca.install(ctx)
    active = ctx.console._active
    on_trust_step = (
        active is not None
        and ctx.console._tasks[active].title == "Trusting the ingress certificate"
    )
    if on_trust_step:
        if trusted:
            ctx.console.checkpoint("Ingress certificate is trusted locally")
        else:
            ctx.console.cancel_step()
    ctx.console.finish_checklist()
    ctx.console.next_steps(
        (
            ("aap-demo deploy", "Deploy AAP 2.7"),
            ("aap-demo status", "Show cluster and AAP status"),
            ("aap-demo oc cluster-info", "Run oc against this cluster"),
            ("aap-demo ssh", "Open a shell on the cluster node"),
        )
    )


def destroy(
    ctx: AppContext,
    *,
    reset: bool = False,
    sleep: Callable[[float], None] = time.sleep,
    which: Callable[[str], Optional[str]] = _which,
) -> None:
    """Delete the CRC VM. ``--reset`` removes the aap-demo config file too."""
    if which("crc") is None:
        raise PrerequisiteError(
            "CRC (OpenShift Local) is required but not found",
            hint="Download from: https://console.redhat.com/openshift/create/local",
        )
    home = Path(ctx.env.get("HOME") or Path.home())
    if not infra_crc.has_instance(ctx.runner, home=home):
        raise AapDemoError(
            "No CRC cluster to delete",
            hint="Run 'aap-demo create' to create one.",
        )
    ctx.console.out("")
    ctx.console.out("WARNING: This will DELETE the entire CRC cluster!")
    ctx.console.out("")
    ctx.console.out("  • All cluster data will be PERMANENTLY DESTROYED")
    ctx.console.out("  • All PVC storage will be LOST")
    ctx.console.out("  • All deployed applications will be removed")
    ctx.console.out("  • You will need to redeploy AAP from scratch")
    ctx.console.out("")
    if not ctx.quiet and not ctx.assume_yes:
        prompts.timed_continue(ctx.console, seconds=DESTROY_CONFIRM_SECONDS, wait=sleep)

    podman = which("podman")
    steps = ["Deleting the CRC cluster"]
    if podman:
        steps.append("Removing the podman connection")
    ctx.console.tasks(steps)
    ctx.console.step("Deleting the CRC cluster")

    if not _persistent_store_ok(ctx):
        raise AapDemoError(
            "Persistent CRI-O image storage could not be detached — refusing to delete the cluster"
        )

    ctx.console.progress("Deleting the CRC VM")

    def _delete_vm():
        # detach keeps crc off this terminal. Its delete UI opens /dev/tty and
        # erases the live line; a new session cannot open /dev/tty.
        deleted_vm = ctx.runner.run(["crc", "delete", "-f"], detach=True)
        if not deleted_vm.ok:
            deleted_vm = ctx.runner.run(["crc", "delete"], detach=True)
        return deleted_vm

    # Paint from this thread. crc holds the wait long enough that the
    # checklist's own refresh thread stops, which is why clean spins and
    # destroy did not.
    deleted = ctx.console.paint_while(_delete_vm)
    if not deleted.ok:
        raise AapDemoError("CRC delete failed — config preserved")
    ctx.console.checkpoint("CRC cluster deleted")

    if podman:
        ctx.console.step("Removing the podman connection")
        ctx.runner.run(["podman", "system", "connection", "remove", "aap-demo"])
        ctx.console.checkpoint("Podman connection removed")
    if reset:
        config_path = ctx.paths.config_file
        if config_path.is_file():
            config_path.unlink()
        ctx.console.success("Config reset — next 'aap-demo create' will start fresh")
