# Low-Resource Automation Orchestrator Replicas Implementation Plan

<!-- markdownlint-disable MD013 -->

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `AO_LOW_RESOURCE=1` mode that configures the operator-managed AutomationOrchestrator custom resource to run its backend, UI, and worker with one replica each, while preserving the current two-replica default.

**Architecture:** Keep replica configuration in the checked-in AutomationOrchestrator CR template and render one validated replica count at deploy time. The addon will apply the CR on both fresh installs and healthy existing-install paths so changing the environment variable reconciles through the operator without directly scaling Deployments or resetting the database. The normal mode renders `2`; low-resource mode renders `1`.

**Tech Stack:** Bash, `sed`, Kubernetes/OpenShift custom resources, OLM-managed Automation Orchestrator, shell regression tests, Markdown ADR documentation.

**Spec:** GitHub issue [#171](https://github.com/RedHatOfficial/aap-demo/issues/171)

## Global Constraints

- The current default remains two replicas for `backend`, `ui`, and `worker`.
- Low-resource mode is opt-in through `AO_LOW_RESOURCE=1`.
- Replica settings must be applied through `kind: AutomationOrchestrator`, never by scaling generated Deployments directly.
- Low-resource mode is intended for development/local clusters and is not HA.
- The resulting AutomationOrchestrator resource must report healthy after reconciliation.
- No secrets, tokens, or pull-secret contents may be committed.

## Review Focus

- Unset or disabled `AO_LOW_RESOURCE` must render all three components with `replicas: 2`; pin this in the rendering test.
- `AO_LOW_RESOURCE=1` must render exactly one replica for backend, UI, and worker; pin all three fields in the rendering test.
- An invalid non-empty value must fail before applying the CR; pin the validation error in the shell test.
- Re-running `aap-demo enable ao` on an existing healthy instance with the mode changed must update the CR without `FORCE=1` or database deletion; cover the fast path in the deployment test plan and live acceptance check.
- The operator may temporarily reconcile after the CR update; the command must wait for `Ready=True` and no degraded condition before reporting success.

---

### Task 1: Record the architecture decision

**Files:**

- Create: `docs/adr/026-low-resource-ao-replicas.md`
- Modify: `docs/adr/README.md`

**Interfaces:**

- Consumes: GitHub issue #171, ADR-008 addon conventions, ADR-017 Automation Orchestrator deployment model, ADR-014 shell testing strategy.
- Produces: ADR-026, a proposed decision that later implementation tasks execute and that links back to issue #171.

- [ ] **Step 1: Create the ADR with the repository template sections.**

  Use `Status: Proposed`, the current date `2026-09-24`, and `aap-demo maintainers` as authors. The context must state that the operator defaults backend, UI, and worker to two replicas, which reserves unnecessary CPU and memory on local CRC/MicroShift clusters. The decision must specify:

  ```text
  AO_LOW_RESOURCE=1 selects one replica for spec.backend.replicas,
  spec.ui.replicas, and spec.worker.replicas. When AO_LOW_RESOURCE is
  unset or disabled, the rendered CR explicitly selects two replicas for
  all three components. The addon applies this CR through kubectl and
  never scales generated Deployments directly.
  ```

  Document that changing the mode on an existing install is done by rerunning `aap-demo enable ao` with the desired environment variable, not by using `FORCE=1`; `FORCE=1` remains the destructive reinstall escape hatch. State that one-replica mode is for development/local clusters and provides no HA redundancy.

- [ ] **Step 2: Document alternatives and consequences.**

  Include these alternatives and reasons:

  - Directly scaling `automation-orchestrator-backend`, UI, and worker Deployments: reject because the operator can overwrite the changes and the CR would no longer be the source of truth.
  - Changing the global default to one replica: reject because it silently reduces availability for existing users and violates issue #171’s default-preservation requirement.
  - Adding a separate manifest file or second addon: reject because a single CR template plus a validated profile keeps the addon surface small and makes the mode reversible.

  Record the positive consequence of lower local resource reservation, the negative consequence of no HA in low-resource mode, and the neutral consequence that the operator still owns reconciliation.

- [ ] **Step 3: Add ADR-026 to the index.**

  Add this row to `docs/adr/README.md`:

  ```markdown
  | [026](026-low-resource-ao-replicas.md) | Low-Resource Automation Orchestrator Replicas | Proposed |
  ```

- [ ] **Step 4: Check the ADR for scope and source coverage.**

  Run:

  ```bash
  rg -n "TODO|TBD|FIXME|026|AO_LOW_RESOURCE|#171" docs/adr/026-low-resource-ao-replicas.md docs/adr/README.md
  ```

  Expected: the new ADR contains no TODO/TBD/FIXME placeholders, contains issue #171 and the environment-variable contract, and the index contains exactly one ADR-026 row.

- [ ] **Step 5: Commit the ADR separately.**

  ```bash
  git add docs/adr/026-low-resource-ao-replicas.md docs/adr/README.md
  git commit -m "docs(adr): add low-resource AO replica decision"
  ```

### Task 2: Render replica profiles through the AutomationOrchestrator CR

**Files:**

- Create: `addons/ao/lib/replica-profile.sh`
- Modify: `addons/ao/manifests/automationorchestrator-cr.yaml`
- Modify: `addons/ao/deploy.sh:40-75,1153-1165,1260-1305`

**Interfaces:**

- Consumes: `AO_LOW_RESOURCE` from the environment; the existing `deploy_ao_instance()` and healthy-instance skip path.
- Produces: a validated `AO_REPLICA_COUNT` value and a rendered CR with explicit backend/UI/worker replica fields.

- [ ] **Step 1: Add explicit replica placeholders to the CR template.**

  In `addons/ao/manifests/automationorchestrator-cr.yaml`, add this under `spec` after the existing image-pull-secret block:

  ```yaml
  backend:
    replicas: __AO_REPLICA_COUNT__
  ui:
    replicas: __AO_REPLICA_COUNT__
  worker:
    replicas: __AO_REPLICA_COUNT__
  ```

  Keep the placeholder as an unquoted YAML integer so the API receives a number rather than a string.

- [ ] **Step 2: Add strict profile validation in `addons/ao/lib/replica-profile.sh`.**

  Create the shared helper and add this function:

  ```bash
  ao_resolve_replica_count() {
    case "${AO_LOW_RESOURCE:-}" in
      ""|0|false)
        printf '2\n'
        ;;
      1|true)
        printf '1\n'
        ;;
      *)
        echo "ERROR: AO_LOW_RESOURCE must be unset, 0, false, 1, or true" >&2
        return 1
        ;;
    esac
  }
  ```

  Source this helper from `addons/ao/deploy.sh`. Resolve the value only on the install/reconcile path, after the delete action has been handled, so an unrelated invalid environment value cannot prevent `aap-demo disable ao`. Store the result in `AO_REPLICA_COUNT` before the first CR apply.

- [ ] **Step 3: Substitute the replica count only while applying the CR.**

  Extend the existing `sed` pipeline in `deploy_ao_instance()` with:

  ```bash
  -e "s|__AO_REPLICA_COUNT__|${AO_REPLICA_COUNT}|g" \
  ```

  Do not add `kubectl scale`, Deployment patches, or post-apply replica mutations. Emit a concise line such as `AO replica profile: 1 each (low-resource, non-HA)` when the count is `1`, and `AO replica profile: 2 each (default)` otherwise.

- [ ] **Step 4: Apply the selected CR on the existing healthy-instance path.**

  In the current `if [ -z "$FORCE" ]` fast path, after the instance is confirmed healthy and before the success message, call `deploy_ao_instance()` with `FORCE` still empty. This lets users switch between profiles without database reset. Extract the existing wait logic into a reusable `wait_for_ao_instance_ready()` function, and call it from both the fresh-install path and the profile-change path so both wait for `Ready=True` and reject `Degraded=True`.

  The success condition must query the existing CR:

  ```bash
  kubectl get automationorchestrator automation-orchestrator \
    -n "$NAMESPACE" \
    -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}'
  ```

  and require `True`, while the existing degraded-condition check remains false. Keep the existing route/pod checks as supplemental diagnostics, not as a replacement for CR health.

- [ ] **Step 5: Verify the CR-only behavior in source.**

  Run:

  ```bash
  rg -n "AO_LOW_RESOURCE|AO_REPLICA_COUNT|spec:|backend:|ui:|worker:|kubectl scale|patch deployment" addons/ao/deploy.sh addons/ao/manifests/automationorchestrator-cr.yaml
  ```

  Expected: the three replica fields occur in the CR template, `AO_LOW_RESOURCE` is validated and substituted, and no new direct Deployment scaling is introduced for AO replicas.

- [ ] **Step 6: Commit the implementation contract.**

  ```bash
  git add addons/ao/deploy.sh addons/ao/manifests/automationorchestrator-cr.yaml
  git commit -m "feat(ao): add low-resource replica profile"
  ```

### Task 3: Add non-destructive regression coverage

**Files:**

- Create: `test/test-ao-replica-profile.sh`
- Modify: `test/README.md`

**Interfaces:**

- Consumes: `addons/ao/lib/replica-profile.sh`, the CR template, and the deploy script’s CR rendering behavior.
- Produces: fast shell coverage for default, opt-in, invalid-input, and CR-only rendering behavior.

- [ ] **Step 1: Write the profile test cases.**

  Source `addons/ao/lib/replica-profile.sh` and run the production helper without a cluster. Assert:

  ```bash
  AO_LOW_RESOURCE= ao_resolve_replica_count  # prints 2
  AO_LOW_RESOURCE=1 ao_resolve_replica_count # prints 1
  AO_LOW_RESOURCE=true ao_resolve_replica_count # prints 1
  AO_LOW_RESOURCE=unexpected ao_resolve_replica_count # exits non-zero and prints validation error
  ```

  Do not duplicate a second production implementation in the test. Render temporary copies of `automationorchestrator-cr.yaml` using the same `sed` replacement contract as `deploy_ao_instance()`, then assert all three paths with exact YAML matches:

  ```bash
  grep -c '^    replicas: 2$' "$rendered"  # expected 3 for default
  grep -c '^    replicas: 1$' "$rendered"  # expected 3 for low-resource
  ```

- [ ] **Step 2: Test that the rendered values live in the CR.**

  Assert that the rendered file contains `kind: AutomationOrchestrator`, all three component keys, and no `kubectl scale` or Deployment replica patch command is required by the test path. This protects the issue’s operator-source-of-truth requirement.

- [ ] **Step 3: Register and document the test.**

  Add the executable test to the AO test list in `test/README.md`, explain that it is non-destructive, and run:

  ```bash
  chmod +x test/test-ao-replica-profile.sh
  ./test/test-ao-replica-profile.sh
  ```

  Expected: all default, low-resource, invalid-input, and CR-rendering assertions pass.

- [ ] **Step 4: Commit the regression coverage.**

  ```bash
  git add test/test-ao-replica-profile.sh test/README.md
  git commit -m "test(ao): cover replica profile rendering"
  ```

### Task 4: Document the opt-in mode for local users

**Files:**

- Modify: `addons/ao/README.md`
- Modify: `docs/FULL-README.md` only if the project’s global environment-variable section is intended to list addon-specific variables

**Interfaces:**

- Consumes: the `AO_LOW_RESOURCE=1` contract from ADR-026 and the deploy behavior from Task 2.
- Produces: user-facing instructions that make the availability tradeoff and reversible workflow explicit.

- [ ] **Step 1: Add the environment variable to the AO README table.**

  Add:

  ```markdown
  | `AO_LOW_RESOURCE` | unset | Set to `1`/`true` for one backend, UI, and worker replica; development/local only, not HA |
  ```

- [ ] **Step 2: Add enable, switch, and revert examples.**

  Document:

  ```bash
  AO_LOW_RESOURCE=1 aap-demo enable ao  # 1 backend, 1 UI, 1 worker; non-HA
  AO_LOW_RESOURCE=0 aap-demo enable ao  # restore the default 2 each
  aap-demo enable ao                    # default is 2 each when unset
  ```

  State that this applies the `AutomationOrchestrator` custom resource, preserves the database, and waits for the resource to become healthy. State that `FORCE=1` is not required to change replica mode and remains a reinstall/reset path.

- [ ] **Step 3: Add a capacity note.**

  Explain that one-replica mode reduces reserved CPU/memory and redundancy; it is appropriate for CRC/MicroShift development and demos, not production or HA validation.

- [ ] **Step 4: Commit the documentation.**

  ```bash
  git add addons/ao/README.md docs/FULL-README.md
  git commit -m "docs(ao): document low-resource replica mode"
  ```

### Task 5: Verify the branch and live acceptance criteria

**Files:**

- Verify: all files from Tasks 1–4

**Interfaces:**

- Consumes: the completed ADR, CR rendering, regression test, and user documentation.
- Produces: evidence that the branch is clean, tests pass, and issue #171’s live behavior is satisfied when a disposable cluster is available.

- [ ] **Step 1: Run fast local verification.**

  ```bash
  bash -n addons/ao/deploy.sh test/test-ao-replica-profile.sh
  ./test/test-ao-replica-profile.sh
  make test
  ```

  Expected: syntax checks, profile tests, and dry-run CLI checks pass.

- [ ] **Step 2: Run repository linting for touched content.**

  ```bash
  shellcheck addons/ao/deploy.sh test/test-ao-replica-profile.sh
  markdownlint docs/adr/026-low-resource-ao-replicas.md addons/ao/README.md docs/adr/README.md test/README.md
  yamllint addons/ao/manifests/automationorchestrator-cr.yaml
  ```

  Expected: no new shell, Markdown, or YAML findings.

- [ ] **Step 3: Run live acceptance on a disposable local cluster.**

  ```bash
  AO_LOW_RESOURCE=1 aap-demo enable ao
  kubectl get automationorchestrator automation-orchestrator -n automation-orchestrator -o yaml
  ```

  Confirm the CR contains `backend.replicas: 1`, `ui.replicas: 1`, and `worker.replicas: 1`, and that its `Ready` condition is `True` with no `Degraded=True` condition. Then restore the default without reinstalling:

  ```bash
  AO_LOW_RESOURCE=0 aap-demo enable ao
  kubectl get automationorchestrator automation-orchestrator -n automation-orchestrator -o yaml
  ```

  Confirm all three fields return to `2`, the PostgreSQL cluster and admin secret remain intact, and the resource again reports healthy. Record any operator-version-specific status shape in ADR-026’s references rather than weakening the CR source-of-truth rule.

- [ ] **Step 4: Review the final diff and branch state.**

  ```bash
  git diff origin/main...HEAD --check
  git diff --stat origin/main...HEAD
  git status --short --branch
  ```

  Expected: no whitespace errors, only the ADR/implementation/test/documentation files are changed, and the branch is clean after commits.
