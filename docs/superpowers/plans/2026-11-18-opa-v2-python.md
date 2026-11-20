# OPA v2-Python Addon Implementation Plan

<!-- markdownlint-disable MD012 MD013 MD032 MD033 MD050 -->

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port OPA to the native Python v2 addon interface while preserving its Kubernetes deployment, AAP Policy as Code configuration, four job templates, policy playbooks, and cleanup behavior.

**Architecture:** OpaAddon owns explicit OPA Kubernetes resources and delegates AAP bootstrap/cleanup to an in-cluster Ansible playbook run through common.playbook_job. Python persists state through common.state; the existing shell addon remains packaged as the legacy fallback.

**Tech Stack:** Python 3.9+, argparse, PyYAML, AppContext/CommandRunner, kubectl, Ansible ansible.builtin.uri, pytest, Ruff, Hatch force-included addon files.

**Spec:** docs/superpowers/specs/2026-11-18-opa-v2-python-design.md

## Global Constraints

- Preserve OPA 1.20.2, the OPA Service and Route, AAP Policy as Code settings, the Policy as Code organization, OPA Localhost inventory, project, credential, four job templates, existing policy playbooks, idempotency, and addons.enabled state.
- Keep addons/opa/deploy.sh packaged and available as the legacy path until the native port is complete.
- Do not download and text-substitute arbitrary remote YAML for native Kubernetes resources; explicit Python data owns the manifest.
- Do not add a general AAP REST client; bootstrap and cleanup use ansible.builtin.uri inside common.playbook_job.
- Persist only non-secret options; never print passwords, tokens, or secret-backed extra vars.
- Keep Python 3.9 compatibility and repository Ruff/mypy constraints.
- Use Conventional Commits with git commit -s; never commit directly on main.

## Review Focus

- Conflicting ownership on an existing opa resource is rejected before apply/delete; test in Tasks 1 and 3.
- Failed bootstrap/rollout leaves opa disabled and cleans temporary resources; test in Tasks 2 and 3.
- Passwords are absent from manifests, logs, structured output, and errors; test in Tasks 2 and 3.
- Installed wheels find both native playbooks and the legacy fallback; test in Task 4.
- Environment overrides and a second enable are idempotent; test in Task 3.

---

### Task 1: Render owned OPA Kubernetes resources

**Files:**
- Create: src/aap_demo/addons/opa_resources.py
- Test: tests/unit/test_opa_resources.py

**Interfaces:** resource_documents(namespace: str, opa_version: str, route_host: str) -> list[dict], owned(document: dict) -> bool, and resource_names() -> tuple[str, ...].

- [ ] **Step 1: Write failing tests**

~~~python
import pytest

from aap_demo.addons.opa_resources import OWNER, owned, resource_documents


def test_resources_have_expected_kinds_image_and_route() -> None:
    docs = resource_documents("aap-operator", "1.20.2", "opa.apps.example.test")
    assert [(d["kind"], d["metadata"]["name"]) for d in docs] == [
        ("Deployment", "opa"), ("Service", "opa"), ("Route", "opa")
    ]
    assert docs[0]["metadata"]["labels"]["app.kubernetes.io/managed-by"] == OWNER
    container = docs[0]["spec"]["template"]["spec"]["containers"][0]
    assert container["image"] == "openpolicyagent/opa:1.20.2"
    assert container["ports"] == [{"name": "http", "containerPort": 8181}]
    assert docs[2]["spec"]["host"] == "opa.apps.example.test"


def test_ownership_requires_both_labels() -> None:
    doc = resource_documents("aap-operator", "1.20.2", "opa.apps.example.test")[0]
    assert owned(doc)
    doc["metadata"]["labels"]["app.kubernetes.io/managed-by"] = "other"
    assert not owned(doc)


@pytest.mark.parametrize("version", ["", "1.20.2\n", "../../bad"])
def test_invalid_image_version_is_rejected(version: str) -> None:
    with pytest.raises(ValueError, match="OPA version"):
        resource_documents("aap-operator", version, "opa.apps.example.test")
~~~

- [ ] **Step 2: Run the test to verify it fails**

Run: python -m pytest tests/unit/test_opa_resources.py -q

Expected: FAIL because the module does not exist.

- [ ] **Step 3: Implement the resource module**

Define OWNER = "aap-demo-opa", PART_OF = "aap-demo", stable app: opa
selectors, and the three resources. The Deployment uses one replica, image
openpolicyagent/opa:{opa_version}, port 8181, run --server --addr
0.0.0.0:8181, and an HTTP /health readiness probe. The Service exposes port
8181 and the Route targets that Service. Validate the version with
[A-Za-z0-9._-]+. owned() requires both ownership labels and the OPA identity.

- [ ] **Step 4: Run the test to verify it passes**

Run: python -m pytest tests/unit/test_opa_resources.py -q

Expected: PASS.

- [ ] **Step 5: Commit**

~~~bash
git add src/aap_demo/addons/opa_resources.py tests/unit/test_opa_resources.py
git commit -s -m "feat(opa): render owned native resources"
~~~

### Task 2: Add the in-cluster AAP bootstrap playbook

**Files:**
- Create: addons/opa/playbooks/bootstrap.yml
- Create: src/aap_demo/addons/opa_playbooks.py
- Test: tests/unit/test_opa_playbooks.py

**Interfaces:** playbooks_root() -> Path and playbook_files() -> dict[str, str], returning bootstrap.yml, load-policies.yml, test-policies.yml, clear-policies.yml, and demo-policy.yml.

- [ ] **Step 1: Write failing loader and playbook contract tests**

~~~python
import yaml

from aap_demo.addons.opa_playbooks import playbook_files, playbooks_root


def test_all_opa_playbooks_are_available() -> None:
    root = playbooks_root()
    assert all((root / name).is_file() for name in (
        "bootstrap.yml", "load-policies.yml", "test-policies.yml",
        "clear-policies.yml", "demo-policy.yml",
    ))
    assert set(playbook_files()) == {
        "bootstrap.yml", "load-policies.yml", "test-policies.yml",
        "clear-policies.yml", "demo-policy.yml",
    }


def test_bootstrap_uses_uri_and_has_both_states() -> None:
    text = playbook_files()["bootstrap.yml"]
    docs = list(yaml.safe_load_all(text))
    assert "ansible.builtin.uri" in text
    assert "state: present" in text
    assert "state: absent" in text
    for name in ("OPA | Load Example Policies", "OPA | Test Policies",
                 "OPA | Clear Policies", "OPA | Demo Policy"):
        assert name in text
    assert "aap_password" not in text.split("debug", 1)[-1]
    assert docs
~~~

- [ ] **Step 2: Run the test to verify it fails**

Run: python -m pytest tests/unit/test_opa_playbooks.py -q

Expected: FAIL because the loader and bootstrap playbook do not exist.

- [ ] **Step 3: Implement checkout/package resolution**

Resolve addons/opa/playbooks from a source checkout first, then
aap_demo/bundled/addons/opa/playbooks beside the installed package. Return
UTF-8 text for exactly the five named files and raise AddonError naming the
missing path when neither location is complete.

- [ ] **Step 4: Implement bootstrap.yml**

Accept gateway_url, aap_username, aap_password, opa_server, opa_repo, opa_ref,
aap_demo_repo, aap_demo_branch, namespace, state, and the policy playbook names.
Use ansible.builtin.uri with Basic Auth and validate_certs: false; GET by name/org
before POST/PATCH. In present, create or update the Policy as Code organization,
OPA Localhost inventory and localhost host, project, least-privilege AAP
credential, four exact job templates, and OPA settings. Poll project sync for at
most 60 attempts and fail on failed or timeout. Build the demo survey from the
GitHub contents API at opa_repo/opa_ref, always adding REMOVE. In absent, clear
OPA_HOST and delete only those named resources within the owned organization.
Never debug or print aap_password or credential inputs.

- [ ] **Step 5: Run the test to verify it passes**

Run: python -m pytest tests/unit/test_opa_playbooks.py -q

Expected: PASS.

- [ ] **Step 6: Commit**

~~~bash
git add addons/opa/playbooks/bootstrap.yml src/aap_demo/addons/opa_playbooks.py tests/unit/test_opa_playbooks.py
git commit -s -m "feat(opa): add native bootstrap playbook"
~~~

### Task 3: Implement OpaAddon orchestration and cleanup

**Files:**
- Create: src/aap_demo/addons/opa.py
- Test: tests/unit/test_opa_addon.py

**Interfaces:** OpaAddon.name == "opa", kind == "native", public is True,
needs_cluster is True, enable(ctx, args) -> 0, and disable(ctx, args) -> 0.

- [ ] **Step 1: Write failing contract and behavior tests**

~~~python
import argparse
import json
import pytest

from aap_demo.addons import get
from aap_demo.core.errors import AddonError


def args() -> argparse.Namespace:
    return argparse.Namespace(addon="opa", addon_args=[])


def test_opa_is_native_and_public() -> None:
    addon = get("opa")
    assert (addon.kind, addon.public, addon.needs_cluster) == ("native", True, True)


def test_conflicting_deployment_stops_before_apply(app_ctx, monkeypatch) -> None:
    _stub_dependencies(app_ctx, monkeypatch)
    app_ctx.runner.ok(
        ["kubectl", "get", "deployment", "opa"],
        stdout=json.dumps({"metadata": {"labels": {
            "app": "opa", "app.kubernetes.io/managed-by": "other"
        }}}),
    )
    with pytest.raises(AddonError, match="owned"):
        get("opa").enable(app_ctx, args())
    assert not any(c.argv[:2] == ("kubectl", "apply") for c in app_ctx.runner.calls)
~~~

Add fixtures for gateway_url, discover_image, admin_password, rollout, and
playbook_job.run; capture the submitted PlaybookJob instead of running a real
cluster job.

- [ ] **Step 2: Run the test to verify it fails**

Run: python -m pytest tests/unit/test_opa_addon.py -q

Expected: FAIL because the addon is not implemented or registered.

- [ ] **Step 3: Implement options, route, and ownership checks**

Read addons.options.opa first and environment second, with defaults:
OPA_VERSION=1.20.2, OPA_REPO=https://github.com/ansible/example-opa-policy-for-aap,
OPA_MANIFEST_REF=8dad3022d5, AAP_DEMO_REPO=https://github.com/RedHatOfficial/aap-demo.git,
and AAP_DEMO_BRANCH=main. Discover the AAP route with kubectl get route aap and
derive opa.<domain> plus http://opa.<namespace>.svc.cluster.local:8181. Use
common.kube.read_object to guard Deployment, Service, and Route; raise
AddonError("refusing to use unowned OPA resource") on conflicting labels.

- [ ] **Step 4: Implement the bootstrap job and enable flow**

Create _bootstrap_job(ctx, state) using gateway.gateway_url,
ee.discover_image(ctx, addon="opa"), and aap.admin_password. Supply
aap_hostname, aap_username: admin, password, OPA/AAP repository values,
opa_server, namespace, state, and exact playbook names as extra vars; the
existing PlaybookJob Secret carries extra vars. Use the five playbook files,
bootstrap.yml, a stable aap-demo-opa-bootstrap Job name, mount root
/opt/aap-demo-opa, and the configured namespace as pull-secret source.

Enable must apply resources, wait for kubectl rollout status deployment/opa -n
<namespace> --timeout=120s, run the bootstrap job with state: present, then
persist options and add exactly one opa entry to addons.enabled. On rollout or
bootstrap failure, leave state unchanged and clean newly created resources.
Progress/output may show routes and service URLs but never the password.

- [ ] **Step 5: Implement disable flow**

Verify ownership, run the bootstrap job with state: absent, delete owned
Deployment/Service/Route with --ignore-not-found, and only then remove opa from
addons.enabled. If AAP cleanup fails, retain enabled state and Kubernetes
resources. If resources are absent, state removal still waits for AAP cleanup.

- [ ] **Step 6: Add idempotency, failure, ownership, and redaction tests**

Add tests named test_enable_records_state_only_after_bootstrap,
test_second_enable_keeps_one_state_entry, test_rollout_failure_cleans_up,
test_bootstrap_failure_keeps_state_disabled, test_disable_refuses_unowned_service,
and test_password_is_absent_from_output_and_error. Assert the captured job,
resource manifests, cleanup commands, and FakeRunner error hints.

- [ ] **Step 7: Run the test to verify it passes**

Run: python -m pytest tests/unit/test_opa_addon.py -q

Expected: PASS.

- [ ] **Step 8: Commit**

~~~bash
git add src/aap_demo/addons/opa.py tests/unit/test_opa_addon.py
git commit -s -m "feat(opa): add native Python addon"
~~~

### Task 4: Register OPA and package native/fallback files

**Files:**
- Modify: src/aap_demo/addons/__init__.py
- Modify: pyproject.toml:67-82
- Modify: tests/unit/test_addon_registry.py
- Modify: tests/unit/test_product_demos_addon.py
- Modify: tests/unit/test_bundle_verify.py

- [ ] **Step 1: Add failing registry/package assertions**

Assert get("opa") is a native public cluster addon, get("opa") is get("opa"),
and "opa" in names(). Assert Hatch includes
"addons/opa" = "aap_demo/bundled/addons/opa", deploy.sh, and all five playbooks.

- [ ] **Step 2: Run focused tests to verify failure**

Run: python -m pytest tests/unit/test_addon_registry.py tests/unit/test_bundle_verify.py -q

Expected: FAIL until registration and packaging are changed.

- [ ] **Step 3: Register the native singleton and package the directory**

Import OpaAddon, instantiate _OPA, and insert it before the shell-directory
comprehension so a shell entry cannot replace it. Add the exact Hatch mapping
above, preserving deploy.sh for the legacy command and playbooks/ for the
native loader.

- [ ] **Step 4: Run focused tests**

Run: python -m pytest tests/unit/test_addon_registry.py tests/unit/test_product_demos_addon.py tests/unit/test_bundle_verify.py -q

Expected: PASS with opa in every sorted addon listing.

- [ ] **Step 5: Commit**

~~~bash
git add src/aap_demo/addons/__init__.py pyproject.toml tests/unit/test_addon_registry.py tests/unit/test_product_demos_addon.py tests/unit/test_bundle_verify.py
git commit -s -m "feat(opa): register native addon and package fallback"
~~~

### Task 5: Update documentation and add cluster smoke validation

**Files:**
- Modify: addons/opa/README.md
- Modify: docs/guides/addons.md
- Modify: docs/index.md
- Create: test/test-opa-addon.sh

- [ ] **Step 1: Document the native workflow**

Identify aap-demo enable opa as Python-v2 supported, retain the four exact
template names and environment overrides, document addons.enabled state and
the explicit legacy fallback, and add an OPA section to docs/guides/addons.md
with enable, disable, health, and policy-template commands. Add OPA to
docs/index.md while keeping required front matter on indexed pages.

- [ ] **Step 2: Add the smoke script**

Following existing test/test-*-addon.sh conventions, create an executable
script that runs aap-demo enable opa, waits for the OPA deployment rollout,
checks /health, asserts all four AAP templates, runs aap-demo disable opa, and
asserts the Deployment, Service, and Route are absent. Use the existing
kubeconfig/namespace environment and never print secrets.

- [ ] **Step 3: Run docs and shell checks**

~~~bash
markdownlint addons/opa/README.md docs/guides/addons.md docs/index.md --config .markdownlint.json
bash -n test/test-opa-addon.sh
~~~

Expected: both commands pass.

- [ ] **Step 4: Commit**

~~~bash
git add addons/opa/README.md docs/guides/addons.md docs/index.md test/test-opa-addon.sh
git commit -s -m "docs(opa): document native addon workflow"
~~~

### Task 6: Complete verification and real-cluster validation

- [ ] **Step 1: Run repository checks**

~~~bash
python -m pytest tests/unit -q
python -m ruff check src tests
python -m ruff format --check src tests
python -m aap_demo --help
~~~

Expected: all commands exit 0.

- [ ] **Step 2: Build and inspect the wheel**

~~~bash
python -m pip install -e ".[dev]"
python -m build
python -m pytest tests/unit/test_opa_playbooks.py tests/unit/test_bundle_verify.py -q
~~~

Expected: the wheel contains aap_demo/bundled/addons/opa/ and packaged-runtime tests pass.

- [ ] **Step 3: Run the disposable-cluster smoke test**

~~~bash
./test/test-opa-addon.sh
~~~

Record rollout, health, four templates, disable cleanup, and ownership-safe
deletion in the pull request test plan.

- [ ] **Step 4: Inspect final state**

~~~bash
git diff main...HEAD --check
git status --short --branch
git log --oneline --decorate -8
~~~

Expected: no whitespace errors, only intended OPA files changed, and a clean
feature branch.
