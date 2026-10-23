<!-- markdownlint-disable MD013 -->

# AO/AAP-Demo Live Acceptance Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an opt-in live acceptance harness that validates the AAP-Demo core, AO, MCP, Product Demos, wiring, security connections, and every repository-managed execution environment on a live cluster.

**Architecture:** A shell entry point delegates to a Python runner composed of small environment, API-client, check, scenario, and artifact modules. The runner supports `auto`, `provision`, and `validate` modes, inventories repository-managed AAP resources, runs focused checks, executes representative EE jobs and AO workflows, and emits redacted machine-readable and human-readable results.

**Tech Stack:** Bash, Python 3 standard library, `kubectl`, AAP REST API, AO REST API, JSON scenario manifests, `unittest`, and the repository’s existing shell-test conventions.

**Spec:** `docs/superpowers/specs/2026-10-20-ao-aap-demo-acceptance-design.md`

## Global Constraints

- The first target is manual or dedicated self-hosted live testing; GitHub-hosted lifecycle testing is out of scope.
- `auto` must reuse a healthy AAP-Demo/AO environment and provision only missing prerequisites.
- `validate` must never provision or mutate addons.
- The default run must preserve the cluster after failures; cleanup is explicit.
- “All supported execution environments” means every EE referenced by AAP-Demo-managed job templates.
- Tokens, passwords, API keys, and other secrets must never appear in logs or artifacts.
- Live acceptance tests are opt-in; existing fast tests must remain cluster-independent.
- Use unique, clearly prefixed test names and avoid destructive jobs by default.

## Review Focus

- A healthy existing cluster must not be reprovisioned in `auto` or `validate`; test mode detection and command invocation with mocked subprocesses in Task 2.
- A target-context mismatch or missing credential must fail before any mutating command; test fail-closed preflight behavior in Task 2.
- API failures, expired tokens, and malformed JSON must become classified check failures rather than uncaught tracebacks; test client behavior in Task 3.
- A managed job template referencing an untested or unavailable EE must fail as contract drift; test inventory and coverage enforcement in Task 5.
- Diagnostic collection must not write secrets even when API responses or pod logs contain them; test redaction and fail-closed omission in Task 7.

### Task 1: Scaffold the acceptance runner and result contracts

**Files:**

- Create: `test/ao-acceptance/run.sh`
- Create: `test/ao-acceptance/runner.py`
- Create: `test/ao-acceptance/model.py`
- Create: `test/ao-acceptance/__init__.py`
- Create: `test/test-ao-acceptance-runner.py`

**Interfaces:**

- `model.CheckStatus`: `PASS`, `FAIL`, `SKIP`, `BLOCKED` string enum values.
- `model.FailureClass`: `prerequisite`, `wiring`, `execution`, `timeout`, `contract_drift` string enum values.
- `model.CheckResult`: dataclass with `check_id: str`, `component: str`, `status: CheckStatus`, `failure_class: FailureClass | None`, `summary: str`, `started_at: str`, `finished_at: str`, `duration_seconds: float`, and `details: dict[str, object]`.
- `model.RunConfig`: dataclass with `mode: str`, `namespace: str`, `artifact_dir: pathlib.Path`, `context: str | None`, `scenario_file: pathlib.Path`, `timeout_seconds: int`, and `dry_run: bool`.
- `runner.parse_args(argv: list[str]) -> RunConfig`.
- `runner.main(argv: list[str]) -> int`.

- [ ] **Step 1: Write failing tests for CLI and result serialization.**

  Cover `--mode auto|provision|validate`, `--namespace`, `--context`, `--artifact-dir`, `--scenario-file`, `--timeout`, `--dry-run`, invalid modes, and default values. Assert that a `CheckResult` serializes to JSON without changing enum values or timestamps.

- [ ] **Step 2: Run the focused tests and verify they fail.**

  Run: `python3 -m unittest test/test-ao-acceptance-runner.py -v`

  Expected: FAIL because the acceptance package and contracts do not exist.

- [ ] **Step 3: Implement the contracts and shell entry point.**

  Make `run.sh` resolve the repository root, exec `python3 test/ao-acceptance/runner.py "$@"`, and preserve the Python exit code. Make the runner parse arguments, create a run-level result container, and return `0` only when no check is `FAIL` or `BLOCKED`.

- [ ] **Step 4: Run the focused tests and verify they pass.**

  Run: `python3 -m unittest test/test-ao-acceptance-runner.py -v`

- [ ] **Step 5: Commit the scaffold.**

  ```bash
  git add test/ao-acceptance test/test-ao-acceptance-runner.py
  git commit -m "test: scaffold AO live acceptance runner"
  ```

### Task 2: Add target detection, preflight, and execution modes

**Files:**

- Create: `test/ao-acceptance/environment.py`
- Modify: `test/ao-acceptance/runner.py`
- Modify: `test/ao-acceptance/model.py`
- Create: `test/test-ao-acceptance-environment.py`

**Interfaces:**

- `environment.CommandRunner.run(args: list[str], *, check: bool = False, timeout: int = 60) -> CommandResult`.
- `environment.TargetInspector.current_context() -> str`.
- `environment.TargetInspector.aap_demo_ready() -> bool`.
- `environment.TargetInspector.ao_ready() -> bool`.
- `environment.TargetInspector.required_addons_ready() -> dict[str, bool]`.
- `environment.validate_target(config: RunConfig, inspector: TargetInspector) -> list[CheckResult]`.
- `environment.prepare_target(config: RunConfig, runner: CommandRunner) -> list[CheckResult]`.

- [ ] **Step 1: Write failing tests for mode behavior.**

  Mock `kubectl config current-context`, `kubectl get`, and `aap-demo` commands. Assert that `validate` never calls `aap-demo deploy` or `aap-demo enable`; `auto` skips mutating commands when AAP-Demo, AO, MCP, and Product Demos are ready; `provision` invokes `aap-demo deploy`, `aap-demo enable ao`, and `aap-demo enable product-demos` in order; and a context mismatch blocks before mutation.

- [ ] **Step 2: Run the focused tests and verify they fail.**

  Run: `python3 -m unittest test/test-ao-acceptance-environment.py -v`

- [ ] **Step 3: Implement command execution and target inspection.**

  Use `subprocess.run` with captured text, explicit timeouts, and no shell interpolation. Detect readiness through existing AAP-Demo namespaces/resources and `kubectl wait`/JSON output. Treat missing resources as data for `auto`, but as a prerequisite failure for `validate`.

- [ ] **Step 4: Wire mode handling into the runner.**

  Perform target validation first, then call `prepare_target` only for `auto` with missing prerequisites or `provision`. Stop before mutation on any explicit-context or credential preflight failure.

- [ ] **Step 5: Run the focused tests and verify they pass.**

  Run: `python3 -m unittest test/test-ao-acceptance-environment.py -v`

- [ ] **Step 6: Commit the mode implementation.**

  ```bash
  git add test/ao-acceptance test/test-ao-acceptance-environment.py
  git commit -m "test: add AO acceptance target modes"
  ```

### Task 3: Implement authenticated AAP/AO clients and redaction

**Files:**

- Create: `test/ao-acceptance/clients/__init__.py`
- Create: `test/ao-acceptance/clients/http.py`
- Create: `test/ao-acceptance/clients/aap.py`
- Create: `test/ao-acceptance/clients/ao.py`
- Create: `test/ao-acceptance/redaction.py`
- Create: `test/test-ao-acceptance-clients.py`

**Interfaces:**

- `http.ApiError`: exception with `method`, `url`, `status`, and redacted `body`.
- `http.JsonClient.request(method: str, path: str, *, payload: dict | None = None, timeout: int = 60) -> dict`.
- `aap.AapClient.get(path: str) -> dict`, `aap.AapClient.list_all(path: str) -> list[dict]`, `aap.AapClient.launch_job_template(template_id: int, extra_vars: dict | None = None) -> int`, and `aap.AapClient.job_status(job_id: int) -> dict`.
- `ao.AoClient.get(path: str) -> dict`, `ao.AoClient.list_all(path: str) -> list[dict]`, `ao.AoClient.launch_workflow(workflow_id: str, inputs: dict | None = None) -> str`, and `ao.AoClient.workflow_status(execution_id: str) -> dict`.
- `redaction.redact(value: object) -> object`.
- `redaction.redact_text(text: str) -> str`.

- [ ] **Step 1: Write failing tests for API and redaction contracts.**

  Mock successful JSON responses, non-2xx responses, invalid JSON, connection failures, pagination, and polling payloads. Assert that authorization headers, keys named `token`, `password`, `secret`, `api_key`, and bearer-token patterns are replaced before exceptions or artifacts expose them.

- [ ] **Step 2: Run the focused tests and verify they fail.**

  Run: `python3 -m unittest test/test-ao-acceptance-clients.py -v`

- [ ] **Step 3: Implement the redactor and shared JSON client.**

  Use `urllib.request` from the standard library, pass CA and token configuration explicitly, redact request/response diagnostics, and raise `ApiError` with bounded response text. Do not log headers or raw payloads.

- [ ] **Step 4: Implement AAP and AO resource clients.**

  Add pagination handling through `next` links, normalize API list responses, launch only by numeric/template identifiers resolved by checks, and expose status payloads without printing sensitive fields.

- [ ] **Step 5: Run the focused tests and verify they pass.**

  Run: `python3 -m unittest test/test-ao-acceptance-clients.py -v`

- [ ] **Step 6: Commit the client layer.**

  ```bash
  git add test/ao-acceptance/clients test/ao-acceptance/redaction.py test/test-ao-acceptance-clients.py
  git commit -m "test: add redacted AAP and AO acceptance clients"
  ```

### Task 4: Add readiness, resource inventory, and wiring checks

**Files:**

- Create: `test/ao-acceptance/inventory.py`
- Create: `test/ao-acceptance/checks/__init__.py`
- Create: `test/ao-acceptance/checks/readiness.py`
- Create: `test/ao-acceptance/checks/wiring.py`
- Modify: `test/ao-acceptance/runner.py`
- Create: `test/test-ao-acceptance-checks.py`

**Interfaces:**

- `inventory.ManagedResourceInventory`: dataclass containing `organizations`, `projects`, `inventories`, `credentials`, `job_templates`, `execution_environments`, `ao_integrations`, and `ao_workflows` lists of dictionaries.
- `inventory.build_inventory(aap: AapClient, ao: AoClient, managed_markers: dict[str, str]) -> ManagedResourceInventory`.
- `checks.readiness.run(inventory: ManagedResourceInventory, probes: ProbeSet) -> list[CheckResult]`.
- `checks.wiring.run(inventory: ManagedResourceInventory) -> list[CheckResult]`.

- [ ] **Step 1: Write failing tests for inventory and wiring contracts.**

  Supply fixture payloads for AAP-Demo-managed organizations, projects, credentials, job templates, and AO integrations/workflows. Assert that unrelated resources are excluded, expected project refs and job-template relationships are retained, and missing integrations, credentials, or workflow bindings produce the correct failure class.

- [ ] **Step 2: Run the focused tests and verify they fail.**

  Run: `python3 -m unittest test/test-ao-acceptance-checks.py -v`

- [ ] **Step 3: Implement inventory construction.**

  Filter by the repository’s stable names/descriptions and addon-managed markers already used by `addons/ao` and `addons/product-demos-base`. Resolve linked IDs into normalized records so later checks do not repeat API lookup logic.

- [ ] **Step 4: Implement readiness and wiring checks.**

  Check AAP/AO/MCP readiness, required projects and job templates, SCM refs, credential presence/type, AO integration endpoints, workflow node bindings, and launch permissions. Return one result per check with a useful resource identifier.

- [ ] **Step 5: Run the focused tests and verify they pass.**

  Run: `python3 -m unittest test/test-ao-acceptance-checks.py -v`

- [ ] **Step 6: Commit inventory and wiring checks.**

  ```bash
  git add test/ao-acceptance/inventory.py test/ao-acceptance/checks test/ao-acceptance/runner.py test/test-ao-acceptance-checks.py
  git commit -m "test: validate AAP-Demo managed wiring"
  ```

### Task 5: Add TLS, identity, token, MCP, and execution-environment checks

**Files:**

- Create: `test/ao-acceptance/checks/security.py`
- Create: `test/ao-acceptance/checks/execution_environments.py`
- Create: `test/ao-acceptance/probes.py`
- Modify: `test/ao-acceptance/checks/__init__.py`
- Create: `test/test-ao-acceptance-ee-security.py`

**Interfaces:**

- `probes.ProbeSet.host_https(url: str) -> ProbeResult`.
- `probes.ProbeSet.host_dns(host: str) -> ProbeResult`.
- `probes.ProbeSet.ee_https(namespace: str, selector: str, url: str) -> ProbeResult`.
- `checks.security.run(inventory: ManagedResourceInventory, probes: ProbeSet) -> list[CheckResult]`.
- `checks.execution_environments.enumerate_supported(inventory: ManagedResourceInventory) -> list[dict]`.
- `checks.execution_environments.run(inventory: ManagedResourceInventory, aap: AapClient, runner: CommandRunner, probes: ProbeSet, *, ao: AoClient) -> list[CheckResult]`. Representative EE execution must launch the named AO workflow mapped to the exact AAP job template; it must not call `AapClient.launch_job_template` directly.

- [ ] **Step 1: Write failing tests for TLS/security and EE coverage.**

  Test trusted HTTPS, DNS failure, certificate failure, host-versus-pod probe results, required user/credential/token metadata, and an inventory with two managed EEs where one lacks a representative job. Assert that an untested EE is `contract_drift`, not `SKIP`.

- [ ] **Step 2: Run the focused tests and verify they fail.**

  Run: `python3 -m unittest test/test-ao-acceptance-ee-security.py -v`

- [ ] **Step 3: Implement host and EE-pod probes.**

  Use `curl`/`kubectl exec` through `CommandRunner` with CA verification enabled. Capture only status, hostname, certificate subject/issuer, and redacted error text. Never add an insecure fallback.

- [ ] **Step 4: Implement security and wiring checks.**

  Validate route trust, route resolution, expected users, credential types, token usability, AO AAP/MCP integration reachability, MCP tool availability, and private-network route behavior required by the addon.

- [ ] **Step 5: Implement managed EE enumeration and representative jobs.**

  Derive EE references from managed job templates, verify expected image/name and availability, map each EE/template pair to a named AO workflow, launch AO, poll AO and its linked AAP job until terminal state, and require success. Fail with explicit contract drift when a managed EE has no matrix entry or AO representative; never launch the AAP template directly.

- [ ] **Step 6: Run the focused tests and verify they pass.**

  Run: `python3 -m unittest test/test-ao-acceptance-ee-security.py -v`

- [ ] **Step 7: Commit security and EE checks.**

  ```bash
  git add test/ao-acceptance/checks test/ao-acceptance/probes.py test/test-ao-acceptance-ee-security.py
  git commit -m "test: validate AO security and execution environments"
  ```

### Task 6: Add scenario manifests and AO workflow execution

**Files:**

- Create: `test/ao-acceptance/scenarios/critical-path.json`
- Create: `test/ao-acceptance/scenarios.py`
- Create: `test/ao-acceptance/checks/workflows.py`
- Modify: `test/ao-acceptance/runner.py`
- Create: `test/test-ao-acceptance-workflows.py`

**Interfaces:**

- `scenarios.Scenario`: dataclass with `scenario_id`, `component`, `workflow_name`, `job_template_names`, `timeout_seconds`, `poll_seconds`, `expected_workflow_states`, `expected_job_states`, and `success_markers`.
- `scenarios.load(path: pathlib.Path) -> list[Scenario]`.
- `checks.workflows.run(scenarios: list[Scenario], inventory: ManagedResourceInventory, ao: AoClient, aap: AapClient) -> list[CheckResult]`.

- [ ] **Step 1: Write failing tests for manifest parsing and workflow polling.**

  Test required manifest fields, duplicate IDs, unknown workflow names, AO success with AAP success, AO failure, AAP failure, timeout, and missing completion markers. Assert that every failure includes the scenario ID and linked resource IDs.

- [ ] **Step 2: Run the focused tests and verify they fail.**

  Run: `python3 -m unittest test/test-ao-acceptance-workflows.py -v`

- [ ] **Step 3: Add the critical-path scenario manifest.**

  Define one AO wiring smoke scenario, one deterministic AAP-backed workflow, one Product Demos workflow, and one AO-mediated MCP workflow using stable names already created by the addons. The MCP workflow must use an agentic node bound to the managed AO MCP integration and a bounded success marker. Set polling and timeout values in the manifest rather than in code.

- [ ] **Step 4: Implement scenario loading and contract validation.**

  Reject malformed or duplicate scenarios before any launch. Resolve names through the inventory and classify missing upstream workflow/job-template changes as `contract_drift`.

- [ ] **Step 5: Implement launch and polling.**

  Launch each selected AO workflow, follow its linked AAP jobs, poll both systems until terminal state or deadline, and check declared success markers. MCP scenarios must also find structured AO evidence naming the declared MCP tool and a result; marker-only text is insufficient. Reject unsupported MCP arguments before provisioning. Do not retry a mutating workflow automatically unless the manifest explicitly marks it idempotent.

- [ ] **Step 6: Run the focused tests and verify they pass.**

  Run: `python3 -m unittest test/test-ao-acceptance-workflows.py -v`

- [ ] **Step 7: Commit scenarios and workflow execution.**

  ```bash
  git add test/ao-acceptance/scenarios test/ao-acceptance/scenarios.py test/ao-acceptance/checks/workflows.py test/ao-acceptance/runner.py test/test-ao-acceptance-workflows.py
  git commit -m "test: execute critical AO acceptance workflows"
  ```

### Task 7: Add diagnostics, redacted artifacts, and end-to-end runner output

**Files:**

- Create: `test/ao-acceptance/artifacts.py`
- Modify: `test/ao-acceptance/runner.py`
- Modify: `test/ao-acceptance/redaction.py`
- Create: `test/test-ao-acceptance-artifacts.py`

**Interfaces:**

- `artifacts.ArtifactCollector.collect_failure(run_config: RunConfig, results: list[CheckResult], clients: dict, command_runner: CommandRunner) -> pathlib.Path`.
- `artifacts.write_results(path: pathlib.Path, results: list[CheckResult]) -> None`.
- `artifacts.write_summary(path: pathlib.Path, results: list[CheckResult]) -> None`.

- [ ] **Step 1: Write failing tests for artifact safety and exit classification.**

  Feed API payloads, Kubernetes logs, command output, and exception bodies containing passwords, bearer tokens, API keys, and secret-shaped values. Assert that generated `results.json`, summaries, and collected files contain redaction markers or omission notices but not the original values.

- [ ] **Step 2: Run the focused tests and verify they fail.**

  Run: `python3 -m unittest test/test-ao-acceptance-artifacts.py -v`

- [ ] **Step 3: Implement bounded diagnostic collection.**

  Collect AAP/AO statuses, workflow/job events, selected Kubernetes YAML/descriptions/events/logs, host/EE probes, scenario/config metadata, and repository commit. Write into a timestamped directory below the configured artifact directory and apply redaction before every write.

- [ ] **Step 4: Implement result and summary output.**

  Always write `results.json` and a readable `summary.txt`. Return exit code `0` only for all-pass, `1` for check failures, and `2` for invalid configuration or blocked prerequisites. On failure, attempt diagnostics but preserve the original failure classification if collection itself fails.

- [ ] **Step 5: Run the focused tests and verify they pass.**

  Run: `python3 -m unittest test/test-ao-acceptance-artifacts.py -v`

- [ ] **Step 6: Commit artifact handling.**

  ```bash
  git add test/ao-acceptance/artifacts.py test/ao-acceptance/runner.py test/ao-acceptance/redaction.py test/test-ao-acceptance-artifacts.py
  git commit -m "test: collect redacted AO acceptance diagnostics"
  ```

### Task 8: Document operation and integrate fast-test safeguards

**Files:**

- Modify: `test/README.md`
- Create: `test/ao-acceptance/README.md`
- Modify: `.github/workflows/test.yaml`
- Create: `test/test-ao-acceptance-cli.sh`

- [ ] **Step 1: Write the CLI safeguard test.**

  Run the shell entry point with `--help`, invalid mode, and `--mode validate` against a deliberately missing context using mocked command paths. Assert that help is successful, invalid arguments fail clearly, and validate exits before provisioning.

- [ ] **Step 2: Run the CLI test and verify it fails.**

  Run: `bash test/test-ao-acceptance-cli.sh`

- [ ] **Step 3: Document live-run prerequisites and examples.**

  Document target-context selection, credentials, artifact locations, `auto`/`provision`/`validate`, `--skip-provision`, representative EE expectations, cleanup policy, and failure triage. Include the existing-cluster command as the primary example:

  ```bash
  ./test/ao-acceptance/run.sh --mode validate --artifact-dir /tmp/aap-demo-ao-acceptance
  ```

- [ ] **Step 4: Add the CLI safeguard to fast CI without invoking a cluster.**

  Add the shell test to the existing unit-test job. Do not add the live runner itself to pull-request CI; document the dedicated/self-hosted trigger separately.

- [ ] **Step 5: Run all fast acceptance-related tests.**

  Run:

  ```bash
  bash test/test-ao-acceptance-cli.sh
  python3 -m unittest discover -s test -p 'test-ao-acceptance-*.py' -v
  bash -n test/ao-acceptance/run.sh
  git diff --check
  ```

- [ ] **Step 6: Commit documentation and fast-test integration.**

  ```bash
  git add test/README.md test/ao-acceptance/README.md .github/workflows/test.yaml test/test-ao-acceptance-cli.sh
  git commit -m "docs: document AO live acceptance testing"
  ```

## Plan self-review

- **Spec coverage:** Provision/reuse modes are covered by Task 2; TLS, users,
  credentials, tokens, integrations, and MCP by Task 5; all managed EEs by
  Task 5; AO/AAP/Product Demos workflow execution by Task 6; diagnostics and
  secret handling by Task 7; dedicated-runner operation by Task 8.
- **Placeholder scan:** No task depends on an unresolved placeholder or unspecified file.
- **Type consistency:** `RunConfig`, `CheckResult`, `ManagedResourceInventory`,
  `Scenario`, `AapClient`, and `AoClient` interfaces are defined before later
  tasks consume them.
- **Review focus coverage:** Existing-cluster reuse and fail-closed preflight
  are tested in Task 2; API failure behavior in Task 3; EE contract drift in
  Task 5; and artifact redaction in Task 7.
- **Scope:** The plan implements one cohesive acceptance subsystem and keeps
  fast unit tests and live execution separate.
