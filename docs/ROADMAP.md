# aap-demo Roadmap

**Last updated:** 2026-10-22

This roadmap describes recommended evolution for `aap-demo`. It is directional,
not a release commitment. Priorities should change when Red Hat product versions,
OpenShift Local, supported host platforms, or demo requirements change.

## Vision

Make `aap-demo` the fastest reliable way to create, operate, demonstrate, pause,
recover, and remove a complete local Ansible Automation Platform environment.

The project should remain:

- Local-development and demonstration tooling, never a production deployment pattern.
- Secure by default, with retained credentials encrypted and secret values excluded
  from ordinary output, process arguments, and logs.
- Idempotent and recoverable after interruption, sleep, reboot, or partial failure.
- Transparent: every long operation reports progress and every failure provides a
  concrete next action.
- Extensible through documented addon contracts rather than edits to the main CLI.
- Usable interactively and through stable, machine-readable automation interfaces.

## Current strengths

- End-to-end CRC/MicroShift and AAP lifecycle management.
- A full-demo path that includes AAP, Private Automation Hub, Automation
  Orchestrator, Product Demos, Fleet nodes, licensing, wiring, and the dashboard.
- Encrypted credential retention and separate Customer Portal and Automation Hub
  token handling.
- Shared operation locking, readiness, resource preflight, storage, recovery, and
  secure HTTP helpers.
- More than 50 focused shell, Python, and PowerShell test assets.
- Linux, macOS, Windows, and WSL guidance with platform-specific implementations.
- CI for shell syntax, unit tests, portability, linting, secret detection, and
  Kubernetes manifest validation.

## Main risks to address

1. **CLI concentration:** `aap-demo.sh` is nearly 4,000 lines and still owns command
   dispatch, lifecycle orchestration, status, deployment, Fleet, and addon behavior.
   This increases regression risk and makes ownership boundaries difficult to see.
2. **Live validation gap:** CI validates isolated behavior but cannot prove that a
   fresh CRC VM, AAP installation, external APIs, and every addon work together.
3. **Implicit addon contracts:** addons use similar lifecycle patterns, but their
   dependencies, readiness, resource requirements, supported architectures, and
   cleanup semantics are not expressed through one machine-readable contract.
4. **Cross-platform drift:** Bash and PowerShell implementations can diverge as new
   lifecycle and security behavior is added.
5. **Long-operation recovery:** full-demo is rerunnable, but a persistent execution
   journal and explicit phase model would make interruption recovery clearer.
6. **Supportability:** troubleshooting evidence exists across status, diagnose,
   must-gather, logs, and the dashboard, but there is no single redacted support
   bundle manifest or health-state model.

## Recommended delivery order

### Milestone 1: Stabilize the CLI core

**Priority:** Now

Turn the main script into a thin compatibility-preserving entry point before adding
more top-level features.

- Move command implementations into cohesive modules such as cluster, deployment,
  diagnostics, credentials, Fleet, addons, and maintenance.
- Keep `aap-demo.sh` responsible for bootstrap, argument dispatch, shared setup, and
  backward-compatible aliases.
- Define common command rules for exit codes, errors, warnings, progress messages,
  timeouts, prompts, `QUIET=true`, and structured output.
- Remove remaining duplicated waits and rollout checks in favor of the shared
  readiness helpers.
- Add shell tests that source each module independently and verify that loading a
  module has no side effects.
- Document internal module boundaries in an architecture ADR.

#### Exit criteria

- `aap-demo.sh` is below 1,500 lines without changing public commands.
- Every mutating top-level command has a focused regression test.
- Required failures consistently return nonzero and include a next action.
- Existing unit, lint, portability, and live smoke tests remain green.

### Milestone 2: Formalize state and addon contracts

**Priority:** Now

Make extensions declarative and state upgrades predictable.

- Introduce an addon manifest describing:
  - name, version, lifecycle scripts, dependencies, and conflicts;
  - supported host and guest architectures;
  - CPU, memory, storage, and external-service requirements;
  - readiness checks, wiring hooks, cleanup behavior, and purge behavior;
  - credentials consumed, without storing secret values in the manifest.
- Validate manifests before enablement and generate addon help/completion from them.
- Add a versioned state schema for `~/.aap-demo` and encrypted Vault keys.
- Implement explicit, tested state migrations with backup and rollback behavior.
- Detect unknown, removed, or partially installed addons and offer a safe reconcile
  action.

#### Exit criteria

- Adding a normal addon does not require editing the main command dispatcher.
- Help, completion, preflight, dashboard metadata, and dependency checks consume the
  same addon manifest.
- State migrations are idempotent and tested from each supported prior schema.
- `aap-demo diagnose` identifies state/schema drift without exposing credentials.

### Milestone 3: Make orchestration resumable and observable

**Priority:** Next

Represent long workflows as named, inspectable phases.

- Add a persistent, non-secret execution journal for create, deploy, start,
  full-demo, restore, and uninstall operations.
- Record phase start/end time, result, retry count, and a redacted error summary.
- Resume only safe idempotent phases; require confirmation before retrying a
  destructive or externally visible phase.
- Add explicit `ready`, `progressing`, `degraded`, `blocked`, and `stopped` health
  states shared by status, diagnose, JSON output, and the dashboard.
- Show the active phase, elapsed time, last successful phase, and actionable blocker
  in both terminal and dashboard views.
- Provide `aap-demo reconcile` for converging cluster, addon, credential-health, and
  wiring state without recreating healthy resources.

#### Exit criteria

- Interrupting full-demo at each phase and rerunning it reaches the same final state.
- Status and dashboard report the same normalized health state.
- A failed workflow can be diagnosed without searching multiple temporary logs.
- Execution journals contain no credentials, tokens, authorization headers, or
  request bodies.

### Milestone 4: Establish a live release qualification gate

**Priority:** Next

Keep fast isolated CI, then add a separately managed live test lane on disposable
hardware capable of nested virtualization.

- Define a versioned release scenario:
  1. clean host preflight;
  2. fresh cluster creation;
  3. AAP deployment and subscription attachment;
  4. full-demo installation;
  5. health and endpoint validation;
  6. repeated idempotency run;
  7. stop/start and host reboot recovery;
  8. must-gather generation;
  9. complete uninstall with residue checks.
- Run the live lane on a schedule and before tagged releases, not on every pull
  request.
- Store redacted timings, component versions, resource peaks, phase results, and
  failure artifacts.
- Add contract tests using recorded, sanitized API fixtures for Red Hat and AAP APIs
  so response-shape regressions are caught without live credentials.
- Change advisory CI checks that protect correctness into required checks after
  existing violations are resolved.

#### Exit criteria

- Every release has a linked live qualification result and tested version matrix.
- The project tracks median and worst-case install time and disk usage.
- API fixture tests cover authentication rejection, empty results, pagination,
  multiple subscriptions, rate limits, and malformed responses.
- Secret scanning verifies generated logs and support artifacts, not only source.

### Milestone 5: Improve daily user experience

**Priority:** Next

- Add named resource profiles such as `minimal`, `standard`, and `full-demo`, with
  preflight explaining the selected profile and required capacity.
- Support a documented non-secret configuration file for repeatable unattended runs;
  continue reading secrets only from the encrypted credential store.
- Add machine-readable output to major read-only commands:
  `status`, `preflight`, `diagnose`, `version`, and addon inventory.
- Add a `doctor --fix` or equivalent mode that previews each repair before applying
  it and never silently performs destructive recovery.
- Make progress output stable in noninteractive terminals and preserve concise,
  human-friendly interactive output.
- Add a release changelog and migration notes for behavioral or state changes.

#### Exit criteria

- A user can preflight a selected profile before any VM or cluster mutation.
- Automation does not need to parse human-oriented output.
- Common failure classes link to one documented repair command or procedure.
- Upgrade notes identify configuration, state, credential, and platform impacts.

### Milestone 6: Strengthen platform parity

**Priority:** Later

- Publish a generated capability matrix for Linux, macOS, native Windows, and WSL.
- Define a platform-neutral lifecycle contract test suite and run it against Bash
  and PowerShell implementations.
- Mark features as supported, experimental, unavailable, or awaiting live validation.
- Add real-host qualification for macOS and Windows recovery paths when suitable
  runners are available.
- Reduce duplicated behavior by sharing schemas, fixtures, manifests, and expected
  outputs even where platform-specific execution remains necessary.

#### Exit criteria

- The capability matrix is generated from tested declarations rather than maintained
  manually in several documents.
- Equivalent commands return equivalent state and error categories across platforms.
- Platform-specific limitations are detected before an operation starts.

### Milestone 7: Harden releases and supply-chain hygiene

**Priority:** Later

- Produce checksums and signed release artifacts.
- Generate an SBOM for distributed scripts, bundled assets, images, and downloaded
  helper-tool versions.
- Pin or verify downloaded binaries and container images wherever upstream supports
  immutable digests or checksums.
- Automate dependency and base-image update proposals.
- Document supported AAP, CRC, MicroShift, host OS, architecture, and addon versions.
- Add a deprecation policy for commands, aliases, state schemas, and host platforms.

#### Exit criteria

- Users can verify every release artifact before installation.
- Downloaded executable dependencies are authenticated or checksum-verified.
- Each release publishes a support matrix, known limitations, and upgrade notes.

## Architecture decision gate

Do not rewrite the project solely because the main Bash file is large. First complete
the module, state, addon, and command contracts above. Then evaluate whether a shared
cross-platform core would materially improve reliability.

An evaluation should compare:

- keeping Bash and PowerShell with shared declarative contracts;
- a small Python core with thin shell/PowerShell bootstraps;
- a compiled single-binary CLI.

The decision should measure startup prerequisites, distribution size, privilege
boundaries, testability, platform parity, contributor familiarity, and migration
risk. Any replacement must preserve existing commands and state migration before it
becomes the default.

## Ongoing engineering measures

Track these measures per release:

| Measure | Desired direction |
|---------|-------------------|
| Fresh full-demo success rate | Increase toward 100% on qualified hosts |
| Second-run idempotency failures | Decrease to zero |
| Median fresh install time | Decrease without hiding readiness failures |
| Actionable error coverage | Increase for every known failure class |
| Main dispatcher size | Decrease as command modules become independent |
| Live-tested platform/version combinations | Increase intentionally |
| Secret leaks in tests, logs, and support bundles | Remain zero |
| Recovery after interrupted phases | Increase to every safe phase |

## Contribution guidance

New roadmap work should:

1. Preserve the local-development-only security boundary.
2. Include focused non-live tests and identify any required live validation.
3. Reuse shared lifecycle, readiness, secure HTTP, state, and credential helpers.
4. Update help, completion, dashboard metadata, and documentation where applicable.
5. Define a measurable acceptance criterion rather than only adding a feature.
6. Avoid increasing `aap-demo.sh` unless the change is bootstrap or dispatch logic.

## Explicit non-goals

- Production AAP installation or production security guidance.
- Exposing local services outside the host.
- Replacing supported Red Hat installers or lifecycle tooling.
- Silently collecting telemetry or uploading diagnostic data.
- Storing retained credentials in plaintext for convenience.
- Adding new addons faster than core reliability and release validation can support.
