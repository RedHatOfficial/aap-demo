# Python Windows Default Implementation Plan

<!-- markdownlint-disable MD013 -->

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the PyPI-installed Python `aap-demo` CLI the default Windows experience while preserving a deliberate Bash v1 compatibility path for capabilities that are not yet implemented in Python.

**Architecture:** Windows will install the Python package into an isolated pipx environment and expose its console script as `aap-demo`. The existing Git Bash implementation remains available as `aap-demo-v1` and is invoked explicitly for unsupported legacy addon commands; Python owns command routing, configuration migration, CRC execution, status/diagnostics, and supported addon lifecycles. Capability detection must fail clearly rather than silently switching implementations.

**Tech Stack:** Python 3.9+, `pyproject.toml`, pipx/PyPI, argparse, keyring, PyYAML, jsonschema, Rich, Windows PowerShell, Git Bash, OpenShift Local/CRC, `oc`/`kubectl`, pytest.

**Spec:** `docs/concepts/two-ways-to-run.md`, `docs/concepts/what-aap-demo-is.md`, ADR-010, ADR-029, ADR-030, ADR-031, ADR-032, and the current Python package under `src/aap_demo/`.

## Global Constraints

- Python runtime support remains `>=3.9`.
- The Windows entry point must be the PyPI/pipx Python CLI; Bash v1 remains an explicit compatibility command.
- Never destroy or redeploy a user’s existing CRC cluster during installation, migration, update, or rollback.
- Preserve the existing `~/.aap-demo` kubeconfig, credentials, addon state, and Bash v1 checkout.
- Unsupported Python commands must report the fallback command and reason; they must not silently execute a different implementation.
- Windows deployment and addon tests must run without assuming POSIX file modes or POSIX-only paths.
- Secrets must not be printed, committed, or copied into source control; use Windows Credential Manager/keyring where supported.

## Review Focus

- Existing Bash state contains credentials that keyring cannot import: migration must be recoverable and must identify the exact remediation without exposing values.
- Windows NTFS does not provide POSIX `0600` semantics: secret-storage tests must verify Windows ACL/keyring behavior rather than Unix mode bits.
- CRC may be stopped, starting, or inaccessible through SSH/UAC: Python must distinguish those states and give an actionable command.
- A user may invoke an addon supported only by Bash v1: routing must be explicit, versioned, and testable.
- A PyPI upgrade must not replace the working Bash checkout or change the running cluster: install, update, and rollback need independent verification.

### Task 1: Define the Windows implementation and command-capability contract

**Files:**

- Modify: `docs/concepts/two-ways-to-run.md`
- Modify: `docs/concepts/what-aap-demo-is.md`
- Modify: `docs/reference/commands.md`
- Modify: `docs/adr/010-cross-platform-cli.md`
- Create: `docs/reference/windows-python-migration.md`
- Test: `tests/unit/test_cli_surface.py`, `tests/unit/test_command_surface.py`

**Interfaces:**

- Produces the public command contract: Python v2 is `aap-demo`; Bash v1 is `aap-demo-v1`.
- Produces a capability matrix naming Python-supported commands, Bash fallback commands, and intentionally unsupported commands.

- [ ] **Step 1: Write failing command-surface tests** for `aap-demo --version`, `aap-demo-v1 --version`, explicit fallback messaging, and unsupported-addon errors.
- [ ] **Step 2: Run** `python -m pytest tests/unit/test_cli_surface.py tests/unit/test_command_surface.py -q` and confirm the new contract fails.
- [ ] **Step 3: Document** the capability matrix and migration rules in the listed docs, including examples for `aap-demo` and `aap-demo-v1`.
- [ ] **Step 4: Update** CLI help text so every fallback includes its command and reason.
- [ ] **Step 5: Run** the focused tests and verify the help output matches the documented matrix.
- [ ] **Step 6: Commit** `docs: define Python-first Windows command contract`.

### Task 2: Install Python v2 from PyPI and preserve Bash v1

**Files:**

- Modify: `powershell/aap-demo.ps1`
- Modify: `powershell/README.md`
- Modify: `install.sh`
- Modify: `docs/guides/install.md`
- Create: `powershell/install-python.ps1`
- Test: `test/test-powershell-installer-launcher.ps1`, `test/test-powershell-parity.ps1`, `tests/system/test_windows_launcher.py`

**Interfaces:**

- `install-python.ps1` installs `aap-demo` from PyPI with pipx, verifies the console script, and registers the existing Bash checkout as `aap-demo-v1`.
- The launcher resolves the Python executable without depending on the caller’s current PATH, and returns a useful error when Python/pipx is missing.

- [ ] **Step 1: Add failing PowerShell/Python smoke tests** for fresh install, already-installed upgrade, missing pipx, and preserved `aap-demo-v1`.
- [ ] **Step 2: Implement** the installer with an isolated pipx environment; do not install into the system interpreter.
- [ ] **Step 3: Implement** explicit `aap-demo-v1` registration pointing at the existing `~/.aap-demo/aap-demo/aap-demo.sh` checkout.
- [ ] **Step 4: Make** the PowerShell launcher dispatch to the Python console script by default and remove implicit Git Bash dispatch for Python-owned commands.
- [ ] **Step 5: Add** `--implementation {python,v1}` only if needed for diagnostics; otherwise expose `aap-demo-v1` as the stable fallback.
- [ ] **Step 6: Run** PowerShell parser tests and a clean Windows install smoke test; verify `where aap-demo`, `where aap-demo-v1`, `aap-demo --version`, and `aap-demo-v1 --version`.
- [ ] **Step 7: Commit** `feat: make PyPI Python CLI the Windows default`.

### Task 3: Migrate legacy state and credentials safely

**Files:**

- Modify: `src/aap_demo/core/migration.py`
- Modify: `src/aap_demo/core/paths.py`
- Modify: `src/aap_demo/core/secrets.py`
- Modify: `src/aap_demo/core/config.py`
- Test: `tests/unit/test_migration.py`, `tests/unit/test_paths.py`, `tests/unit/test_secrets.py`
- Create: `tests/system/test_windows_migration.py`

**Interfaces:**

- Migration is idempotent and records migrated/blocked items without copying secret values into logs.
- Kubeconfig remains at `~/.aap-demo/kubeconfig.microshift` unless the user explicitly supplies `--kubeconfig`.
- Credential import failure is nonfatal for unrelated commands and gives a precise recovery command.

- [ ] **Step 1: Add failing tests** for legacy config discovery, existing kubeconfig preservation, idempotent reruns, missing keyring backend, and a failed `galaxy-token` import.
- [ ] **Step 2: Implement** Windows path normalization and a migration report with redacted item names only.
- [ ] **Step 3: Implement** keyring-first credential storage with an explicit file-based compatibility path only where the existing contract requires it.
- [ ] **Step 4: Verify** no migration path prints passwords, API keys, token contents, or secret file contents.
- [ ] **Step 5: Run** focused unit and Windows migration tests with the existing `.aap-demo` state fixture.
- [ ] **Step 6: Commit** `feat: migrate Windows v1 state into Python CLI`.

### Task 4: Complete Windows CRC and cluster lifecycle parity

**Files:**

- Modify: `src/aap_demo/infra/crc.py`
- Modify: `src/aap_demo/exec/ssh.py`
- Modify: `src/aap_demo/cluster/preflight.py`
- Modify: `src/aap_demo/cluster/kubeconfig.py`
- Modify: `src/aap_demo/cli/lifecycle.py`
- Test: `tests/unit/test_infra_crc.py`, `tests/unit/test_exec_ssh.py`, `tests/unit/test_cluster_preflight.py`, `tests/unit/test_cluster_kubeconfig.py`
- Test: `tests/integration/test_deploy_live.py`

**Interfaces:**

- CRC states are `not_created`, `stopped`, `starting`, `running`, and `unreachable`, with stable exit codes and actionable messages.
- Windows startup requiring elevation is detected and reported; the CLI never hangs waiting for invisible UAC.

- [ ] **Step 1: Fix the two current Windows unit failures** so “no cluster exists” and “CRC not responding but machine exists” are distinguished by machine-directory and command-result evidence.
- [ ] **Step 2: Add tests** for `crc start` launched from an interactive administrator shell versus noninteractive SSH.
- [ ] **Step 3: Implement** bounded CRC status/start polling and a clear handoff to elevated PowerShell when UAC is required.
- [ ] **Step 4: Verify** status, diagnose, kubeconfig extraction, stop, and start against the running CRC demo without redeploying it.
- [ ] **Step 5: Run** the complete non-integration Python suite and the Windows live smoke tests.
- [ ] **Step 6: Commit** `fix: make Python CRC lifecycle reliable on Windows`.

### Task 5: Establish addon ownership, routing, and parity gates

**Files:**

- Modify: `src/aap_demo/addons/__init__.py`
- Modify: `src/aap_demo/cli/addons.py`
- Modify: `src/aap_demo/addons/fleet/*`
- Modify: `src/aap_demo/cli/lifecycle.py`
- Modify: `addons/*/deploy.sh` only where the fallback contract requires a stable v1 entry point
- Test: `tests/unit/test_fleet_addon.py`, `tests/unit/test_product_demos_addon.py`, `tests/unit/test_command_surface.py`
- Create: `tests/system/test_windows_addon_routing.py`

**Interfaces:**

- Python owns the supported v2 addons, initially Fleet v2 and Product Demos where implemented.
- Bash-only addons are invocable through `aap-demo-v1 enable <addon>` and are listed as compatibility paths.
- Python must not claim that an addon is enabled unless it verifies the resulting resource state.

- [ ] **Step 1: Add a machine-readable capability registry** with implementation owner, command, Windows support, and destructive/live-test classification.
- [ ] **Step 2: Add failing routing tests** for Python-owned, Bash-fallback, unavailable, and unknown addons.
- [ ] **Step 3: Implement** explicit fallback routing and consistent output/exit codes.
- [ ] **Step 4: Port only the addons required for the default Windows contract; do not duplicate shell implementations without a parity test.
- [ ] **Step 5: Repair or quarantine Windows-specific tests** that incorrectly assert POSIX modes (`0600`) or rely on Unix tar behavior; replace them with Windows ACL/keyring and binary-archive assertions.
- [ ] **Step 6: Run** addon unit tests plus one live smoke test per Python-owned addon, leaving destructive lifecycle tests opt-in.
- [ ] **Step 7: Commit** `feat: add explicit Windows addon capability routing`.

### Task 6: Add PyPI release, upgrade, rollback, and acceptance gates

**Files:**

- Modify: `pyproject.toml`
- Modify: `.github/workflows/*` release/test workflow(s)
- Modify: `docs/guides/install.md`
- Modify: `docs/reference/windows-python-migration.md`
- Create: `tests/system/test_pypi_smoke.py`

**Interfaces:**

- PyPI smoke test installs the wheel into a clean venv and verifies version, help, status/diagnose command construction, and bundled addon assets.
- Rollback removes or deactivates only the Python console script and restores `aap-demo-v1`; it does not alter CRC or cluster state.

- [ ] **Step 1: Add a clean-venv PyPI smoke test** that installs the published artifact, runs `aap-demo --version`, and checks the entry point points into the isolated environment.
- [ ] **Step 2: Add wheel-content checks** for bundled Product Demos and required data/manifests.
- [ ] **Step 3: Add release gates** for Python unit tests, Windows launcher tests, package build, wheel install, and PyPI smoke execution.
- [ ] **Step 4: Document** upgrade, rollback, `aap-demo-v1`, and recovery after a failed migration.
- [ ] **Step 5: Perform a staged acceptance run** on the current Windows host: install PyPI v2, verify existing cluster status, run diagnose, verify gateway API, test Python-owned addons, and confirm v1 fallback.
- [ ] **Step 6: Commit** `test: add Windows PyPI acceptance gates`.

## Rollout Sequence

1. Land Tasks 1–3 while Bash v1 remains the default.
2. Land Task 4 and fix the two currently failing Windows Python tests.
3. Land Task 5 with explicit fallback routing; do not remove Bash v1.
4. Publish a release candidate and pass Task 6’s clean-venv PyPI smoke tests.
5. Switch the Windows installer/launcher default to PyPI v2.
6. Keep `aap-demo-v1` available for at least one release cycle and publish the rollback command.
7. Remove Bash v1 only after every addon in the capability registry has a Python owner and a live Windows acceptance test.

## Acceptance Checklist

- [ ] A clean Windows machine can install Python v2 from PyPI without requiring a source checkout.
- [ ] Existing CRC/AAP state remains intact after install, update, migration, and rollback.
- [ ] `aap-demo --version` identifies the Python package and Python runtime; `aap-demo-v1 --version` identifies the legacy shell implementation.
- [ ] `aap-demo status` and `aap-demo diagnose` work against the existing MicroShift kubeconfig.
- [ ] Unsupported addons produce an explicit Bash fallback command.
- [ ] No secret values appear in migration, install, test, or diagnostic output.
- [ ] Python unit tests, Windows launcher tests, package build tests, and PyPI smoke tests pass.
- [ ] Live destructive addon tests remain opt-in and are never part of the default install check.
