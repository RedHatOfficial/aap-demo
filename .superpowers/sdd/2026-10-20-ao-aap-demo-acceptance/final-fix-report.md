# AO/AAP-Demo Acceptance Final Fix Report

Date: 2026-10-20

## Status

The whole-branch review findings are addressed. The default acceptance manifest
is success-capable using repository-owned, read-only representatives; unsafe
operations remain opt-in and non-launchable by default. No live cluster was
contacted during this fix wave, so the first environment-backed acceptance run
remains operational evidence rather than a code-completion requirement.

## Review finding closure

### 1. Success-capable default suite

- Added immutable repository-owned read-only playbooks for AO and Product
  Demos, each with deterministic execution markers and a bounded optional
  pause used for EE inspection.
- Provisioned safe, credentialless job templates and local AO workflows that
  demonstrate AO wiring, an AO-backed AAP job, Product Demos, and authenticated
  MCP behavior.
- Replaced the blocked default manifest with four executable safe scenarios.
- Moved certificate, disk, installer, and ServiceNow demonstrations to
  `unsafe-operations.json`; they remain explicitly blocked until an operator
  opts in and supplies environment-specific contracts.

### 2. Secret-safe failure artifacts

- Replaced raw API, job, event, probe, and HTTP payload persistence with
  explicit diagnostic field allowlists.
- Omitted free-form `stdout` and `output` from persisted diagnostics.
- Added synthetic tests proving unlabeled secrets embedded in nested API, job,
  event, and HTTP payloads do not reach artifacts.

### 3. Authenticated MCP and CA-aware probes

- Added an MCP JSON-RPC client for authenticated `tools/list` and read-only
  `tools/call` requests.
- Readiness now proves authenticated MCP behavior rather than an unauthenticated
  HTTP GET.
- In-pod probes carry bearer tokens and CA data over standard input, not
  process arguments, and support the configured in-cluster CA.
- Security checks cover the AAP task pod, relevant AO backend/worker contexts,
  and every managed EE through a real acceptance job pod.

### 4. Real managed EE representatives

- Every managed EE must map to an exact safe representative; unknown or
  unrepresented EEs fail as contract drift.
- EE checks validate exact project URL, playbook, immutable full revision, and
  image identity, then launch the safe representative and identify its pod by
  the official AWX job label.
- The resulting AAP job must report the expected execution environment, and
  authenticated MCP `tools/list` must work from that job pod.

### 5. Addon-aligned wiring

- Safe job templates are intentionally credentialless and no longer fail a
  generic credential requirement.
- Wiring validates the expected repository, full immutable revision,
  playbook, execution environment, and prompt-on-launch contract.
- AO checks validate the effective AAP and MCP integrations and credentials
  provisioned by the addon rather than inferred mutable names.

### 6. Preparation ordering and freshness

- Preparation order is now aap-demo, minimal deterministic Product Demos
  Linux content, then AO.
- A failed Product Demos preparation stops before managed checks or workflow
  execution.
- Revalidation replaces stale preflight target results rather than retaining
  contradictory status.
- Product Demos projects are pinned to their observed full installed revision,
  with update-on-launch disabled before AO representatives are derived.

### 7. CI discovery

- Added a discovery-safe loader that imports the existing hyphenated acceptance
  suites, so `unittest discover` executes the full Python acceptance suite.
- CI runs discovery plus the provisioning contract test.

### 8. Approved-context diagnostics

- Diagnostic collection is gated on `target_approved`. A context mismatch or
  other context-approval failure cannot query the currently active cluster.

### 9. Secondary issues

- Durations now use monotonic elapsed time instead of fixed zero values.
- Task 6 has a final amendment identifying earlier blocked-default text as
  historical.
- Added dedicated Product Demos readiness coverage and cleared the deferred
  ledger item.

## Principal implementation areas

- `.github/workflows/test.yaml`
- `addons/ao/deploy.sh`
- `addons/ao/playbooks/acceptance-read-only.yml`
- `addons/ao/playbooks/sync-ao-demos.yml`
- `addons/ao/playbooks/tasks/sync_acceptance_workflow.yml`
- `addons/ao/scripts/provision-aap-demos.py`
- `addons/product-demos-base/deploy.sh`
- `addons/product-demos-base/lib.sh`
- `addons/product-demos-base/playbooks/acceptance-read-only.yml`
- `test/ao-acceptance/`
- `test/ao_acceptance_discovery/test_acceptance.py`
- `test/test-ao-acceptance-*.py`
- `test/test-ao-acceptance-provisioning.sh`
- `test/test-provision-aap-demos.py`

## TDD evidence

Regression tests were added before or alongside each correction and observed
failing against the reviewed behavior. Coverage includes success-capable
manifest contracts, unlabeled-secret suppression, authenticated MCP requests,
stdin token/CA transport, per-EE representatives, exact immutable wiring,
Product Demos preparation failure, stale-result replacement, diagnostic context
gating, real durations, and discovery execution.

## Verification evidence

- Explicit acceptance suite: 123 tests passed.
- Discovery acceptance suite: all discovered acceptance tests passed.
- Acceptance CLI and provisioning shell contracts passed.
- Product Demos API, project-sync, and overlay tests passed.
- AO MCP integration and LLM workflow-binding tests passed.
- AO provisioning and demo-import Python tests passed.
- All repository shell files passed `bash -n`; changed shell files passed
  ShellCheck and shfmt.
- Changed YAML passed yamllint. Changed Ansible content passed the production
  ansible-lint profile with zero failures and zero warnings.
- Changed Python compiled successfully; scenario manifests passed `json.tool`.
- Markdown lint, whitespace checks, and commit hooks passed.

## Remaining concern

The implementation is verified locally with synthetic and contract tests, but
this fix wave did not contact a live cluster. The first live acceptance run must
therefore confirm the deployed operator/API versions expose the exact observed
resource fields and that cluster policy permits the bounded in-pod MCP probes.
