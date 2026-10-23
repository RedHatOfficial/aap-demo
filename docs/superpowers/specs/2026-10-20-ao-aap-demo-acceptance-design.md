# AO/AAP-Demo Live Acceptance Testing Design

## Intent

Add a live acceptance-testing layer for the AAP-Demo Automation Orchestrator
(AO) critical path. The suite will validate not only that AO workflows can run,
but also that the AAP-Demo build and its addon wiring produce a usable,
securely connected AAP, AO, MCP, and Product Demos environment.

The first target is a manually operated or dedicated self-hosted environment.
GitHub-hosted lifecycle testing is out of scope for the first milestone.

## Scope

The initial critical path includes:

- AAP-Demo core deployment and readiness.
- The `ao` addon.
- The `mcp-server` addon, including its automatic installation as an AO
  dependency.
- The `product-demos` addon with a minimal, deterministic domain selection.
- AO workflows that launch AAP job templates.
- Every execution environment referenced by AAP-Demo-managed job templates.

The suite is an opt-in live test. Existing fast unit, manifest, importer, and
provisioning tests remain separate and continue to run without a live cluster.

## Goals and non-goals

### Goals

1. Detect whether a target AAP-Demo/AO environment is ready for acceptance
   testing.
2. Reuse an existing healthy environment without unnecessary provisioning.
3. Validate the resources, credentials, tokens, routes, TLS trust, and
   integrations created or wired by AAP-Demo.
4. Exercise representative AAP job execution through every supported
   execution environment.
5. Exercise a small, explicit set of AO, MCP, and Product Demos workflows.
6. Produce actionable, secret-free evidence when a check fails.

### Non-goals

- Running the suite automatically on every GitHub pull request.
- Testing every upstream AO demo workflow in the first milestone.
- Validating arbitrary user-created AAP resources or execution environments.
- Destroying or resetting a cluster as part of the default test run.
- Printing, persisting, or attaching bearer tokens and other secrets.

## Execution modes

The operator-facing entry point will be:

```bash
./test/ao-acceptance/run.sh --mode validate
```

The runner supports three modes:

- `auto` (default): detect a healthy AAP-Demo/AO installation and reuse it;
  provision only missing prerequisites.
- `provision`: explicitly run the required AAP-Demo deployment and addon setup,
  then execute the acceptance suite.
- `validate`: never provision or mutate addons; require the critical path to
  exist and run readiness, validation, workflow scenarios, and diagnostics.

`--skip-provision` may be provided as a convenience alias for `--mode
validate`, but the explicit mode remains the documented interface.

All modes require an explicitly selected target context. `auto` must verify
the current context before it invokes any deployment or addon command. The
default behavior preserves the cluster after failures; cleanup, if later
needed, must be an explicit operation.

## Architecture

The acceptance harness is a repository-based shell/Python test runner. AO
workflows are the behavior under test, while the harness owns setup, polling,
assertions, and evidence collection.

Proposed boundaries:

- `test/ao-acceptance/run.sh`: operator-friendly entry point, argument
  handling, exit status, and summary display.
- `test/ao-acceptance/environment.py`: target-context checks, mode handling,
  AAP-Demo detection, and readiness gates.
- `test/ao-acceptance/provision.py`: controlled invocation of `aap-demo deploy`
  and the required addon enablement commands.
- `test/ao-acceptance/clients/`: authenticated AAP and AO API clients with
  redaction-aware request/response logging.
- `test/ao-acceptance/checks/`: focused checks for TLS, identity, tokens,
  integrations, MCP, AAP resources, execution environments, and workflows.
- `test/ao-acceptance/scenarios/`: versioned scenario manifests containing
  workflow/job-template names, timeouts, expected terminal states, and success
  markers.
- `test/ao-acceptance/artifacts.py`: diagnostic collection, secret scrubbing,
  result serialization, and artifact layout.

The data flow is:

1. Confirm the target context and collect non-secret environment metadata.
2. In `auto` or `provision`, deploy or enable only what is needed.
3. Wait for AAP, AO, MCP, integrations, projects, job templates, and imported
   workflows to become usable.
4. Build an inventory of AAP-Demo-managed resources and referenced execution
   environments.
5. Run wiring and resource checks.
6. Run one representative successful job through each supported execution
   environment.
7. Invoke explicit AO workflow scenarios and follow their linked AAP jobs.
8. Emit results and collect diagnostics on failure.

## Validation contract

### TLS, routing, and trust

Validate that AAP, AO, and MCP route URLs:

- resolve from the host;
- resolve from execution-environment pods where the workflow requires it;
- complete authenticated HTTPS requests; and
- use a trusted ingress CA in the relevant host and pod contexts.

Checks must cover the in-cluster route/network workarounds used by MicroShift,
including route host aliases and private-network SSRF allow-list behavior where
applicable.

### Users, credentials, and tokens

Validate that required admin and service identities exist, expected credential
types are present, and tokens are non-empty, scoped as intended, and usable for
the APIs or integrations that consume them. Token values must never appear in
logs, result files, or diagnostic artifacts.

### AAP, AO, and MCP wiring

Validate:

- AO AAP and MCP integrations resolve to expected endpoints;
- AO credentials are attached to the relevant workflow nodes;
- MCP tools are enabled and one deterministic operation is callable;
- managed organizations, projects, inventories, credentials, job templates,
  schedules where applicable, and launch permissions exist;
- projects point to the expected repository and ref; and
- imported AO workflows contain expected AAP job-template links and bindings.

### Execution environments

The suite defines “all supported execution environments” as every execution
environment referenced by AAP-Demo-managed job templates, including the Product
Demos EE. Each EE/template pair must map to a named AO acceptance workflow whose
AO graph links the exact AAP job template. It must:

1. enumerate those references from the managed AAP resources;
2. verify each EE’s expected name/image and availability;
3. ensure every managed EE is represented in the acceptance matrix; and
4. launch at least one representative successful job through its mapped AO
   workflow for each EE.

An unrecognized or untested EE reference is a contract-drift failure, not a
 silently skipped check.

## Initial workflow scenarios

The first suite uses an explicit scenario manifest rather than executing every
upstream AO demo:

1. **AO installation and wiring smoke test** — verify AO reachability, expected
   integrations, provider/credential bindings, and imported workflow presence.
2. **AAP-backed AO workflow** — invoke one deterministic AO workflow whose AAP
   job-template node launches a known job template; require terminal AO success,
   AAP job success, and an expected completion marker in job events.
3. **Product Demos integration** — verify the selected Product Demos project,
   EE, and job template, then run the least environment-sensitive demo through
   AO and validate its expected artifact or fact.
4. **MCP integration smoke test** — launch one deterministic AO workflow with
   an agentic node bound to the managed MCP integration, invoke one selected
   read-only MCP tool, and validate a recognizable successful result without
   broad infrastructure changes. Acceptance success requires structured AO
   evidence for the declared MCP tool in addition to the marker; direct MCP
   calls remain supplemental readiness/security diagnostics only. Unsupported
   MCP arguments are rejected before provisioning.

Every scenario declares a timeout, polling interval, expected terminal states,
resource names, and success markers. Upstream workflow or job-template changes
must produce a clear contract-drift error.

## Results and failure evidence

Each check emits a structured result containing:

- stable check ID and component (`tls`, `identity`, `mcp`, `ee:<name>`,
  `workflow:<name>`, and so on);
- start/end timestamps and duration;
- target namespace/resource identifiers;
- status and redacted summary; and
- failure class: prerequisite, wiring, execution, timeout, or contract drift.

On failure, collect a timestamped artifact bundle containing, where available:

- sanitized AAP/AO API responses;
- workflow and AAP job status and events;
- Kubernetes resource YAML, descriptions, recent events, and relevant pod logs;
- host and execution-environment-pod DNS/TLS probes;
- the scenario manifest and repository commit;
- non-secret addon and mode configuration;
- machine-readable `results.json`; and
- a concise human-readable summary.

Redaction happens at the collection boundary. If a collector cannot prove that
credentials and bearer tokens have been removed, it must omit the payload and
record that omission rather than write potentially sensitive data.

Scenarios use unique, clearly prefixed test names and avoid destructive jobs by
default.

## Testing strategy

The harness itself will have fast tests for argument parsing, mode selection,
resource inventory, API response parsing, polling/timeout behavior, contract
matching, redaction, and exit-code classification. These tests mock API
responses and command output.

Live acceptance tests are opt-in and run only on the manually operated or
dedicated self-hosted environment. The initial rollout is:

1. dry-run inventory and readiness checks;
2. wiring and managed-resource validation;
3. representative jobs for every managed EE;
4. AO workflow execution;
5. MCP and Product Demos scenarios; and
6. dedicated-runner setup and artifact-retention documentation.

## Success criteria

The first milestone is complete when an operator can point the runner at an
already-running AAP-Demo cluster and, without reprovisioning it, receive a
single pass/fail result that demonstrates:

- the critical-path services are healthy;
- the repository-managed wiring is present and usable;
- TLS, users, credentials, tokens, and route trust work from their intended
  contexts;
- every repository-managed EE has passed a representative job;
- AO can launch and complete the selected AAP-backed workflows;
- MCP and Product Demos integration scenarios pass; and
- any failure produces actionable, secret-free diagnostics.
