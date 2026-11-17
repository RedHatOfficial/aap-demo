<!-- markdownlint-disable MD013 -->

# Bash Addons to Native V2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate every non-AO bash addon to the native Python V2 addon interface, with one isolated feature branch and test gate per addon.

**Architecture:** Each addon becomes a native `Addon` implementation registered in the shared Python registry and built on the existing `AppContext`, runner, Kubernetes, gateway, playbook-job, and state helpers. Legacy bash installers remain available to V1 and serve as the behavior reference; V2 does not shell out to them. Product-demo domains follow the base addon; AO-family work is deferred.

**Tech Stack:** Python 3.9+, `aap_demo.addons.base.Addon`, `AppContext`, existing runner/kubectl helpers, `addons/common`, pytest, Ruff, Bash reference installers, and disposable MicroShift/OpenShift smoke tests.

**Spec:** `docs/superpowers/specs/2026-11-17-bash-addons-v2-migration-design.md`

## Global Constraints

- Never commit directly to `main`; use one `feature/<addon>-v2` branch per addon and signed commits.
- Do not modify `addons/ao`, `addons/ao-eap`, or AO-owned shared behavior; `ao-pr-testing` waits for Adam’s AO V2 interface.
- Do not invoke a legacy `deploy.sh` from a native V2 addon.
- Preserve existing addon-owned resources, defaults, environment variables, local state, and cleanup semantics unless an addon-specific ADR says otherwise.
- Use `AppContext.runner` and existing Python seams in tests; do not call the host shell directly from unit tests.
- Do not print or persist secrets in test output, manifests, command arguments, or normal status output.
- Every branch ends with focused tests, full unit tests, Ruff, format checks, `git diff --check`, and the relevant live smoke test or a recorded reason it could not run.

## Review Focus

- Cleanup ownership: disabling one addon must not delete AAP, AO, or another addon’s resources; test this in every port.
- Idempotence: repeated enable must converge without duplicate resources or config entries; test the second enable path.
- Partial failure: a failed apply, Helm operation, playbook job, or external API call must leave state truthful and retryable.
- Secret safety: credentials, tokens, kubeconfigs, and generated passwords must never appear in argv, logs, status, or Git.
- Platform/tool boundaries: missing binaries, unsupported architecture, Windows/Git Bash behavior, and cluster-not-ready errors must be actionable.

## Branch workflow used for every addon

Run from a clean working tree on the integration branch:

```bash
git switch <integration-branch>
git pull --ff-only
git switch -c feature/<addon>-v2
```

For the branch’s addon, perform these steps in order:

1. Read the addon README, its ADRs, its `deploy.sh`, sourced libraries, manifests, and existing shell tests. Write the resource/secret/state ownership table in the focused Python test module before implementation.
2. Add the failing registry/lifecycle tests and run only that module; confirm failure for the missing native class.
3. Implement the minimal native class and helper module(s), registering the canonical name and any existing alias.
4. Add tests for idempotent enable, failure-state preservation, cleanup ownership, status redaction, and addon-specific prerequisites.
5. Run the focused module, then the full checks:

   ```bash
   python -m pytest tests/unit/<focused-test>.py -q
   python -m pytest tests/unit -q
   python -m ruff check src tests
   python -m ruff format --check src tests
   git diff --check
   ```

6. Run the disposable-cluster smoke test: enable, inspect status and owned resources, enable again, disable, and inspect cleanup. Record results without credentials.
7. Commit signed with a Conventional Commit message, push the branch, and open a PR against the integration branch. Do not combine another addon’s migration into the branch.

## File map

| Area | Responsibility |
| --- | --- |
| `src/aap_demo/addons/<addon>.py` | Native lifecycle, resource generation, API/playbook orchestration, and status rendering for one addon. |
| `src/aap_demo/addons/__init__.py` | One registry entry, canonical name, alias, and public visibility for one addon. |
| `src/aap_demo/addons/common/` | Reusable helpers only; changes require a separate common-framework branch. |
| `tests/unit/test_<addon>_addon.py` | Focused mocked lifecycle, state, ownership, failure, and secret-safety tests. |
| `tests/integration/test_<addon>_live.py` or existing live suite | Opt-in disposable-cluster smoke coverage where the addon warrants it. |
| `docs/guides/addons.md` or addon documentation | V2 command, prerequisites, state, and cleanup behavior. |
| `addons/<addon>/` | Legacy V1 implementation retained as behavior reference and older-command support. |

## Migration branches

Each row below is an independent feature branch and a complete test/PR unit. The
listed dependencies mean the dependent branch starts after the dependency is
merged; they do not permit combining branches.

### Task 1: `feature/apme-eap-v2`

**Files:** Create `src/aap_demo/addons/apme_eap.py` and `tests/unit/test_apme_eap_addon.py`; modify `src/aap_demo/addons/__init__.py` and the addon guide; test the existing APME playbook/OCI publishing path.

- [ ] Extract the current playbook, Helm, local venv, GitHub credential, plugin-pack, and registry ownership from `addons/apme-eap/deploy.sh` and `lib.sh` into tests.
- [ ] Implement enable/disable/destroy/status using Python runner seams and the existing state directory; preserve the plugin-pack and credential file boundaries.
- [ ] Test missing playbook dependencies, failed OCI push, repeat enable, cleanup, and redacted credentials.
- [ ] Run the branch workflow and the APME live smoke test.

### Task 2: `feature/devspaces-v2`

**Files:** Create `src/aap_demo/addons/devspaces.py` and `tests/unit/test_devspaces_addon.py`; modify registry and addon docs.

- [ ] Port OLM/operator subscription, CheCluster creation, readiness, namespace cleanup, and finalizer-tolerant disable behavior.
- [ ] Test OLM missing, cluster unavailable, repeated enable, deletion timeout handling, and namespace ownership.
- [ ] Run the branch workflow and verify the CheCluster/operator disappear after disable.

### Task 3: `feature/eda-playground-v2`

**Files:** Create `src/aap_demo/addons/eda_playground.py` and `tests/unit/test_eda_playground_native_addon.py`; modify registry/docs while preserving the existing shell-fallback tests.

- [ ] Port manifests, OAuth route/configuration, state directory, image configuration, and delete behavior from the current shell addon.
- [ ] Test custom namespace/image, route and secret redaction, repeat enable, and cleanup without deleting shared EDA/AAP resources.
- [ ] Run the branch workflow and EDA playground live smoke test.

### Task 4: `feature/keycloak-v2`

**Files:** Create `src/aap_demo/addons/keycloak.py` and `tests/unit/test_keycloak_addon.py`; modify registry/docs.

- [ ] Port manifest application, readiness, route discovery, realm/client configuration, and delete behavior.
- [ ] Test idempotent realm/client setup, missing route, failed readiness, password handling, and owned-resource cleanup.
- [ ] Run the branch workflow and Keycloak live smoke test.

### Task 5: `feature/local-cache-v2`

**Files:** Create `src/aap_demo/addons/local_cache.py` and `tests/unit/test_local_cache_addon.py`; modify registry/docs.

- [ ] Port CRC SSH image save/load, cache paths, image selection, and delete/clear behavior through existing Python SSH seams.
- [ ] Test missing CRC SSH, image transfer failure, cache reuse, path safety, and no accidental deletion outside the addon cache.
- [ ] Run the branch workflow and a disposable CRC cache smoke test.

### Task 6: `feature/mcp-server-v2`

**Files:** Create `src/aap_demo/addons/mcp_server.py` and `tests/unit/test_mcp_server_addon.py`; modify registry/docs.

- [ ] Port the MCP server CR, namespace/configuration, readiness, route, and delete lifecycle.
- [ ] Test CR apply failure, route/status output, repeated reconciliation, and cleanup limited to MCP-owned objects.
- [ ] Run the branch workflow and MCP live smoke test.

### Task 7: `feature/ollama-v2`

**Files:** Create `src/aap_demo/addons/ollama.py` and `tests/unit/test_ollama_addon.py`; modify registry/docs.

- [ ] Port namespace, deployment/service, model pull/warm-up, persistent state, AO integration prerequisites, and delete behavior without implementing AO itself.
- [ ] Test model configuration, pull failure/retry, secret redaction, resource readiness, and cleanup while preserving the documented model state semantics.
- [ ] Run the branch workflow and Ollama smoke test; record AO integration checks as deferred if Adam’s interface is not merged.

### Task 8: `feature/olm-v2`

**Files:** Create `src/aap_demo/addons/olm.py` and `tests/unit/test_olm_addon.py`; modify the deployment integration that currently invokes `addons/olm/deploy.sh` and relevant docs.

- [ ] Port operator-sdk installation/uninstallation and catalog readiness through the existing operator-sdk and CRC helpers.
- [ ] Test already-installed OLM, timeout-with-resources-present, unsupported platform, and safe uninstall behavior.
- [ ] Run the branch workflow and verify OLM state on a disposable cluster.

### Task 9: `feature/opa-v2`

**Files:** Create `src/aap_demo/addons/opa.py` and `tests/unit/test_opa_addon.py`; modify registry/docs.

- [ ] Port OPA deployment/manifests and policy load/test/clear playbook operations using existing playbook-job or runner helpers.
- [ ] Test policy load failure, clear scope, repeat enable, status, and cleanup ownership.
- [ ] Run the branch workflow and OPA policy live smoke test.

### Task 10: `feature/portal-v2`

**Files:** Create `src/aap_demo/addons/portal.py` and `tests/unit/test_portal_addon.py`; modify registry/docs.

- [ ] Port Helm installation, architecture-specific values, registry credential extraction, dynamic plugin settings, route readiness, and delete behavior.
- [ ] Test missing Helm, missing/invalid registry credentials, arm64/amd64 values, repeat upgrade, secret redaction, and cleanup.
- [ ] Run the branch workflow and Portal live smoke test on supported architectures where available.

### Task 11: `feature/portal-operator-v2`

**Files:** Create `src/aap_demo/addons/portal_operator.py` and `tests/unit/test_portal_operator_addon.py`; modify registry/docs.

- [ ] Port operator subscription/CSV readiness and uninstall, keeping it separate from the Portal application addon.
- [ ] Test existing CSV, subscription failure, finalizer timeout, repeat enable, and namespace/resource ownership.
- [ ] Run the branch workflow and operator-only live smoke test.

### Task 12: `feature/registry-v2`

**Files:** Create `src/aap_demo/addons/registry.py` and `tests/unit/test_registry_addon.py`; modify registry/docs.

- [ ] Port namespace, registry deployment/service/route, CRC trust configuration, and delete behavior through the existing SSH helper.
- [ ] Test route discovery, insecure-registry configuration, SSH failure, repeat enable, and cleanup without touching external registries.
- [ ] Run the branch workflow and image push/pull smoke test.

### Task 13: `feature/setup-pah-v2`

**Files:** Create `src/aap_demo/addons/setup_pah.py` and `tests/unit/test_setup_pah_addon.py`; modify registry/docs.

- [ ] Port Private Automation Hub remote/credential configuration, token-file handling, prompts/config options, status, and cleanup semantics.
- [ ] Test token from environment/file/keyring, absent token, failed API update, idempotent reconfigure, and secret-safe output.
- [ ] Run the branch workflow and PAH configuration smoke test with a disposable credential.

### Task 14: `feature/subscription-attach-v2`

**Files:** Create `src/aap_demo/addons/subscription_attach.py` and `tests/unit/test_subscription_attach_addon.py`; modify registry/docs.

- [ ] Port subscription manifest/secret attachment and cleanup using the existing subscription and config helpers.
- [ ] Test existing subscription, invalid manifest, repeated attach, secret redaction, and delete scope.
- [ ] Run the branch workflow and subscription attachment smoke test.

### Task 15: `feature/product-demos-base-v2`

**Files:** Create `src/aap_demo/addons/product_demos_base.py` and `tests/unit/test_product_demos_base_addon.py`; modify registry/docs.

- [ ] Port the base project, execution environment, credentials, Galaxy configuration, and state contract from `addons/product-demos-base`.
- [ ] Test credential wiring, missing Galaxy token, project sync failure, repeat enable, and cleanup preserving user-provided credentials.
- [ ] Run the branch workflow and verify the base project/EE in AAP.

### Task 16: `feature/product-demos-v2`

**Files:** Create `src/aap_demo/addons/product_demos.py` and `tests/unit/test_product_demos_native_addon.py`; modify registry/docs.

**Depends on:** `product-demos-base-v2`.

- [ ] Port domain selection, upstream ref/repository options, job-template creation, partial-install reporting, and base-addon dependency state.
- [ ] Test selected domains, failed domain retry, upstream ref override, repeat enable, and cleanup limited to APD resources.
- [ ] Run the branch workflow and the full product-demos live smoke test.

### Tasks 17–22: Product-demo domain branches

Create one branch and one native module/test module for each of `product-demo-cloud`,
`product-demo-linux`, `product-demo-network`, `product-demo-openshift`,
`product-demo-satellite`, and `product-demo-windows`:

- [ ] Branch names: `feature/product-demo-cloud-v2`, `feature/product-demo-linux-v2`, `feature/product-demo-network-v2`, `feature/product-demo-openshift-v2`, `feature/product-demo-satellite-v2`, and `feature/product-demo-windows-v2`.
- [ ] Register exactly one canonical addon per branch and preserve its existing APD playbook selection, extra vars, credentials, and cleanup semantics.
- [ ] Test that the domain automatically requires/records `product-demos-base`, handles domain-specific prerequisites and failure retry, and never deletes another domain’s AAP objects.
- [ ] Run focused tests, the full checks, and that domain’s live smoke test independently before opening each PR.

**Depends on:** `product-demos-base-v2`; use `product-demos-v2` as an additional dependency where the native implementation centralizes domain selection.

### Task 23: Deferred AO-family tracking

**Files:** Create a tracking note under `docs/superpowers/evidence/` only after Adam publishes the AO V2 interface; do not modify AO code in this migration series.

- [ ] Verify the merged AO V2 lifecycle/API contract and define the `ao-pr-testing` dependency boundary.
- [ ] Open `feature/ao-pr-testing-v2` only after that contract is stable; port its MCP registration, credentials, workflow, webhook, and cleanup as a separate plan.
- [ ] Keep `ao` and `ao-eap` out of this plan’s implementation branches and test gates.

## Final integration gate

- [ ] Confirm every in-scope branch has an independent PR, signed commits, focused test evidence, and no unrelated addon changes.
- [ ] After all approved branches merge, run the complete Python unit suite and the addon registry/list tests together.
- [ ] Run a clean-install/package test to ensure every native addon is included and no V2 registry entry shells out to a missing legacy script.
- [ ] Update the addon guide and V2 command reference to distinguish native addons from the deferred AO family.
- [ ] Run `make lint-markdown` or the documented Markdown lint command, `python -m pytest tests/unit -q`, Ruff checks, format checks, and `git diff --check` on the integration branch.
