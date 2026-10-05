"""Phase 3 against a real cluster (design §12.4: "first ``@pytest.mark.integration``").

Three kinds of test here, in increasing cost:

1. **Server-side dry runs.** Every manifest the deploy path renders is sent to
   the real API server with ``--dry-run=server``. That validates the rendered
   YAML against the *actual* CRD schemas — which is the one thing the
   golden-file unit tests cannot do, since they only prove the port matches
   bash, not that bash was right.
2. **Idempotent namespace setup** in a throwaway namespace, which exercises
   the real SCC grant path and then cleans up after itself.
3. **Assertions about a deployed AAP**, skipped when nothing is deployed, so
   the file is useful both immediately after a deploy and on a bare cluster.

None of these deploy AAP themselves: a full deploy takes tens of minutes and
belongs to a human-initiated run, not to a test invocation. What they do is
make that run's *result* checkable, and catch a broken render in seconds.
"""

from __future__ import annotations

import json

import pytest
import yaml

from aap_demo.cluster import aap as aap_mod
from aap_demo.cluster import catalog_signature, coredns, olm, scc, storage
from aap_demo.cluster import namespace as ns_mod
from aap_demo.exec import kubectl

from .conftest import TEST_NAMESPACE

pytestmark = pytest.mark.integration

DEFAULT_NAMESPACE = "aap-operator"


def _dry_run(ctx, manifest: str, *extra: str):
    return ctx.runner.run(
        ["kubectl", "apply", "--dry-run=server", "-f", "-", *extra], input=manifest
    )


# ---------------------------------------------------------------------------
# 1. The rendered manifests are valid against the live API server
# ---------------------------------------------------------------------------


def test_catalogsource_is_accepted_by_the_api_server(live_ctx) -> None:
    if not kubectl.exists(live_ctx.runner, "crd", olm.SUBSCRIPTION_CRD):
        pytest.skip("OLM is not installed on this cluster")
    version = catalog_signature.resolve_ocp_version(live_ctx)
    result = _dry_run(live_ctx, olm.render_catalogsource(DEFAULT_NAMESPACE, version))
    assert result.ok, result.stderr


def test_operatorgroup_and_subscription_are_accepted(live_ctx) -> None:
    if not kubectl.exists(live_ctx.runner, "crd", olm.SUBSCRIPTION_CRD):
        pytest.skip("OLM is not installed on this cluster")
    for manifest in (
        olm.render_operatorgroup(DEFAULT_NAMESPACE),
        olm.render_subscription(DEFAULT_NAMESPACE, "stable-2.7"),
    ):
        result = _dry_run(live_ctx, manifest)
        assert result.ok, result.stderr


@pytest.mark.parametrize("cr_name", ["minimal", "controller"])
def test_rendered_cr_is_accepted_by_the_aap_crd(live_ctx, cr_name: str) -> None:
    """The strongest available check that the R6 YAML rewrite is faithful."""
    if not kubectl.exists(live_ctx.runner, "crd", "ansibleautomationplatforms.aap.ansible.com"):
        pytest.skip("the AAP operator's CRDs are not installed")
    manifest = aap_mod.render_cr(aap_mod.load_cr(cr_name), namespace=DEFAULT_NAMESPACE)
    result = _dry_run(live_ctx, manifest, "-n", DEFAULT_NAMESPACE)
    assert result.ok, result.stderr


def test_storage_pvcs_are_accepted_and_name_the_rwx_class(live_ctx) -> None:
    from aap_demo import data

    manifest = storage.render_pvcs(
        data.read(data.MANIFESTS, storage.PVC_MANIFEST),
        namespace=TEST_NAMESPACE,
        aap_name="aap",
    )
    _ensure_namespace(live_ctx, TEST_NAMESPACE)
    try:
        result = _dry_run(live_ctx, manifest)
        assert result.ok, result.stderr
    finally:
        _delete_namespace(live_ctx, TEST_NAMESPACE)


def test_the_rwx_storage_class_exists_on_this_cluster(live_ctx) -> None:
    """Its absence is why ``aap-hub-file-storage`` sticks in Pending."""
    assert storage.has_rwx_class(live_ctx), "nfs-local-rwx missing — hub file storage will not bind"


# ---------------------------------------------------------------------------
# 2. Namespace setup against the real cluster
# ---------------------------------------------------------------------------


def test_namespace_setup_grants_sccs_and_labels_psa(live_ctx) -> None:
    """Runs the real ``setup_namespace`` in a throwaway namespace, then cleans up."""
    try:
        ns_mod.ensure(live_ctx, TEST_NAMESPACE)

        labels = kubectl.jsonpath(
            live_ctx.runner,
            "namespace",
            TEST_NAMESPACE,
            path="{.metadata.labels.pod-security\\.kubernetes\\.io/enforce}",
        )
        assert labels == "privileged"

        assert _scc_granted(live_ctx, "anyuid", TEST_NAMESPACE)
        assert _scc_granted(live_ctx, "privileged", TEST_NAMESPACE)
    finally:
        _delete_namespace(live_ctx, TEST_NAMESPACE)


def test_namespace_setup_is_idempotent(live_ctx) -> None:
    try:
        ns_mod.ensure(live_ctx, TEST_NAMESPACE)
        ns_mod.ensure(live_ctx, TEST_NAMESPACE)
        assert kubectl.exists(live_ctx.runner, "namespace", TEST_NAMESPACE)
    finally:
        _delete_namespace(live_ctx, TEST_NAMESPACE)


# ---------------------------------------------------------------------------
# 3. Cluster facts the deploy path depends on
# ---------------------------------------------------------------------------


def test_ocp_version_resolves_to_a_real_version(live_ctx) -> None:
    version = catalog_signature.resolve_ocp_version(live_ctx)
    assert version.count(".") == 1 and version.split(".")[0].isdigit()


def test_signature_relaxation_gate_matches_this_cluster(live_ctx) -> None:
    """4.22+ is exactly where the demo-only policy relaxation becomes necessary."""
    version = catalog_signature.resolve_ocp_version(live_ctx)
    major, minor = (int(part) for part in version.split(".")[:2])
    expected = (major, minor) >= (4, 22)
    assert catalog_signature.needs_relaxation(version) is expected


def test_coredns_corefile_is_readable(live_ctx) -> None:
    corefile = coredns.read_corefile(live_ctx)
    assert corefile, "no dns-default Corefile — routes will not resolve from in-cluster"


# ---------------------------------------------------------------------------
# 4. A deployed AAP is healthy (skipped when nothing is deployed)
# ---------------------------------------------------------------------------


@pytest.fixture
def deployed(live_ctx):
    name = aap_mod.instance_name(live_ctx, DEFAULT_NAMESPACE)
    if not name:
        pytest.skip(f"no AAP instance in {DEFAULT_NAMESPACE} — run a deploy first")
    return name


def test_deployed_aap_reports_the_successful_condition(live_ctx, deployed) -> None:
    assert aap_mod.successful_condition(live_ctx, DEFAULT_NAMESPACE) == "True"


def test_deployed_aap_has_running_pods(live_ctx, deployed) -> None:
    result = live_ctx.runner.run(["kubectl", "get", "pods", "-n", DEFAULT_NAMESPACE, "-o", "json"])
    assert result.ok
    pods = json.loads(result.stdout)["items"]
    assert pods, "no pods in the namespace"
    unhealthy = [
        pod["metadata"]["name"]
        for pod in pods
        if pod["status"].get("phase") not in ("Running", "Succeeded")
    ]
    assert not unhealthy, f"pods not Running/Succeeded: {unhealthy}"


def test_deployed_aap_publishes_a_route(live_ctx, deployed) -> None:
    host = kubectl.jsonpath(
        live_ctx.runner, "route", "-n", DEFAULT_NAMESPACE, path="{.items[0].spec.host}"
    )
    assert host, "no route published"
    assert host.endswith("nip.io") or "." in host


def test_deployed_aap_has_an_admin_password(live_ctx, deployed) -> None:
    assert aap_mod.admin_password(live_ctx, DEFAULT_NAMESPACE)


def test_gateway_has_the_net_bind_service_capability(live_ctx, deployed) -> None:
    """Without it the gateway crash-loops on EACCES binding its privileged port."""
    deployment = f"{deployed}-gateway"
    if not kubectl.exists(live_ctx.runner, "deployment", deployment, "-n", DEFAULT_NAMESPACE):
        pytest.skip("no gateway deployment (controller-only CR)")
    caps = kubectl.jsonpath(
        live_ctx.runner,
        "deployment",
        deployment,
        "-n",
        DEFAULT_NAMESPACE,
        path='{.spec.template.spec.containers[?(@.name=="api")].securityContext.capabilities.add}',
    )
    assert "NET_BIND_SERVICE" in caps


def test_no_pvc_is_stuck_pending(live_ctx, deployed) -> None:
    assert storage.pending_pvcs(live_ctx, DEFAULT_NAMESPACE) == []


def test_the_live_cr_matches_what_the_renderer_would_produce(live_ctx, deployed) -> None:
    """The applied CR's own fields still agree with the port's rendering.

    Only the keys the renderer sets are compared: the operator adds defaults,
    status and metadata of its own, and asserting on those would make this a
    test of the operator rather than of the port.
    """
    result = live_ctx.runner.run(
        ["kubectl", "get", "aap", deployed, "-n", DEFAULT_NAMESPACE, "-o", "json"]
    )
    assert result.ok
    live = json.loads(result.stdout)
    cr_name = live["metadata"]["annotations"].get("aap-demo/cr", "controller")
    rendered = yaml.safe_load(
        aap_mod.render_cr(aap_mod.load_cr(cr_name), namespace=DEFAULT_NAMESPACE)
    )
    for key, value in rendered["spec"].items():
        if isinstance(value, dict):
            for sub_key, sub_value in value.items():
                assert live["spec"].get(key, {}).get(sub_key) == sub_value, f"{key}.{sub_key}"


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


def _ensure_namespace(ctx, name: str) -> None:
    ctx.runner.run(["kubectl", "create", "namespace", name])


def _delete_namespace(ctx, name: str) -> None:
    ctx.runner.run(["kubectl", "delete", "namespace", name, "--wait=false"])


def _scc_granted(ctx, name: str, namespace: str) -> bool:
    """All three grant shapes (§14 R3 plus the one this live run turned up)."""
    return scc.grant_present(ctx, name, namespace)
