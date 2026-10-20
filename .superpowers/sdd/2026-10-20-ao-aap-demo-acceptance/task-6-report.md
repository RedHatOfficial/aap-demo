# Task 6 Report — AO Critical-Path Scenario Execution

## Result

Implemented scenario manifest parsing, pre-launch contract validation, bounded
AO/AAP polling, AAP job-event completion markers, and runner integration for
the four critical-path scenarios.

Commit: `c8e7a4a test: execute critical AO acceptance workflows`

## Files

- `test/ao-acceptance/scenarios/critical-path.json` — four bounded scenarios:
  AO wiring, AAP-backed certificate workflow, Product Demos read-only
  diagnostic, and MCP smoke operation.
- `test/ao-acceptance/scenarios.py` — strict JSON manifest loading and
  `Scenario` contract validation.
- `test/ao-acceptance/checks/workflows.py` — all-or-nothing contract
  resolution, single workflow launch, AO/AAP polling, linked-job discovery,
  job-event marker validation, and classified failures.
- `test/ao-acceptance/runner.py` — manifest loading before any live launch;
  malformed manifests, failed managed validation, and contract drift prevent
  workflow and EE execution.
- `test/test-ao-acceptance-workflows.py` — coverage for malformed/duplicate
  manifests, unknown workflows, AO and AAP failures, timeouts, job-event
  markers, missing markers, resource IDs in failures, and launch safety.
- `test/test-ao-acceptance-runner.py` — updated runner contract assertion for
  the loaded scenario set.

## TDD Evidence

- Initial focused run failed as expected because `scenarios` did not yet
  exist (`ModuleNotFoundError`).
- The managed-validation safety test failed before the runner gate existed:
  `workflows.run` was called after a failed security result.
- The timeout regression failed before polling retained the last AO payload,
  so the linked AAP job ID was absent from the failure result.
- The job-event marker regression failed before job events were read through
  the existing AAP client.

## Tests and Output

Final focused suite:

```text
python3 -m unittest test/test-ao-acceptance-workflows.py -v
Ran 11 tests in 0.003s
OK
```

Task 1-5 regression set plus Task 6:

```text
python3 -m unittest test/test-ao-acceptance-runner.py \
  test/test-ao-acceptance-environment.py \
  test/test-ao-acceptance-clients.py \
  test/test-ao-acceptance-checks.py \
  test/test-ao-acceptance-ee-security.py \
  test/test-ao-acceptance-workflows.py -v
Ran 80 tests in 0.232s
OK
```

Also passed:

```text
python3 -m py_compile test/ao-acceptance/scenarios.py \
  test/ao-acceptance/checks/workflows.py test/ao-acceptance/runner.py
python3 -m json.tool test/ao-acceptance/scenarios/critical-path.json
git diff --check
```

The commit hooks passed whitespace, end-of-file, YAML, merge-conflict,
case-conflict, branch, commit-message, and secret-detection checks.

## Self-Review

- Manifest parsing completes before `run_managed_checks`; malformed and
  duplicate manifests cannot initiate an AO or AAP launch.
- Every scenario reference is resolved against the managed inventory before
  any scenario launch. Missing workflows, templates, or workflow-template
  links become `contract_drift` results.
- Each workflow launch happens once only; no implicit retry path exists.
- AO and AAP failures, timeouts, event-read failures, and missing markers
  retain the scenario ID, workflow ID, declared template IDs, and observed
  job IDs.
- Managed readiness, wiring, or security failures block all workflow and EE
  launches. Contract drift blocks EE launches as well.
- AAP job events are read only after terminal job success to check declared
  markers through the existing client boundary. Errors are redacted before
  being placed in results.
- Author self-review only; no reviewer was spawned, as required by the task.

## Concerns

- No live cluster was contacted. The first opt-in run will validate the AO
  execution payload's linked-job field names and the four upstream workflow
  completion markers; any mismatch is designed to report as contract drift or
  execution evidence rather than silently pass.

## Fix Round 1 (2026-10-20)

### Commit

- `70add3f test: harden AO workflow acceptance contracts`

### Files changed

- `test/ao-acceptance/scenarios/critical-path.json` — replaces the invented
  Product Demos diagnostic and unsafe default executions with four explicit,
  addon-provisioned contracts. Certificate renewal, disk remediation, Product
  Demos installation, and ServiceNow auto-remediation are all non-launchable
  and report `BLOCKED`/`contract_drift` until safe representatives exist.
- `test/ao-acceptance/scenarios.py` — requires launch/read-only intent,
  an explicit blocked reason for unsafe contract-only scenarios, and declared
  execution-evidence fields when success markers are used.
- `test/ao-acceptance/checks/workflows.py` — resolves each declared template
  name to its deployment-local ID, validates exact workflow and runtime
  ID/name allowlists, uses one monotonic scenario deadline across AO and AAP
  polling, and restricts marker matching to declared output/result fields.
- `test/test-ao-acceptance-workflows.py` — adds contract-only launch-safety,
  absent/unapproved link, exact graph, shared-deadline, and execution-evidence
  marker tests.
- `test/test-ao-acceptance-runner.py` — updates the default scenario contract
  assertion.

### TDD evidence

The initial focused run after adding the four review-regression tests failed
as expected: unsafe launch validation, runtime unexpected-link validation,
shared deadline handling, and metadata-only marker matching were all absent.
After implementation, the focused suite passed with the added regression
coverage.

### Tests and output

```text
python3 -m unittest test/test-ao-acceptance-workflows.py -v
Ran 20 tests in 0.004s
OK

python3 -m unittest test/test-ao-acceptance-runner.py \
  test/test-ao-acceptance-environment.py \
  test/test-ao-acceptance-clients.py \
  test/test-ao-acceptance-checks.py \
  test/test-ao-acceptance-ee-security.py \
  test/test-ao-acceptance-workflows.py -v
Ran 89 tests in 0.228s
OK

python3 -m py_compile test/ao-acceptance/scenarios.py \
  test/ao-acceptance/checks/workflows.py test/ao-acceptance/runner.py
python3 -m json.tool test/ao-acceptance/scenarios/critical-path.json
git diff --check
```

Commit hooks also passed whitespace, EOF, merge-conflict, branch,
commit-message, and secret-detection checks.

### Self-review

- No default manifest scenario can launch: every currently provisioned
  representative is operational or mutating, so the contract explicitly
  blocks it rather than treating configuration names as a pass path.
- Static template names are resolved through the existing managed inventory
  into deployment-local IDs; both the workflow graph and each AO-reported
  linked AAP job must match the exact declared `(id, name)` allowlist. Missing
  or unexpected links fail as `contract_drift` before AAP job polling.
- One monotonic deadline is created per launched scenario and reused for AO
  polling, each linked AAP job, and marker-event collection. No retry loop was
  introduced.
- Marker text is read only from each scenario's declared terminal execution
  evidence fields (`stdout`, `output`, or `result` by default), never from
  workflow/template/configuration metadata.
- Existing redaction boundaries remain used for API errors; no secret values
  are added to results. Author self-review only, as instructed.

### Concerns

- The default four scenarios are intentionally blocked until the addons
  provision demonstrably read-only AO/Product Demos representatives. A live
  run therefore reports a clear contract outcome instead of launching disk,
  cleanup/expansion, certificate renewal, or ServiceNow remediation.
- No live cluster was contacted; live AO payload field variations that omit
  job-template identity will safely report `contract_drift` before job
  acceptance.

## Fix Round 2 (2026-10-20)

### Changes

- Replaced invented default workflow names with the names imported from pinned
  `abcc1a1482a`: `Cert Demo 101 - Manual Reactive Renewal`, the nameless
  disk export's importer fallback `disk-demo-101`, and `ServiceNow Incident -
  AI Triage and Response`. Each remains non-launchable with an explicit
  contract-only reason.
- Restored recursive discovery of `job_ids` and `aap_job_ids`, alongside
  `jobs` and `aap_jobs`. Every discovered linked ID is retained in the result
  and fails `contract_drift` before AAP polling when it lacks an approved
  template allowlist or template identity.
- Restricted manifest `success_marker_fields` to `stdout`, `output`,
  `result`, and `status`. Runtime marker matching applies the same allowlist,
  so metadata fields cannot become execution evidence.

### TDD evidence

The new focused tests initially failed on the unparsed `job_ids` and
`aap_job_ids`, the unvalidated `workflow_name` marker field, and the three
invented default workflow names. They passed after the targeted changes.

### Tests and checks

```text
python3 -m unittest test/test-ao-acceptance-workflows.py -v
Ran 23 tests in 0.004s
OK

python3 -m unittest test/test-ao-acceptance-runner.py \\
  test/test-ao-acceptance-environment.py \\
  test/test-ao-acceptance-clients.py \\
  test/test-ao-acceptance-checks.py \\
  test/test-ao-acceptance-ee-security.py \\
  test/test-ao-acceptance-workflows.py -v
Ran 92 tests in 0.239s
OK

python3 -m py_compile test/ao-acceptance/scenarios.py \\
  test/ao-acceptance/checks/workflows.py test/ao-acceptance/runner.py
python3 -m json.tool test/ao-acceptance/scenarios/critical-path.json
git diff --check
```

### Concerns

- No live cluster was contacted. The default scenarios remain safely blocked;
  a live runtime payload that supplies only bare linked IDs is deliberately
  classified as `contract_drift` rather than polled without an identity-backed
  allowlist.
