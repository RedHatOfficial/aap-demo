# Windows Python v2 Migration Plan

<!-- markdownlint-disable MD013 -->

**Goal:** Move every supported Windows command and addon to native Python v2,
then simplify Windows setup and remove its legacy PowerShell command
implementation.

**Decision:** See [ADR-046](../../adr/046-python-cli-windows-default.md). The
current transition exposes Python as `aap-demo` and Bash as `aap-demo-v1`.
That compatibility path is temporary on Windows. The target is Python owning
the supported Windows commands and addons directly, without Bash handlers.
PowerShell may remain only to bootstrap a Python runtime and hand control to
Python setup tooling. Python owns package setup, prerequisites, product
commands, addons, and user-data management.

**Scope:** This is a staged migration. PR 339 implements the first cutover and
reversibility slice. Completion requires porting the supported v1 Windows
surface, validating equivalent behavior, and then removing the Windows-only
compatibility layers. Do not remove them before the acceptance gates pass.

## Phase 1: Python-first install and explicit v1 fallback

**Outcome:** a clean install selects Python v2 as `aap-demo`; the existing Bash
checkout remains available as `aap-demo-v1`.

- [x] Install the PyPI package in an isolated pipx environment from
  `powershell/install.ps1`.
- [x] Register the Bash checkout as `aap-demo-v1`; do not dispatch Python
  commands implicitly to Bash.
- [x] Remove the old PowerShell command wrapper when installing Python v2.
- [x] Document Git for Windows requirements for the legacy CLI and Python
  handlers that execute bundled Bash.
- [x] Supersede the old two-CLI architecture in ADR-010 with ADR-046.
- [ ] Validate command resolution and version output in a clean Windows user
  profile with PowerShell 5.1 and PowerShell 7.

**Files:** `powershell/install.ps1`, `powershell/README.md`,
`docs/concepts/two-ways-to-run.md`, `docs/adr/010-cross-platform-cli.md`,
`docs/adr/046-python-cli-windows-default.md`.

## Phase 2: Preserve existing state and make rollback safe

**Outcome:** existing Windows users can adopt Python and return to Bash without
losing CRC, kubeconfig, configuration, or addon state.

- [x] Use the Python CLI's idempotent migration from `%USERPROFILE%\.aap-demo`
  for supported config, kubeconfig, certificates, and credentials.
- [x] Preserve hand-placed pull-secret files in the shared legacy directory.
- [x] Add `install.ps1 -RollbackToV1` to restore Bash as the `aap-demo` command.
- [x] Make `install.ps1 -Uninstall` remove the Python package and command
  launchers while preserving cluster and user data.
- [x] Remove the installer-added PATH entry only when the installer recorded
  that it added it.
- [ ] Validate upgrade, interrupted migration retry, rollback, and uninstall
  with representative existing `%USERPROFILE%\.aap-demo` state.
- [ ] Confirm credential migration behavior with and without a Windows
  keyring backend; verify no secret value is printed.

**Files:** `powershell/install.ps1`, `powershell/README.md`,
`src/aap_demo/core/migration.py`, `src/aap_demo/core/paths.py`,
`docs/reference/windows-python-migration.md`.

## Phase 3: Complete Windows lifecycle and ingress trust

**Outcome:** Python v2 can inspect and manage an existing CRC/MicroShift
cluster on Windows, including ingress TLS trust, without redeploying it.

- [x] Read the Current User Root store with Python's SSL bindings and import
  the ingress CA through Windows CryptoAPI in a bounded Python worker.
- [x] Report the saved certificate and a Python retry hint if trust import
  fails.
- [ ] Validate CRC create/start/stop/status/diagnose, SSH, and kubeconfig sync
  on Windows; fix only evidenced platform gaps.
- [ ] Confirm a new ingress CA can be added to Current User Root and verify
  trust in Chrome, Edge, and Firefox, including after cluster recreation.
- [ ] Check behavior under non-ASCII and space-containing Windows user paths.
- [ ] Record results for supported Windows and OpenShift Local versions.

**Files:** `src/aap_demo/cluster/ingress_ca.py`,
`src/aap_demo/infra/crc.py`, `src/aap_demo/exec/ssh.py`,
`src/aap_demo/cluster/kubeconfig.py`, relevant Windows unit/system tests.

## Phase 4: Port the supported Windows surface to Python

**Outcome:** Every supported Windows command and addon has a Python
implementation and runs without Git for Windows.

- [x] Document the current Python registry: Fleet, AO, and OPA are native
  Python; Product Demos, EDA Playground, MCP Server, and Ollama use bundled
  Bash handlers.
- [x] Document Git for Windows and external tool requirements for shell-backed
  handlers; keep unsupported-addon fallback explicit.
- [ ] Inventory every v1 command and registered addon used on Windows. Record
  its owner, dependencies, state, and acceptance evidence in the capability
  matrix.
- [ ] Port supported commands and addons to native Python, preserving user
  data, error behavior, and documented configuration. Explicitly mark
  unsupported or platform-inapplicable features instead of forwarding them to
  Bash.
- [ ] Replace shell-backed Python addon handlers with Python implementations.
- [ ] Keep the capability matrix generated from the command/addon registries
  so it cannot silently drift from `aap-demo help` or `aap-demo enable`.
- [ ] Validate each supported Windows command and addon on a clean Windows
  environment without Git for Windows.

**Files:** `src/aap_demo/`, `addons/`, `includes/`,
`docs/reference/windows-python-migration.md`, Windows tests.

## Phase 5: Simplify Windows installation and retire compatibility code

**Outcome:** PowerShell only bootstraps Python; Python owns setup and every
supported command and addon.

- [x] Add a Python setup module that installs/upgrades/uninstalls `aap-demo`
  through pipx, checks or installs prerequisites, and manages command
  launchers.
- [x] Reduce `powershell/install.ps1` to locating or bootstrapping Python and
  invoking the Python setup module.
- [ ] Remove the PowerShell native CLI (`powershell/aap-demo.ps1` and
  `powershell/native/`) after parity is accepted.
- [ ] Remove the Windows `aap-demo-v1` launcher, rollback path, and Git for
  Windows requirement after all supported Windows workflows pass in Python.
- [x] Move prerequisite, PATH, install, rollback, and uninstall behavior out
  of PowerShell and into Python setup tooling.
- [ ] Update Windows guides, ADRs, and migration docs to describe the final
  Python-only runtime and supported install path.
- [ ] Add Windows setup and launcher checks for fresh install, upgrade, PATH
  precedence, missing Python/pipx, and uninstall.
- [ ] Build and install the wheel in a clean Windows environment; verify the
  console script and packaged runtime assets.
- [ ] Run repeatable Windows unit, package, and non-destructive smoke checks.
- [ ] Keep cluster-destroying and addon-removal tests opt-in for routine CI;
  run them in the explicitly authorized end-to-end acceptance workflow.
- [ ] Publish the supported Windows/Python/CRC combination with each release.

**Transition acceptance checklist:**

- [ ] `aap-demo --version` runs Python v2; `aap-demo-v1 --version` runs Bash v1.
- [ ] Every supported Windows command and addon is implemented in Python and
  requires no Git for Windows runtime.
- [ ] Existing CRC state and kubeconfig work after install and migration.
- [ ] Upgrade, interrupted migration retry, rollback during transition, and
  uninstall preserve CRC and user state.
- [ ] Ingress CA trust is verified in the supported Windows browsers.
- [ ] Unsupported or inapplicable features fail clearly and do not route to
  legacy commands.
- [ ] Clean Windows install, upgrade, and uninstall succeed with the documented
  Python package manager/bootstrap.
- [ ] No secret material appears in migration, installer, or diagnostic output.

**Final Windows target:**

- [ ] PowerShell is used only to bootstrap the Python runtime and hand off to
  Python setup tooling.
- [ ] Python setup tooling installs, upgrades, and uninstalls the CLI and
  manages prerequisites and launchers.
- [ ] Python setup tooling installs, upgrades, and uninstalls `aap-demo`
  through pipx.
- [ ] The supported Windows command and addon surface runs in Python without
  Git for Windows or a PowerShell command implementation.

## PR 339 implementation status

The Windows-default change is on a clean branch based on current `main`. The
implementation makes Python v2 the default, adds the rollback path and Windows
Current User certificate-store handling, and moves setup ownership into a
standard-library Python module. `install.ps1` now only locates or bootstraps
Python and invokes that module; Python setup installs `aap-demo` with pipx.
Addon conversions are planned for follow-up PRs. Removing the PowerShell native
CLI and v1 fallback, and clean Windows installer validation, remain open
migration work.
