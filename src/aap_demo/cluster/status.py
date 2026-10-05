"""``aap-demo status`` data gathering (design §2.2: ``cmd_status`` →
``cli/observe.py::status`` + per-addon ``status()`` hooks).

The addon registry (§4) doesn't exist yet — it lands in phase 5+6 — so the
"Addons:" section here reads ``addons.enabled`` from config directly (the
same list ``_addons_list`` read from the legacy ``ADDONS=`` config line) and
falls back to bash's own ``ao``-namespace heuristic for the one addon whose
enabled state is also independently observable on the cluster.

TLS status comes from ``cluster/ingress_ca.py``. On macOS that is
``security verify-cert`` against the saved ingress CA. The missing-file
wording stays the historical two lines.
"""

from __future__ import annotations

import base64
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

from aap_demo.core import version as version_mod
from aap_demo.core.context import AppContext
from aap_demo.core.paths import display_path
from aap_demo.exec import ssh as ssh_mod
from aap_demo.infra import crc as infra_crc

#: Ports ``AVAILABLE_ADDONS`` (aap-demo.sh:2617). ``ao-eap`` is folded into
#: ``ao`` in the rewrite (design §4.5) and product-demo domain addons other
#: than ``product-demo-satellite`` are hidden from status, same as bash.
AVAILABLE_ADDONS = (
    "mcp-server",
    "portal",
    "setup-pah",
    "ao",
    "apme-eap",
    "local-cache",
    "product-demos",
    "product-demo-satellite",
)

#: Ports the secret-name fallback chain in ``cmd_status`` (aap-demo.sh:1832).
ADMIN_SECRET_FALLBACKS = (
    "myaap-admin-password",
    "aap-admin-password",
    "aap-controller-admin-password",
    "custom-admin-password",
)

#: The remote diagnostic one-liner bash runs over SSH (aap-demo.sh:1751-1769),
#: unchanged so the printed VM block matches bash byte-for-byte. Built as a
#: joined list, rather than one triple-quoted block, only so the long
#: MicroShift-version line can wrap under the line-length limit.
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

VM_STATS_SCRIPT = "\n".join(
    [
        'RHEL=$(cat /etc/redhat-release 2>/dev/null || echo "unknown")',
        'USHIFT=$(microshift version 2>/dev/null | awk "/MicroShift Version:/{print \\$3}" '
        '|| rpm -q microshift --qf "%{VERSION}" 2>/dev/null || echo "unknown")',
        "CPUS=$(nproc)",
        'MEM_TOTAL=$(free -h | awk "/Mem:/{print \\$2}")',
        'MEM_USED=$(free -h | awk "/Mem:/{print \\$3}")',
        'MEM_AVAIL=$(free -h | awk "/Mem:/{print \\$7}")',
        'LOAD=$(cat /proc/loadavg | awk "{print \\$1, \\$2, \\$3}")',
        'DISK=$(df -h /var 2>/dev/null | awk "NR==2{print \\$3\\"/\\"\\$2\\" (\\" \\$5 \\" used)\\"}")',  # noqa: E501
        'echo "  OS:           $RHEL"',
        'echo "  OpenShift:    $USHIFT"',
        'echo "  CPUs:         $CPUS"',
        'echo "  Memory:       ${MEM_USED} / ${MEM_TOTAL} (${MEM_AVAIL} available)"',
        'echo "  Load:         $LOAD"',
        'echo "  Disk:         $DISK"',
    ]
)


@dataclass
class NamespaceInfo:
    name: str
    pods_running: int
    pods_total: int
    aap_name: Optional[str] = None
    aap_status: Optional[str] = None  # "healthy" | "deploying" | "reconciling" | None

    def as_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "pods_running": self.pods_running,
            "pods_total": self.pods_total,
            "aap_name": self.aap_name,
            "aap_status": self.aap_status,
        }


@dataclass
class CredentialInfo:
    namespace: str
    username: str
    password: str

    def as_dict(self) -> Dict[str, Any]:
        return {"namespace": self.namespace, "username": self.username, "password": self.password}


@dataclass
class AddonStatus:
    name: str
    enabled: bool

    def as_dict(self) -> Dict[str, Any]:
        return {"name": self.name, "enabled": self.enabled}


@dataclass
class StatusReport:
    tool_version: str
    built: str
    infra: str = "OpenShift Local (CRC)"
    cluster_state: str = "not_created"
    cluster_name: Optional[str] = None
    cluster_version: Optional[str] = None
    aap_version: Optional[str] = None
    aap_csv: Optional[str] = None
    kubeconfig: Optional[str] = None
    source: Optional[str] = None
    branch: Optional[str] = None
    remote: Optional[str] = None
    tls: Dict[str, Any] = field(default_factory=dict)
    vm_info: Optional[str] = None
    namespaces: List[NamespaceInfo] = field(default_factory=list)
    routes: List[str] = field(default_factory=list)
    credentials: List[CredentialInfo] = field(default_factory=list)
    addons: List[AddonStatus] = field(default_factory=list)

    def as_dict(self) -> Dict[str, Any]:
        return {
            "tool_version": self.tool_version,
            "built": self.built,
            "infra": self.infra,
            "cluster_state": self.cluster_state,
            "cluster_name": self.cluster_name,
            "cluster_version": self.cluster_version,
            "aap_version": self.aap_version,
            "aap_csv": self.aap_csv,
            "kubeconfig": self.kubeconfig,
            "source": self.source,
            "branch": self.branch,
            "remote": self.remote,
            "tls": self.tls,
            "vm_info": self.vm_info,
            "namespaces": [n.as_dict() for n in self.namespaces],
            "routes": list(self.routes),
            "credentials": [c.as_dict() for c in self.credentials],
            "addons": [a.as_dict() for a in self.addons],
        }


def _list_namespaces(runner: Any) -> List[str]:
    result = runner.run(
        ["kubectl", "get", "ns", "--no-headers", "-o", "custom-columns=:metadata.name"]
    )
    if not result.ok:
        return []
    names = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    filtered = [
        n
        for n in names
        if not (n.startswith("openshift") or n.startswith("kube-") or n == "default")
    ]
    return sorted(filtered)


def _pod_counts(runner: Any, namespace: str) -> "tuple[int, int]":
    result = runner.run(["kubectl", "get", "pods", "-n", namespace, "--no-headers"])
    lines = [line for line in result.stdout.splitlines() if line.strip()] if result.ok else []
    total = sum(1 for line in lines if "Completed" not in line)
    running = sum(1 for line in lines if "Running" in line)
    return total, running


def _aap_csv(runner: Any, namespace: str) -> Optional[str]:
    result = runner.run(
        ["kubectl", "get", "csv", "-n", namespace, "-o", "jsonpath={.items[0].metadata.name}"]
    )
    name = result.stdout.strip() if result.ok else ""
    return name or None


def _aap_version(runner: Any, namespace: str, csv: Optional[str]) -> Optional[str]:
    reported = runner.run(
        ["kubectl", "get", "aap", "-n", namespace, "-o", "jsonpath={.items[0].status.version}"]
    )
    if reported.ok and reported.stdout.strip():
        return reported.stdout.strip()
    if not csv:
        return None
    spec = runner.run(
        ["kubectl", "get", "csv", csv, "-n", namespace, "-o", "jsonpath={.spec.version}"]
    )
    spec_version = spec.stdout.strip() if spec.ok else ""
    if spec_version and all(part.isdigit() for part in spec_version.split(".")):
        return spec_version
    marker = ".v"
    if marker not in csv:
        return None
    return csv.split(marker, 1)[1].split("-", 1)[0] or None


def _aap_cr_name(runner: Any, namespace: str) -> Optional[str]:
    result = runner.run(["kubectl", "get", "aap", "-n", namespace, "--no-headers"])
    if not result.ok:
        return None
    for line in result.stdout.splitlines():
        parts = line.split()
        if parts:
            return parts[0]
    return None


def _aap_cr_status(runner: Any, namespace: str, name: str) -> str:
    successful = runner.run(
        [
            "kubectl",
            "get",
            "aap",
            name,
            "-n",
            namespace,
            "-o",
            'jsonpath={.status.conditions[?(@.type=="Successful")].status}',
        ]
    )
    if successful.ok and successful.stdout.strip() == "True":
        return "healthy"
    running = runner.run(
        [
            "kubectl",
            "get",
            "aap",
            name,
            "-n",
            namespace,
            "-o",
            'jsonpath={.status.conditions[?(@.type=="Running")].status}',
        ]
    )
    if running.ok and running.stdout.strip() == "True":
        return "deploying"
    return "reconciling"


def _routes(runner: Any) -> List[str]:
    result = runner.run(["kubectl", "get", "route", "-A", "--no-headers"])
    if not result.ok:
        return []
    hosts = set()
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        namespace = parts[0]
        if (
            namespace.startswith("openshift-")
            or namespace.startswith("kube-")
            or namespace.startswith("aap-demo-")
        ):
            continue
        hosts.add(parts[2])
    return sorted(f"https://{host}" for host in hosts)


def _decode_password(raw: str) -> Optional[str]:
    raw = raw.strip()
    if not raw:
        return None
    try:
        return base64.b64decode(raw).decode()
    except (ValueError, UnicodeDecodeError):
        return None


def _admin_password(runner: Any, namespace: str) -> Optional[str]:
    secret_name_result = runner.run(
        [
            "kubectl",
            "get",
            "aap",
            "-n",
            namespace,
            "-o",
            "jsonpath={.items[0].status.adminPasswordSecret}",
        ]
    )
    candidates: List[str] = []
    if secret_name_result.ok and secret_name_result.stdout.strip():
        candidates.append(secret_name_result.stdout.strip())
    candidates.extend(ADMIN_SECRET_FALLBACKS)

    for secret_name in candidates:
        result = runner.run(
            [
                "kubectl",
                "get",
                "secret",
                "-n",
                namespace,
                secret_name,
                "-o",
                "jsonpath={.data.password}",
            ]
        )
        if result.ok and result.stdout.strip():
            password = _decode_password(result.stdout)
            if password:
                return password
    return None


def _credential_namespaces(runner: Any) -> List[str]:
    result = runner.run(["kubectl", "get", "aap", "-A", "--no-headers"])
    if not result.ok:
        return []
    names = {line.split()[0] for line in result.stdout.splitlines() if line.split()}
    return sorted(names)


def _ao_credentials(runner: Any, addons_enabled: List[str]) -> Optional[CredentialInfo]:
    ao_namespace = "automation-orchestrator"
    if "ao" not in addons_enabled:
        namespace_check = runner.run(["kubectl", "get", "namespace", ao_namespace])
        if not namespace_check.ok:
            return None

    secrets = runner.run(["kubectl", "get", "secret", "-n", ao_namespace, "-o", "name"])
    if not secrets.ok:
        return None
    secret_ref = next(
        (line.strip() for line in secrets.stdout.splitlines() if "admin-password" in line.lower()),
        None,
    )
    if not secret_ref:
        return None

    password_result = runner.run(
        ["kubectl", "get", secret_ref, "-n", ao_namespace, "-o", "jsonpath={.data.password}"]
    )
    if not password_result.ok:
        return None
    password = _decode_password(password_result.stdout)
    if not password:
        return None
    return CredentialInfo(namespace=ao_namespace, username="admin", password=password)


def _addon_statuses(runner: Any, addons_enabled: List[str]) -> List[AddonStatus]:
    statuses = []
    for name in AVAILABLE_ADDONS:
        enabled = name in addons_enabled
        if not enabled and name == "ao":
            result = runner.run(["kubectl", "get", "namespace", "automation-orchestrator"])
            enabled = result.ok
        statuses.append(AddonStatus(name=name, enabled=enabled))
    return statuses


def gather(ctx: AppContext) -> StatusReport:
    """Ports ``cmd_status`` (aap-demo.sh:1685-1884)."""
    runner = ctx.runner
    info = version_mod.version_info(runner)
    report = StatusReport(
        tool_version=f"{info.version} ({info.git_sha})",
        built=info.git_date,
    )

    report.cluster_state = infra_crc.get_state(runner)
    if report.cluster_state != infra_crc.STATE_RUNNING:
        return report

    preset = ctx.config.get("crc.preset", "microshift")
    report.cluster_name = infra_crc.get_name(preset)
    version = str(infra_crc.status_json(runner).get("openshiftVersion") or "").strip()
    report.cluster_version = version or None
    report.aap_csv = _aap_csv(runner, ctx.namespace)
    report.aap_version = _aap_version(runner, ctx.namespace, report.aap_csv)
    home = Path(ctx.env.get("HOME") or Path.home())
    report.kubeconfig = display_path(ctx.kubeconfig, home)
    report.source = info.source
    report.branch = info.git_branch
    remote = version_mod.remote_url(runner)
    report.remote = remote if remote != version_mod.UNKNOWN else None

    from aap_demo.cluster import ingress_ca

    report.tls = ingress_ca.describe(ctx)

    key = ssh_mod.detect_ssh_key(ssh_mod.crc_machines_dir(ctx.env))
    if key is not None:
        vm_result = ssh_mod.exec_remote(runner, key, "bash", "-c", VM_STATS_SCRIPT)
        if vm_result.ok:
            report.vm_info = vm_result.stdout.rstrip("\n")

    for namespace in _list_namespaces(runner):
        total, running = _pod_counts(runner, namespace)
        if total == 0:
            continue
        aap_name = _aap_cr_name(runner, namespace)
        aap_status = _aap_cr_status(runner, namespace, aap_name) if aap_name else None
        report.namespaces.append(
            NamespaceInfo(
                name=namespace,
                pods_running=running,
                pods_total=total,
                aap_name=aap_name,
                aap_status=aap_status,
            )
        )

    report.routes = _routes(runner)

    addons_enabled = list(ctx.config.get("addons.enabled", []) or [])

    for namespace in _credential_namespaces(runner):
        password = _admin_password(runner, namespace)
        if password:
            report.credentials.append(
                CredentialInfo(namespace=namespace, username="admin", password=password)
            )

    ao_credential = _ao_credentials(runner, addons_enabled)
    if ao_credential:
        report.credentials.append(ao_credential)

    report.addons = _addon_statuses(runner, addons_enabled)

    return report


def render_text(console: Any, report: StatusReport) -> None:
    """Ports the printing half of ``cmd_status`` (aap-demo.sh:1685-1884)."""
    console.out("")
    console.step("AAP Demo Status")
    console.out("===============")
    console.out(f"Tool:        {report.tool_version}")
    console.out(f"Built:       {report.built}")
    console.out("")
    console.out(f"Infra:       {report.infra}")

    # Bash prints "Cluster:     " followed by a *colored word* and no glyph
    # (aap-demo.sh:1701-1714); a ✓/⚠/✗ prefix here would be output the bash
    # tool never had, and all three states go to stdout.
    if report.cluster_state == infra_crc.STATE_RUNNING:
        name_suffix = f" ({report.cluster_name})" if report.cluster_name else ""
        console.out(f"Cluster:     {console.paint('running', 'green')}{name_suffix}")
        if report.cluster_version:
            # CRC reports one openshiftVersion for both presets. The header
            # names the product the cluster is actually running.
            label = "OpenShift:" if report.cluster_name == "crc-openshift" else "MicroShift:"
            console.out(f"{label:<13}{report.cluster_version}")
        if report.aap_version:
            console.out(f"{'AAP:':<13}{report.aap_version}")
        if report.aap_csv:
            console.out(f"{'CSV:':<13}{report.aap_csv}")
    elif report.cluster_state == infra_crc.STATE_STOPPED:
        console.out(f"Cluster:     {console.paint('stopped', 'yellow')}")
        console.out("")
        console.out("Start with: crc start")
        return
    else:
        console.out(f"Cluster:     {console.paint('not running', 'red')}")
        console.out("")
        console.out("Start with: aap-demo create")
        return

    console.out("")
    console.out("TLS:")
    console.out("----")
    # Bash's ``ingress_ca_trust_status`` pads with %-18s and, in the not-saved
    # case, always prints a second "Browser trust:" line as well
    # (includes/ingress-ca-trust.sh:384-387).
    console.out(f"  {'Ingress CA file:':<18} {report.tls.get('ingress_ca_file', 'not saved')}")
    system_trust = report.tls.get("system_trust")
    if system_trust:
        console.out(f"  {'System trust:':<18} {system_trust}")
    browser_trust = report.tls.get("browser_trust")
    if browser_trust:
        console.out(f"  {'Browser trust:':<18} {browser_trust}")

    console.out("")
    console.out(f"Kubeconfig:  {report.kubeconfig}")
    # Bash prints Source: unconditionally (aap-demo.sh:1731), even when the
    # repo root or branch is unknown.
    branch_suffix = f" (branch: {report.branch})" if report.branch else ""
    console.out(f"Source:      {report.source or ''}{branch_suffix}")
    if report.remote:
        console.out(f"Repo:        {report.remote}")

    console.out("")
    console.out("VM:")
    console.out("---")
    console.out(report.vm_info or "  (unavailable — no CRC SSH key found)")

    console.out("")
    console.out("Namespaces:")
    console.out("-----------")
    if not report.namespaces:
        console.out("  (no application namespaces found)")
    else:
        for ns in report.namespaces:
            # Bash colors *only* the CR name and keeps %-30s alignment for
            # every row (aap-demo.sh:1782-1795) — no glyph, no line-wide color,
            # so an AAP row lines up with a plain one.
            line = f"  {ns.name:<30} {ns.pods_running}/{ns.pods_total} pods"
            if ns.aap_name:
                if ns.aap_status == "healthy":
                    console.out(f"{line}   {console.paint(ns.aap_name, 'green')}")
                elif ns.aap_status == "deploying":
                    console.out(f"{line}   {console.paint(f'{ns.aap_name} (Deploying)', 'yellow')}")
                else:
                    console.out(f"{line}   {ns.aap_name}")
            else:
                console.out(line)

    console.out("")
    console.out("AAP Deployments:")
    console.out("----------------")
    if report.routes:
        for route in report.routes:
            console.out(f"  {route}")
    else:
        console.out("  (no routes found)")

    if report.credentials:
        console.out("")
        console.out("Credentials:")
        console.out("------------")
        for cred in report.credentials:
            console.out(f"  {cred.namespace + ':':<20} {cred.username} / {cred.password}")

    console.out("")
    console.out("Addons:")
    console.out("-------")
    for addon in report.addons:
        console.out(f"  {addon.name:<15} {'enabled' if addon.enabled else 'disabled'}")
    console.out("")


def show_cluster_info(ctx: AppContext, *, total_pods: bool = False) -> None:
    """Ports ``_show_cluster_info`` (aap-demo.sh:550).

    Lives here rather than in ``core/console.py`` (which §2.2's mapping table
    names) because every line of it is a cluster query, and ``console.py`` is
    forbidden from doing anything but write. The console still owns the
    writing; this owns the gathering and the layout.
    """
    ns = ctx.namespace
    context = ctx.runner.run(["kubectl", "config", "current-context"])
    cluster = context.stdout.strip() if context.ok and context.stdout.strip() else "unknown"

    info = ctx.runner.run(["kubectl", "cluster-info", "--request-timeout=2s"])
    api = "unknown"
    if info.ok and info.stdout.strip():
        first = _ANSI_RE.sub("", info.stdout.splitlines()[0])
        _, sep, tail = first.partition("is running at ")
        api = tail.strip() if sep else first.strip()

    aap_count = _count_rows(ctx.runner, ["kubectl", "get", "aap", "-n", ns])
    ctx.console.out("  Infra:            crc")
    ctx.console.out(f"  Cluster Context:  {cluster}")
    ctx.console.out(f"  API Server:       {api}")
    ctx.console.out(f"  Namespace:        {ns}")
    ctx.console.out(f"  AAP Instances:    {aap_count}")
    if total_pods:
        pods = _count_rows(ctx.runner, ["kubectl", "get", "pods", "-A"])
        ctx.console.out(f"  Total Pods:       {pods}")


def _count_rows(runner: Any, argv: List[str]) -> int:
    result = runner.run([*argv, "--no-headers", "--request-timeout=2s"])
    if not result.ok:
        return 0
    return len([line for line in result.stdout.splitlines() if line.strip()])
