# AAP Demo Test Suite

Validation tests for `aap-demo.sh` command-line interface.

## test-aap-demo.sh

Comprehensive test script validating all aap-demo commands.

### Usage

```bash
# Run all tests
./test/test-aap-demo.sh

# Quick mode (skip network/interactive tests)
./test/test-aap-demo.sh --quick

# Verbose mode (show failure reasons)
./test/test-aap-demo.sh --verbose

# Combined
./test/test-aap-demo.sh --quick --verbose

# AAP provisioning fast-path test
python3 ./test/test-provision-aap-demos.py

# AO replica profile rendering (no cluster required)
./test/test-ao-replica-profile.sh
```

### Coverage

#### Help/Usage

- ✓ `help`, `-h`, `--help` output
- ✓ No args shows welcome banner

#### Argument Parsing

- ✓ `NAMESPACE`, `QUIET`, `FORCE` env vars
- ✓ Unknown commands error
- ✓ Unknown flags error
- ✓ `--context=NAME` / `--context NAME` parsing
- ✓ `--kubeconfig=PATH` error handling

#### Commands

- ✓ `config` (no args)
- ✓ `redhat-status`, `rh-status` (network skipped in quick mode)
- ✓ `idle [true|false]` arg parsing
- ✓ `idle notabool` shows error
- ✓ `diagnose` runs without cluster
- ✓ `diagnose --ai` flag parsing
- ✓ `enable` / `disable` (no args shows usage)
- ✓ `enable fake-addon` errors
- ✓ `deploy-all`, `redeploy-all` aliases recognized
- ✓ `must-gather [dir]` arg parsing
- ✓ `test [markers]` arg parsing
- ✓ `destroy`, `clean` show warnings (interactive skipped in quick mode)
- ✓ `destroy --reset` flag parsing

### Test Design

Tests validate:

1. **Argument parsing** — flags, env vars, positional args processed correctly
2. **Help text** — all help commands show usage
3. **Error handling** — unknown commands/args produce useful errors
4. **Non-destructive behavior** — tests don't modify cluster state
5. **Graceful degradation** — commands fail cleanly when cluster/AAP missing
6. **AO replica profile rendering** — default one-replica and explicit
   two-replica CR values, validation errors, and operator source-of-truth
   behavior

Tests **do not** validate:

- Actual cluster creation/destruction (would be destructive)
- Full deploy flow (too slow for unit tests)
- Live AAP operations (requires running instance)
- Network endpoints (skipped in `--quick` mode)

### Exit Codes

- **0** — All tests passed
- **1** — One or more tests failed

### Adding Tests

```bash
test_my_new_feature() {
  local output rc
  output=$(_run_aap_demo my-command arg 2>&1) && rc=0 || rc=$?

  if [ $rc -eq 0 ] && echo "$output" | grep -q "expected"; then
    _pass "my_new_feature"
  else
    _fail "my_new_feature" "reason here"
  fi
}

# Add to test execution section at bottom
test_my_new_feature
```

### Known Issues

- Tests may behave differently when cluster exists vs. doesn't exist
- Some commands (like `idle`, `status`) adapt to current cluster state
- Interactive prompts skipped via `QUIET=true` env var

## Live AO clean-install regression scenario

Run this scenario on a disposable local `aap-demo` cluster to verify both the
purge option and first-install admin-password bootstrap. It is intentionally
not part of the default test suite because it deletes the AO database.

```bash
# Remove AO data, OLM resources, namespace, and saved bootstrap password.
CI=true ./aap-demo.sh disable ao --purge-data

# Confirm the local cached password is absent, then install normally.
test ! -e "$HOME/.aap-demo/ao/initial-admin-password"
CI=true ./aap-demo.sh enable ao
```

During the enable output, verify:

- `✓ Fresh AO admin password generated` appears before the instance is applied.
- `✓ Route ready` and `✓ Automation Orchestrator operator and instance applied`
  appear.
- The final instance has `READY=True` and `TLSREADY=True`:

```bash
kubectl get automationorchestrator automation-orchestrator \
  -n automation-orchestrator
kubectl get secret automation-orchestrator-initial-admin-password \
  -n automation-orchestrator
```
