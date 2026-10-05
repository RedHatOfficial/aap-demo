"""``aap-demo diagnose`` checks (design §2.2: ``cmd_diagnose`` (+``_check_*``) →
``diagnostics/checks.py`` + ``report.py`` + ``ai.py``).

``--ai`` (``ai.py``, shelling out to the ``claude`` CLI) is explicitly out of
scope for phase 1 — it is stubbed at the CLI layer (``cli/observe.py``) rather
than here.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Dict, List

from aap_demo.infra import crc as infra_crc

Level = str  # "pass" | "fail" | "warn" | "info"

_PROBLEM_STATES = ("CrashLoopBackOff", "Error", "ImagePullBackOff", "Pending")


@dataclass(frozen=True)
class CheckResult:
    level: Level
    message: str

    def as_dict(self) -> Dict[str, Any]:
        return {"level": self.level, "message": self.message}


@dataclass
class Section:
    name: str
    checks: List[CheckResult] = field(default_factory=list)

    def as_dict(self) -> Dict[str, Any]:
        return {"name": self.name, "checks": [c.as_dict() for c in self.checks]}


@dataclass
class DiagnoseReport:
    sections: List[Section] = field(default_factory=list)
    issues: int = 0
    warnings: int = 0
    cluster_reachable: bool = True

    def as_dict(self) -> Dict[str, Any]:
        return {
            "cluster_reachable": self.cluster_reachable,
            "issues": self.issues,
            "warnings": self.warnings,
            "sections": [s.as_dict() for s in self.sections],
        }


class _Recorder:
    """Ports the ``_check_pass``/``_check_fail``/``_check_warn``/``_check_info``
    closures defined inline in bash's ``cmd_diagnose`` (aap-demo.sh:1020-1028)."""

    def __init__(self) -> None:
        self.section = Section(name="")
        self.issues = 0
        self.warnings = 0

    def start(self, name: str) -> Section:
        self.section = Section(name=name)
        return self.section

    def ok(self, message: str) -> None:
        self.section.checks.append(CheckResult("pass", message))

    def fail(self, message: str) -> None:
        self.section.checks.append(CheckResult("fail", message))
        self.issues += 1

    def warn(self, message: str) -> None:
        self.section.checks.append(CheckResult("warn", message))
        self.warnings += 1

    def info(self, message: str) -> None:
        self.section.checks.append(CheckResult("info", message))


def _count(lines: List[str], pattern: str) -> int:
    regex = re.compile(pattern)
    return sum(1 for line in lines if regex.search(line))


def _kubectl_lines(runner: Any, *args: str) -> List[str]:
    result = runner.run(["kubectl", *args])
    if not result.ok:
        return []
    return [line for line in result.stdout.splitlines() if line.strip()]


def _check_cluster(runner: Any, rec: _Recorder) -> bool:
    """Returns whether the cluster is reachable. Ports aap-demo.sh:1030-1053."""
    rec.start("Cluster")
    crc_state = infra_crc.get_state(runner)
    if crc_state == infra_crc.STATE_RUNNING:
        rec.ok("OpenShift Local running")
    elif crc_state == infra_crc.STATE_STOPPED:
        rec.fail("OpenShift Local is stopped — run: crc start")
    else:
        rec.fail("OpenShift Local cluster not found — run: aap-demo create")

    reachable = runner.run(["kubectl", "cluster-info"]).ok
    if reachable:
        rec.ok("kubectl connected")
    else:
        rec.fail("kubectl cannot connect to cluster")
    return reachable


def _check_storage(runner: Any, rec: _Recorder) -> None:
    """Ports aap-demo.sh:1058-1093."""
    rec.start("Storage")

    if runner.run(["kubectl", "get", "sc", "topolvm-provisioner"]).ok:
        rec.ok("topolvm-provisioner StorageClass (default)")
    else:
        rec.warn("topolvm-provisioner StorageClass not found")

    if runner.run(["kubectl", "get", "sc", "nfs-local-rwx"]).ok:
        rec.ok("nfs-local-rwx StorageClass (RWX)")
        ready = runner.run(
            [
                "kubectl",
                "get",
                "deployment",
                "nfs-server",
                "-n",
                "nfs-storage",
                "-o",
                "jsonpath={.status.readyReplicas}",
            ]
        )
        ready_count = ready.stdout.strip() if ready.ok else ""
        try:
            ready_ok = int(ready_count or "0") > 0
        except ValueError:
            ready_ok = False
        if ready_ok:
            rec.ok("NFS server pod running")
        else:
            rec.fail(
                "NFS server pod not running — run: aap-demo create "
                "(or kubectl rollout restart deployment/nfs-server -n nfs-storage)"
            )
    else:
        rec.warn("nfs-local-rwx StorageClass not found — hub RWX storage unavailable")
        rec.info(
            "Fix: re-run 'aap-demo create' to deploy NFS provisioner, "
            "or create the StorageClass manually"
        )

    disk_pct = infra_crc.disk_usage_percent(infra_crc.status_json(runner))
    if disk_pct > 90:
        rec.fail(f"Disk usage: {disk_pct}% — critically low space")
    elif disk_pct > 80:
        rec.warn(
            f"Disk usage: {disk_pct}% — consider pruning: aap-demo ssh && sudo crictl rmi --prune"
        )
    else:
        rec.ok(f"Disk usage: {disk_pct}%")


def _check_security(runner: Any, namespace: str, rec: _Recorder) -> None:
    """Ports aap-demo.sh:1098-1163."""
    rec.start("Security")

    ns_exists = runner.run(["kubectl", "get", "namespace", namespace]).ok

    scc_anyuid = 0
    scc_privileged = 0
    if ns_exists:
        crb_lines = _kubectl_lines(runner, "get", "clusterrolebinding", "-o", "wide")
        scc_anyuid = _count(
            crb_lines, rf"scc:anyuid.*system:serviceaccounts:{re.escape(namespace)}"
        )
        scc_privileged = _count(
            crb_lines, rf"scc:privileged.*system:serviceaccounts:{re.escape(namespace)}"
        )
        if scc_anyuid == 0:
            scc_anyuid = _count(
                _kubectl_lines(runner, "get", "rolebinding", "-n", namespace, "-o", "wide"),
                "scc:anyuid",
            )
        if scc_privileged == 0:
            scc_privileged = _count(
                _kubectl_lines(runner, "get", "rolebinding", "-n", namespace, "-o", "wide"),
                "scc:privileged",
            )

    if scc_anyuid > 0 and scc_privileged > 0:
        rec.ok(f"SCCs granted (anyuid + privileged) in {namespace}")
    elif scc_anyuid > 0:
        rec.warn(f"Only anyuid SCC granted — privileged missing in {namespace}")
    elif scc_privileged > 0:
        rec.warn(f"Only privileged SCC granted — anyuid missing in {namespace}")
    elif ns_exists:
        rec.fail(f"No SCCs granted in {namespace} — pods will fail to start")
        rec.info(f"Fix: oc adm policy add-scc-to-group anyuid system:serviceaccounts:{namespace}")
        rec.info(
            f"Fix: oc adm policy add-scc-to-group privileged system:serviceaccounts:{namespace}"
        )
    else:
        rec.info(f"Namespace {namespace} does not exist yet (will be created on deploy)")

    if ns_exists:
        deployments = _kubectl_lines(runner, "get", "deployment", "-n", namespace, "-o", "name")
        gateway_deployments = [d for d in deployments if "gateway" in d and "operator" not in d]
        if gateway_deployments:
            gw_deployment = gateway_deployments[0]
            sg_result = runner.run(
                [
                    "kubectl",
                    "get",
                    gw_deployment,
                    "-n",
                    namespace,
                    "-o",
                    "jsonpath={.spec.template.spec.securityContext.supplementalGroups}",
                ]
            )
            if sg_result.ok and sg_result.stdout.strip() == "[0]":
                rec.ok("Gateway has supplementalGroups: [0]")
            else:
                rec.fail(
                    "Gateway missing supplementalGroups: [0] — supervisord will crash with EACCES"
                )
                rec.info(
                    f"Fix: kubectl patch {gw_deployment} -n {namespace} --type=json "
                    '-p \'[{"op":"add",'
                    '"path":"/spec/template/spec/securityContext/supplementalGroups",'
                    '"value":[0]}]\''
                )

        psa_result = runner.run(
            [
                "kubectl",
                "get",
                "namespace",
                namespace,
                "-o",
                r"jsonpath={.metadata.labels.pod-security\.kubernetes\.io/enforce}",
            ]
        )
        psa_enforce = psa_result.stdout.strip() if psa_result.ok else ""
        if psa_enforce == "privileged":
            rec.ok("Namespace PSA labels: privileged")
        elif psa_enforce:
            rec.warn(f"Namespace PSA enforce: {psa_enforce} (expected: privileged)")
        else:
            rec.fail(f"Namespace {namespace} missing PSA labels")


def _check_aap_deployment(runner: Any, namespace: str, rec: _Recorder) -> None:
    """Ports aap-demo.sh:1168-1234."""
    rec.start("AAP Deployment")

    name_result = runner.run(
        ["kubectl", "get", "aap", "-n", namespace, "-o", "jsonpath={.items[0].metadata.name}"]
    )
    aap_name = name_result.stdout.strip() if name_result.ok else ""

    if not aap_name:
        rec.info(f"No AAP instance found in {namespace}")
        return

    idle_result = runner.run(
        ["kubectl", "get", "aap", aap_name, "-n", namespace, "-o", "jsonpath={.spec.idle_aap}"]
    )
    if idle_result.ok and idle_result.stdout.strip() == "true":
        rec.info(f"AAP '{aap_name}' is idle (scaled down)")
    else:
        successful = runner.run(
            [
                "kubectl",
                "get",
                "aap",
                aap_name,
                "-n",
                namespace,
                "-o",
                'jsonpath={.status.conditions[?(@.type=="Successful")].status}',
            ]
        )
        failure = runner.run(
            [
                "kubectl",
                "get",
                "aap",
                aap_name,
                "-n",
                namespace,
                "-o",
                'jsonpath={.status.conditions[?(@.type=="Failure")].status}',
            ]
        )
        if successful.ok and successful.stdout.strip() == "True":
            rec.ok(f"AAP '{aap_name}' deployed successfully")
        elif failure.ok and failure.stdout.strip() == "True":
            message_result = runner.run(
                [
                    "kubectl",
                    "get",
                    "aap",
                    aap_name,
                    "-n",
                    namespace,
                    "-o",
                    'jsonpath={.status.conditions[?(@.type=="Failure")].message}',
                ]
            )
            fail_message = message_result.stdout.strip() if message_result.ok else ""
            rec.fail(f"AAP '{aap_name}' has failures: {fail_message or 'unknown'}")
        else:
            rec.warn(f"AAP '{aap_name}' is still reconciling")

    pod_lines = _kubectl_lines(runner, "get", "pods", "-n", namespace, "--no-headers")
    total_pods = sum(1 for line in pod_lines if "Completed" not in line)
    running_pods = sum(1 for line in pod_lines if "Running" in line)
    problem_lines = [line for line in pod_lines if any(state in line for state in _PROBLEM_STATES)]

    if problem_lines:
        rec.fail(
            f"{len(problem_lines)} pod(s) in error state ({running_pods}/{total_pods} running)"
        )
        for line in problem_lines:
            rec.info(f"  {line}")
    elif total_pods > 0:
        rec.ok(f"All pods healthy ({running_pods}/{total_pods} running)")

    pvc_lines = _kubectl_lines(runner, "get", "pvc", "-n", namespace, "--no-headers")
    pending_lines = [line for line in pvc_lines if "Pending" in line]
    if pending_lines:
        rec.fail(f"{len(pending_lines)} PVC(s) pending")
        for line in pending_lines:
            rec.info(f"  {line}")
    else:
        bound_count = sum(1 for line in pvc_lines if "Bound" in line)
        if bound_count > 0:
            rec.ok(f"All PVCs bound ({bound_count})")


def _check_dns(runner: Any, rec: _Recorder) -> None:
    """Ports aap-demo.sh:1239-1246."""
    rec.start("DNS")
    running = _count(
        _kubectl_lines(runner, "get", "pods", "-n", "openshift-dns", "--no-headers"), "Running"
    )
    if running > 0:
        rec.ok(f"CoreDNS running ({running} pods)")
    else:
        rec.warn("CoreDNS pods not found in openshift-dns")


def run(runner: Any, namespace: str) -> DiagnoseReport:
    """Ports ``cmd_diagnose`` (aap-demo.sh:1012-1300), minus ``--ai`` (§2.2)."""
    report = DiagnoseReport()
    rec = _Recorder()

    reachable = _check_cluster(runner, rec)
    report.sections.append(rec.section)
    if not reachable:
        # Bash returns 1 immediately here (aap-demo.sh:1041-1045) — no further
        # section, and no summary, is printed when kubectl cannot connect.
        report.cluster_reachable = False
        report.issues = rec.issues
        report.warnings = rec.warnings
        return report

    _check_storage(runner, rec)
    report.sections.append(rec.section)
    _check_security(runner, namespace, rec)
    report.sections.append(rec.section)
    _check_aap_deployment(runner, namespace, rec)
    report.sections.append(rec.section)
    _check_dns(runner, rec)
    report.sections.append(rec.section)

    report.issues = rec.issues
    report.warnings = rec.warnings
    return report


__all__ = ["CheckResult", "Section", "DiagnoseReport", "run"]
