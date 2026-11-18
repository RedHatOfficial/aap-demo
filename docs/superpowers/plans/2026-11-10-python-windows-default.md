# Windows Python v2 Migration Plan

<!-- markdownlint-disable MD013 -->

**Goal:** Make the PyPI Python CLI the default Windows experience, preserve Bash
v1 as an explicit compatibility path, and finish the Windows validation and
capability work needed to call the migration complete.

**Decision:** See [ADR-045](../../adr/045-python-cli-windows-default.md). The
installer exposes Python as `aap-demo` and Bash as `aap-demo-v1`. Python v2 may
invoke bundled Bash addon scripts; this is distinct from running the whole v1
CLI.

**Scope:** This is a staged migration. PR 339 implements the first cutover and
reversibility slice. It does not claim every Python command or addon has
Windows parity, and it does not claim Windows acceptance has completed.

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
- [x] Supersede the old two-CLI architecture in ADR-010 with ADR-045.
- [ ] Validate command resolution and version output in a clean Windows user
  profile with PowerShell 5.1 and PowerShell 7.

**Files:** `powershell/install.ps1`, `powershell/README.md`,
`docs/concepts/two-ways-to-run.md`, `docs/adr/010-cross-platform-cli.md`,
`docs/adr/045-python-cli-windows-default.md`.

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

- [x] Add Windows ingress CA import to the Current User Root store using
  `certutil.exe -user -addstore` and verify its SHA-1 store thumbprint.
- [x] Report the saved certificate and a manual recovery command if trust
  import fails.
- [ ] Validate CRC create/start/stop/status/diagnose, SSH, and kubeconfig sync
  on Windows; fix only evidenced platform gaps.
- [ ] Confirm Current User Root trust in Chrome, Edge, and Firefox, including
  after a cluster recreation changes the ingress CA.
- [ ] Check behavior under non-ASCII and space-containing Windows user paths.
- [ ] Record results for supported Windows and OpenShift Local versions.

**Files:** `src/aap_demo/cluster/ingress_ca.py`,
`src/aap_demo/infra/crc.py`, `src/aap_demo/exec/ssh.py`,
`src/aap_demo/cluster/kubeconfig.py`, relevant Windows unit/system tests.

## Phase 4: Publish addon capability and close support gaps

**Outcome:** Windows users can tell which handlers are native Python, which
invoke bundled Bash, and which remain v1-only.

- [x] Document the current Python registry: Fleet is native Python; Product
  Demos, EDA Playground, AO, MCP Server, and Ollama use bundled Bash handlers.
- [x] Document Git for Windows and external tool requirements for shell-backed
  handlers; keep unsupported-addon fallback explicit.
- [ ] Generate or maintain the Windows capability matrix from the addon
  registry so it cannot silently drift from `aap-demo enable` output.
- [ ] For each addon required on Windows, select a Python owner or document
  why the existing Bash handler remains; validate one supported Windows path.
- [ ] Port or explicitly defer each supported v1-only command. Do not remove
  `aap-demo-v1` until its replacement and acceptance evidence exist.

**Files:** `src/aap_demo/addons/`, `src/aap_demo/cli/addons.py`,
`docs/reference/windows-python-migration.md`, `powershell/README.md`.

## Phase 5: Windows release and acceptance gate

**Outcome:** each Python v2 release has repeatable Windows install, upgrade,
fallback, and package checks.

- [ ] Add Windows installer and launcher checks for fresh install, upgrade,
  PATH precedence, missing pipx, rollback, and uninstall.
- [ ] Build and install the wheel in a clean Windows environment; verify the
  console script and bundled Bash addon assets.
- [ ] Run focused Python unit tests and non-destructive Windows smoke checks.
- [ ] Keep cluster-destroying and addon-removal tests opt-in.
- [ ] Publish the supported Windows/Python/CRC combination and known
  shell-backed addon limitations with each release.

**Acceptance checklist:**

- [ ] `aap-demo --version` runs Python v2; `aap-demo-v1 --version` runs Bash v1.
- [ ] Existing CRC state and kubeconfig work after install and migration.
- [ ] Rollback restores the v1 command without changing CRC or user state.
- [ ] Ingress CA trust is verified in the supported Windows browsers.
- [ ] Unsupported addons show the explicit `aap-demo-v1` command.
- [ ] PyPI install, upgrade, and uninstall succeed on a clean Windows profile.
- [ ] No secret material appears in migration, installer, or diagnostic output.

## PR 339 implementation status

PR 339 rebases the Windows-default change onto current `main`. This slice
implements the Phase 1 command default and Phase 2 rollback, adds the Windows
Current User certificate-store path in Phase 3, and updates the Windows guide,
architecture record, and migration plan. The Windows-specific validation and
remaining parity gates above are intentionally still unchecked.
