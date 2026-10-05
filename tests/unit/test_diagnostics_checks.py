"""``diagnostics/checks.py``: ``aap-demo diagnose`` (minus ``--ai``) over
realistic fixture cluster states (design §7.2's "no cluster, pending PVC,
missing supplementalGroups, ..." states, each becoming a fixture + a test).
"""

from __future__ import annotations

from aap_demo.diagnostics import checks as diagnose_checks
from aap_demo.exec.runner import FakeRunner

NAMESPACE = "aap-operator"


def test_unreachable_cluster_stops_after_the_cluster_section(fake_runner: FakeRunner) -> None:
    fake_runner.fail("crc status -o json")
    fake_runner.fail("kubectl cluster-info")

    report = diagnose_checks.run(fake_runner, NAMESPACE)

    assert report.cluster_reachable is False
    assert len(report.sections) == 1
    assert report.sections[0].name == "Cluster"
    assert any(c.level == "fail" for c in report.sections[0].checks)
    # Bash returns 1 immediately (aap-demo.sh:1041-1045) — no Storage/Security/
    # AAP Deployment/DNS section, and no kubectl calls beyond cluster-info.
    assert not fake_runner.called("kubectl get")


def _register_healthy_cluster(
    fake_runner: FakeRunner,
    *,
    disk_use: int = 1,
    disk_size: int = 100,
    topolvm_ok: bool = True,
    nfs_sc_ok: bool = True,
    nfs_ready_replicas: str = "1",
    crb_stdout: str = (
        f"scc:anyuid system:serviceaccounts:{NAMESPACE}\n"
        f"scc:privileged system:serviceaccounts:{NAMESPACE}\n"
    ),
    rolebinding_stdout: str = "",
    supplemental_groups: str = "[0]",
    psa_enforce: str = "privileged",
    aap_name_stdout: str = "myaap",
    idle_stdout: str = "false",
    successful_stdout: str = "True",
    pod_lines: str = "aap-gateway-1  1/1  Running  0  1h\n",
    pvc_lines: str = "data  Bound  1h\n",
    dns_pod_lines: str = "dns-1  1/1  Running  0  1h\n",
) -> None:
    fake_runner.ok(
        "crc status -o json",
        stdout=f'{{"crcStatus": "Running", "diskUse": {disk_use}, "diskSize": {disk_size}}}',
    )
    fake_runner.ok("kubectl cluster-info", stdout="Kubernetes control plane is running")

    if topolvm_ok:
        fake_runner.ok(["kubectl", "get", "sc", "topolvm-provisioner"], stdout="ok")
    else:
        fake_runner.fail(["kubectl", "get", "sc", "topolvm-provisioner"])

    if nfs_sc_ok:
        fake_runner.ok(["kubectl", "get", "sc", "nfs-local-rwx"], stdout="ok")
        fake_runner.ok(
            [
                "kubectl",
                "get",
                "deployment",
                "nfs-server",
                "-n",
                "nfs-storage",
                "-o",
                "jsonpath={.status.readyReplicas}",
            ],
            stdout=nfs_ready_replicas,
        )
    else:
        fake_runner.fail(["kubectl", "get", "sc", "nfs-local-rwx"])

    # Registered before the plain "get namespace NAMESPACE" rule below:
    # FakeRunner matches by prefix in registration order, and that shorter
    # rule is itself a prefix of this longer jsonpath invocation.
    fake_runner.ok(
        [
            "kubectl",
            "get",
            "namespace",
            NAMESPACE,
            "-o",
            r"jsonpath={.metadata.labels.pod-security\.kubernetes\.io/enforce}",
        ],
        stdout=psa_enforce,
    )
    fake_runner.ok(["kubectl", "get", "namespace", NAMESPACE], stdout="ok")
    fake_runner.ok(["kubectl", "get", "clusterrolebinding", "-o", "wide"], stdout=crb_stdout)
    fake_runner.ok(
        ["kubectl", "get", "rolebinding", "-n", NAMESPACE, "-o", "wide"], stdout=rolebinding_stdout
    )
    fake_runner.ok(
        ["kubectl", "get", "deployment", "-n", NAMESPACE, "-o", "name"],
        stdout="deployment/aap-gateway\n",
    )
    fake_runner.ok(
        [
            "kubectl",
            "get",
            "deployment/aap-gateway",
            "-n",
            NAMESPACE,
            "-o",
            "jsonpath={.spec.template.spec.securityContext.supplementalGroups}",
        ],
        stdout=supplemental_groups,
    )
    fake_runner.ok(
        ["kubectl", "get", "aap", "-n", NAMESPACE, "-o", "jsonpath={.items[0].metadata.name}"],
        stdout=aap_name_stdout,
    )
    if aap_name_stdout:
        fake_runner.ok(
            ["kubectl", "get", "aap", "myaap", "-n", NAMESPACE, "-o", "jsonpath={.spec.idle_aap}"],
            stdout=idle_stdout,
        )
        fake_runner.ok(
            [
                "kubectl",
                "get",
                "aap",
                "myaap",
                "-n",
                NAMESPACE,
                "-o",
                'jsonpath={.status.conditions[?(@.type=="Successful")].status}',
            ],
            stdout=successful_stdout,
        )
        fake_runner.ok(
            [
                "kubectl",
                "get",
                "aap",
                "myaap",
                "-n",
                NAMESPACE,
                "-o",
                'jsonpath={.status.conditions[?(@.type=="Failure")].status}',
            ],
            stdout="",
        )
    fake_runner.ok(["kubectl", "get", "pods", "-n", NAMESPACE, "--no-headers"], stdout=pod_lines)
    fake_runner.ok(["kubectl", "get", "pvc", "-n", NAMESPACE, "--no-headers"], stdout=pvc_lines)
    fake_runner.ok(
        ["kubectl", "get", "pods", "-n", "openshift-dns", "--no-headers"], stdout=dns_pod_lines
    )


def test_fully_healthy_cluster_reports_no_issues_or_warnings(fake_runner: FakeRunner) -> None:
    _register_healthy_cluster(fake_runner)

    report = diagnose_checks.run(fake_runner, NAMESPACE)

    assert report.cluster_reachable is True
    assert report.issues == 0
    assert report.warnings == 0
    assert [s.name for s in report.sections] == [
        "Cluster",
        "Storage",
        "Security",
        "AAP Deployment",
        "DNS",
    ]


def test_missing_sccs_is_a_failure_with_fix_hints(fake_runner: FakeRunner) -> None:
    _register_healthy_cluster(fake_runner, crb_stdout="", rolebinding_stdout="")

    report = diagnose_checks.run(fake_runner, NAMESPACE)

    security = next(s for s in report.sections if s.name == "Security")
    messages = [c.message for c in security.checks]
    assert any("No SCCs granted" in m for m in messages)
    assert any("add-scc-to-group anyuid" in m for m in messages)
    assert any("add-scc-to-group privileged" in m for m in messages)
    assert report.issues >= 1


def test_missing_supplemental_groups_is_a_failure(fake_runner: FakeRunner) -> None:
    _register_healthy_cluster(fake_runner, supplemental_groups="")

    report = diagnose_checks.run(fake_runner, NAMESPACE)

    security = next(s for s in report.sections if s.name == "Security")
    assert any("supplementalGroups" in c.message and c.level == "fail" for c in security.checks)


def test_pending_pvcs_are_listed_as_failures(fake_runner: FakeRunner) -> None:
    _register_healthy_cluster(fake_runner, pvc_lines="hub-file-storage  Pending  1h\n")

    report = diagnose_checks.run(fake_runner, NAMESPACE)

    deployment_section = next(s for s in report.sections if s.name == "AAP Deployment")
    messages = [c.message for c in deployment_section.checks]
    assert any("PVC(s) pending" in m for m in messages)
    assert any("hub-file-storage" in m for m in messages)
    assert report.issues >= 1


def test_problem_pods_are_listed_as_failures(fake_runner: FakeRunner) -> None:
    _register_healthy_cluster(
        fake_runner, pod_lines="aap-gateway-1  0/1  CrashLoopBackOff  3  1h\n"
    )

    report = diagnose_checks.run(fake_runner, NAMESPACE)

    deployment_section = next(s for s in report.sections if s.name == "AAP Deployment")
    messages = [c.message for c in deployment_section.checks]
    assert any("pod(s) in error state" in m for m in messages)
    assert any("CrashLoopBackOff" in m for m in messages)


def test_no_nfs_storage_class_is_a_warning_with_a_fix_hint(fake_runner: FakeRunner) -> None:
    _register_healthy_cluster(fake_runner, nfs_sc_ok=False)

    report = diagnose_checks.run(fake_runner, NAMESPACE)

    storage = next(s for s in report.sections if s.name == "Storage")
    messages = [(c.level, c.message) for c in storage.checks]
    assert (
        "warn",
        "nfs-local-rwx StorageClass not found — hub RWX storage unavailable",
    ) in messages
    assert any(level == "info" and "Fix:" in msg for level, msg in messages)
    assert report.warnings >= 1


def test_nfs_storage_class_present_but_server_not_ready_is_a_failure(
    fake_runner: FakeRunner,
) -> None:
    _register_healthy_cluster(fake_runner, nfs_ready_replicas="0")

    report = diagnose_checks.run(fake_runner, NAMESPACE)

    storage = next(s for s in report.sections if s.name == "Storage")
    assert any(
        c.level == "fail" and "NFS server pod not running" in c.message for c in storage.checks
    )


def test_high_disk_usage_is_a_warning(fake_runner: FakeRunner) -> None:
    _register_healthy_cluster(fake_runner, disk_use=85, disk_size=100)

    report = diagnose_checks.run(fake_runner, NAMESPACE)

    storage = next(s for s in report.sections if s.name == "Storage")
    assert any(c.level == "warn" and "crictl rmi --prune" in c.message for c in storage.checks)
    assert report.warnings >= 1


def test_critical_disk_usage_is_a_failure(fake_runner: FakeRunner) -> None:
    _register_healthy_cluster(fake_runner, disk_use=95, disk_size=100)

    report = diagnose_checks.run(fake_runner, NAMESPACE)

    storage = next(s for s in report.sections if s.name == "Storage")
    assert any(c.level == "fail" and "critically low space" in c.message for c in storage.checks)
    assert report.issues >= 1


def test_no_aap_instance_is_informational_not_a_failure(fake_runner: FakeRunner) -> None:
    _register_healthy_cluster(fake_runner, aap_name_stdout="")

    report = diagnose_checks.run(fake_runner, NAMESPACE)

    deployment_section = next(s for s in report.sections if s.name == "AAP Deployment")
    assert len(deployment_section.checks) == 1
    assert deployment_section.checks[0].level == "info"
    assert report.issues == 0


def test_idle_aap_is_informational(fake_runner: FakeRunner) -> None:
    _register_healthy_cluster(fake_runner, idle_stdout="true")

    report = diagnose_checks.run(fake_runner, NAMESPACE)

    deployment_section = next(s for s in report.sections if s.name == "AAP Deployment")
    assert any("is idle" in c.message for c in deployment_section.checks)


def test_reconciling_aap_is_a_warning(fake_runner: FakeRunner) -> None:
    _register_healthy_cluster(fake_runner, successful_stdout="")

    report = diagnose_checks.run(fake_runner, NAMESPACE)

    deployment_section = next(s for s in report.sections if s.name == "AAP Deployment")
    assert any(
        c.level == "warn" and "still reconciling" in c.message for c in deployment_section.checks
    )


def test_no_coredns_pods_is_a_warning(fake_runner: FakeRunner) -> None:
    _register_healthy_cluster(fake_runner, dns_pod_lines="")

    report = diagnose_checks.run(fake_runner, NAMESPACE)

    dns_section = next(s for s in report.sections if s.name == "DNS")
    assert any(c.level == "warn" for c in dns_section.checks)


def test_report_as_dict_round_trips_for_json_output(fake_runner: FakeRunner) -> None:
    _register_healthy_cluster(fake_runner)
    report = diagnose_checks.run(fake_runner, NAMESPACE)
    payload = report.as_dict()
    assert payload["issues"] == 0
    assert payload["cluster_reachable"] is True
    assert {s["name"] for s in payload["sections"]} == {
        "Cluster",
        "Storage",
        "Security",
        "AAP Deployment",
        "DNS",
    }
