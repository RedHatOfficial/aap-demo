# Open Issues Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Audit every open GitHub issue in `RedHatOfficial/aap-demo`, preserve
fixes already shipped or under review, and deliver each remaining actionable
fix in an independently reviewable branch and pull request.

**Architecture:** Treat each issue as its own change stream. Small code and
documentation fixes get focused regression tests and conventional commits.
New addons, authentication changes, VM lifecycle changes, and secret-storage
changes require an ADR or design note before implementation; research-only
issues receive an evidence-backed recommendation PR rather than an unreviewed
architectural rewrite.

**Tech Stack:** Bash, Kubernetes/OpenShift manifests, Ansible, Python test
helpers, Make, GitHub pull requests, ShellCheck/yamllint/markdownlint, and the
repository's shell regression suite.

**Spec:** GitHub open-issue inventory captured on 2026-10-12; issue URLs and
acceptance criteria are recorded in the audit matrix below.

## Global Constraints

- Preserve the clean user worktree and never commit credentials or generated cluster state.
- Each code-fix issue uses a separate `codex/issue-<number>-<slug>` branch based on `main`.
- Each PR includes a `Test Plan` section and uses a conventional-commit title.
- Addons remain optional and must not increase the default CRC resource footprint.
- A live CRC cluster is required for deployment, route, operator, and OAuth
  acceptance checks; static tests must cover all other behavior.
- Architectural changes must document alternatives and operational trade-offs in `docs/adr/` before implementation.

## Review Focus

- A quantity such as `20` must not silently become 20 bytes when a Kubernetes
  PVC expects a human storage quantity; test normalization and rejection
  behavior.
- Shell startup changes must preserve existing `KUBECONFIG`, detect the active
  shell, quote paths, and work in non-interactive mode.
- Auto-install prompts must never run in `QUIET=true` or when stdin is not a
  terminal.
- Readiness checks must distinguish terminal AAP states from transient
  `Running=True` states and from failures.
- New addon manifests must pin images, avoid namespace-wide privilege grants,
  and support clean delete/re-enable cycles.

## Audit Matrix

<!-- markdownlint-disable MD013 -->

| Issue | Current finding on `main` | Planned disposition |
| --- | --- | --- |
| #229 | Open; `OLLAMA_STORAGE_SIZE=20` is applied as a bare Kubernetes quantity. | Implement quantity normalization and regression tests on `codex/issue-229-ollama-storage-quantity`. |
| #224 | Open feature request; no merged OAuth2 AAP/AO SSO implementation. | ADR and implementation branch after validating AO's supported OIDC contract. |
| #220 | The current Ollama deploy waits for Ready pods and retries pulls; the reported “pod not found” path is covered by `test/test-ollama.sh`. | Keep as likely fixed; add issue evidence to the tracking report and close only after maintainer confirmation/live reproduction. |
| #213 | Open; kubeconfig is saved under `~/.aap-demo`, but enable/create does not offer shell export setup. | Implement opt-in shell export helper and tests on `codex/issue-213-kubeconfig-shell-setup`. |
| #211 | Open and reproducibly broken: `Makefile` includes missing `aap-demo.mk`. | Remove stale include/help references and verify `make ci` on `codex/issue-211-makefile`. |
| #197 | Open; Fleet validates missing QEMU tools but does not offer platform package installation. | Add opt-in package installation with platform-specific commands and tests on `codex/issue-197-fleet-prerequisites`. |
| #196 | Open research question, not a defect. | Produce an ADR/recommendation comparing QEMU, KubeVirt, Kata, and hybrid fallback. |
| #194 | Open feature; `enable fleet` only prints next steps. | Implement guided interactive/non-interactive setup after prerequisite API is defined, on its own branch. |
| #188 | Fixed in merged PR #208; `aap-readiness.sh`, OPA, watchers, and regression tests recognize the terminal AAP 2.7 condition. | Record as fixed; no duplicate PR. |
| #187 | Open; route wiring exists, but host-side DNS failures are not diagnosed clearly by the addon. | Add route-resolution diagnostics and actionable fallback guidance, with static tests. |
| #178 | Open feature request for Vault OIDC demo. | ADR/design first; then a separate addon PR only after the required Vault image/config contract is defined. |
| #173 | Open feature request for CVE remediation workflow in AO. | Add a documented, pinned demo import workflow and tests after validating the upstream setup guide. |
| #172 | Open security/design request for OS-native secret storage. | ADR comparing macOS Keychain, Windows Credential Manager, Linux Secret Service, and file fallback; implementation must be opt-in and migration-safe. |
| #160 | Explicitly stale synthetic plaibook findings with nonexistent paths. | Non-actionable; report and close after maintainer confirmation, no code branch. |
| #156 | Explicitly stale synthetic plaibook findings with nonexistent paths. | Non-actionable; report and close after maintainer confirmation, no code branch. |
| #139 | Open broad request; no precise version source, cadence, or bypass policy is specified. | Define a version-check contract and implement only after agreeing on source/bypass semantics. |
| #135 | Open operator/catalog architecture issue; current addon has static catalog assumptions. | ADR and live-cluster investigation of namespace-scoped CatalogSources/SCCs before code. |
| #104 | Open cleanup request for APME developer paths and ADR history. | Documentation-only branch consolidating supported/default paths and marking superseded ADR sections historical. |
| #96 | Fix is in active PR #212; no duplicate branch. | Review/verify PR #212 and close/resolve issue when merged. |
| #93 | Open lint alignment request; current CI/pre-commit policy needs an evidence-based audit. | Align configs and make only validated checks blocking, with a dedicated lint PR. |
| #90 | Open large monitoring addon proposal. | ADR/resource analysis first; implementation is a separate addon project, not an opportunistic patch. |
| #73 | Fixed in merged PR #223, which added the requested development skills. | Record as fixed; no duplicate PR. |
| #72 | Open feature request for preconfigured decision environments. | Define supported images, registry auth, resource budget, and AAP association mechanism in an ADR before implementation. |
| #70 | OPA addon exists and readiness handling was fixed in PR #208, but the issue's original acceptance list is broader than current code. | Audit acceptance criteria; fill only concrete gaps in a follow-up OPA branch. |
| #48 | Open large EDA payload-generator addon proposal. | ADR/design and minimal vertical slice before adding all platform templates. |
| #38 | Open one-line ALIA addon request with no integration contract. | Request/record product and deployment requirements; no safe implementation can be inferred. |
| #35 | Requested guidance is present in `docs/collection-authentication.md`, `requirements.yml`, and the current skill context. | Record as substantially fixed; add any missing explicit skill section only if acceptance criteria still fail. |
| #34 | Current skill docs emphasize admin credentials but do not clearly state scoped-RBAC guidance by environment. | Add explicit credential-scoping guidance and tests/grep checks on `codex/issue-34-mcp-credential-guidance`. |
| #21 | Open; portability helpers still use Python fallbacks/process substitution/`compgen`, although some JSON paths already prefer `jq`. | Replace avoidable constructs while preserving supported fallbacks, with shell regression coverage. |
| #20 | Fix is in active PR #186; no duplicate branch. | Review/verify PR #186 and close/resolve issue when merged. |

<!-- markdownlint-enable MD013 -->

## Implementation Tasks

### Task 1: Publish and maintain this audit

**Files:**

- Create: `docs/superpowers/plans/2026-10-12-open-issues-remediation.md`
- Test: `make ci` after the plan-only change

- [ ] Verify the issue inventory against GitHub immediately before each PR is created.
- [ ] Update the matrix when an issue is fixed, superseded by an active PR, or blocked on an architectural decision.
- [ ] Commit with `docs: add open issue remediation plan`.

### Task 2: Fix issue #229 — Ollama storage quantities

**Files:**

- Modify: `addons/ollama/deploy.sh`
- Test: `test/test-ollama.sh`

- [ ] Add a shell helper that accepts Kubernetes quantities with an explicit
  unit and converts a bare positive integer entered through the prompt or
  `OLLAMA_STORAGE_SIZE` into `Gi`, while rejecting malformed/zero/negative
  values with an actionable error.
- [ ] Keep explicit units unchanged and quote the rendered manifest value.
- [ ] Add tests for `20` → `20Gi`, `20Gi` unchanged, and invalid input failing before `kubectl apply`.
- [ ] Run `bash -n addons/ollama/deploy.sh` and `./test/test-ollama.sh`.
- [ ] Commit with `fix(ollama): normalize storage quantities` and open a PR closing #229.

### Task 3: Fix issue #211 — Makefile

**Files:**

- Modify: `Makefile`
- Test: `Makefile`/`lint.mk` behavior through `make ci`

- [ ] Remove the nonexistent `aap-demo.mk` include and deployment-target grep block.
- [ ] Keep `lint.mk` targets and make help describe only active targets.
- [ ] Run `make ci`, `bash -n aap-demo.sh`, and the repository shell tests.
- [ ] Commit with `fix(ci): remove stale makefile include` and open a PR closing #211.

### Task 4: Fix issue #213 — opt-in shell kubeconfig setup

**Files:**

- Modify: `aap-demo.sh`, `includes/aap-demo-paths.sh`
- Test: new `test/test-kubeconfig-shell-setup.sh`
- Modify: `README.md`, `docs/FULL-README.md`

- [ ] Detect the current shell from `$SHELL`/parent process and support bash,
  zsh, fish, and PowerShell without assuming a writable startup file.
- [ ] Skip the prompt when `KUBECONFIG` is already set, `QUIET=true`, stdin is
  not a terminal, or the export is already present.
- [ ] Prompt only after a successful kubeconfig save, show the exact file path,
  and offer a one-command temporary export regardless of the answer.
- [ ] Add mocked tests for existing environment, each supported shell, duplicate avoidance, and non-interactive mode.
- [ ] Commit with `feat(kubeconfig): offer shell export setup` and open a PR closing #213.

### Task 5: Fix issue #197 — Fleet prerequisite installation

**Files:**

- Modify: `addons/fleet/fleet.sh`, `addons/fleet/deploy.sh`
- Test: new `test/test-fleet-prerequisites.sh`
- Modify: `addons/fleet/README.md` or create it if absent

- [ ] Keep `fleet_check_prereqs` read-only by default and add an explicit `fleet_install_prereqs` path.
- [ ] Offer `brew install qemu cdrtools` on macOS and
  `sudo dnf install -y qemu-kvm qemu-img genisoimage` on Fedora/RHEL when
  missing tools are detected.
- [ ] Never auto-install in `QUIET=true`, non-interactive mode, or on
  unsupported operating systems; print exact manual commands instead.
- [ ] Validate the image separately so an ISO or missing QCOW2 file is reported distinctly from missing host tools.
- [ ] Run static mocked tests and shell syntax checks, then open a PR closing #197.

### Task 6: Fix issue #194 — guided Fleet enable

**Files:**

- Modify: `aap-demo.sh`, `addons/fleet/deploy.sh`, `addons/fleet/fleet.sh`
- Test: new `test/test-fleet-enable.sh`
- Modify: Fleet README and `docs/FULL-README.md`

- [ ] Define `FLEET_IMAGE` and `FLEET_NODE_COUNT` precedence: process environment, persisted config, interactive defaults.
- [ ] Prompt for a readable QCOW2 path and positive node count only in an interactive terminal.
- [ ] In quiet/non-interactive mode require `FLEET_IMAGE`, default
  `FLEET_NODE_COUNT=2`, and fail before creating anything if the image is
  absent.
- [ ] Call the existing create/register functions, wait for SSH readiness, and print `fleet list` output.
- [ ] Add rollback of newly-created VMs when AAP registration or readiness verification fails.
- [ ] Run mocked lifecycle tests and open a separate PR closing #194.

### Task 7: Fix issue #187 — MCP route diagnostics

**Files:**

- Modify: `addons/mcp-server/deploy.sh`, `addons/mcp-server/README.md`
- Test: new `test/test-mcp-route-diagnostics.sh`

- [ ] Check route admission and local hostname resolution after deployment.
- [ ] If host resolution fails, distinguish DNS failure from route/service/CA
  failure and print the exact `aap-demo trust-ca`, `aap-demo start`, and
  in-cluster route fallback commands that apply.
- [ ] Do not label the addon connected solely because the Route object exists.
- [ ] Keep the check safe for environments where `getent`, `dig`, or Claude are unavailable.
- [ ] Run focused tests and open a PR closing #187.

### Task 8: Fix issue #34 and complete the issue #35 audit

**Files:**

- Modify: `SKILL.md`, `docs/collection-authentication.md`
- Test: new `test/test-skill-guidance.sh`

- [ ] Add explicit environment-by-environment MCP credential guidance: local
  demo admin is acceptable, shared environments use scoped RBAC, CI uses
  least-privilege service accounts, production must not use admin.
- [ ] Add an explicit `infra.aap_configuration`-first section with collection
  verification, `requirements.yml`, dispatch-role guidance, and failure
  recovery.
- [ ] Run markdown lint and the grep-based acceptance test.
- [ ] Commit with `docs: document scoped MCP and AAP collections` and open a PR
  closing #34 (and mention #35 if the audit confirms all criteria).

### Task 9: Fix issue #21 — portability

**Files:**

- Modify: `aap-demo.sh`, `includes/json-utils.sh`
- Test: new `test/test-portability.sh` plus existing shell tests

- [ ] Replace avoidable `compgen` glob checks with a null-safe file test helper.
- [ ] Replace process substitution used solely to decode kubeconfig credentials
  with tracked temporary files and cleanup through the existing temp-file
  mechanism.
- [ ] Keep `jq` as the first JSON implementation and retain the existing
  working Python/awk fallbacks where required by supported Windows installs.
- [ ] Add tests with mocked `jq`, `python3`, `readlink`, and `compgen` availability.
- [ ] Run ShellCheck and the full shell regression suite, then open a PR closing #21.

### Task 10: Audit/lint/documentation and architectural follow-ups

- [ ] #93: align pre-commit and CI configurations, run every check, and open a lint PR.
- [ ] #104: document the supported APME path and mark superseded ADR sections historical.
- [ ] #70: compare the issue acceptance list with the existing OPA addon and add only missing concrete behavior.
- [ ] #135, #172, #178, #196, #224: write ADRs with evidence and explicit
  acceptance criteria before implementation branches.
- [ ] #38, #48, #72, #90, #139, #173: convert underspecified feature
  proposals into executable design docs or minimal vertical-slice PRs after
  requirements are confirmed.
- [ ] #160 and #156: report stale synthetic findings to maintainers and close
  them; no code change.
- [ ] Verify active PRs #186 and #212 and merged PR #223/#208 before changing any overlapping files.

## Verification Checklist

- [ ] `git status --short --branch` is clean before each branch starts.
- [ ] Every new regression test has been run once failing before its implementation and once passing after it.
- [ ] `bash -n` covers every changed shell script.
- [ ] `make ci` or the smallest complete repository validation command passes
  on each branch; live-cluster limitations are called out in the PR.
- [ ] `git diff --check` passes.
- [ ] Each PR URL is recorded in the final issue/PR summary.
