# ADR-014: CLI Testing Strategy

**Status**: Accepted

**Date**: 2026-06-12

**Authors**: aap-demo maintainers

## Context

aap-demo is primarily a shell CLI orchestrating cluster operations. Full integration tests (create → deploy → destroy) are:

- Slow (15–30 minutes)
- Destructive
- Require pull secrets, CRC, and significant RAM
- Impractical in CI for every PR

Contributors still need confidence that argument parsing, help text, and error paths work after changes.

## Decision

Use **non-destructive CLI integration tests** that validate the command surface without requiring a running cluster.

### Test suites

| Script | Scope |
|--------|-------|
| `test/test-core-commands.sh` | Subset documented in README |
| `test/test-aap-demo.sh` | Comprehensive CLI coverage |

### What tests validate

1. **Argument parsing** — env vars (`NAMESPACE`, `QUIET`, `FORCE`), flags (`--ai`, `--reset`, `--context`)
2. **Help text** — `help`, `-h`, `--help`, welcome banner on no args
3. **Error handling** — unknown commands, unknown addons, invalid `idle` args
4. **Non-destructive execution** — `diagnose` runs without cluster; destructive commands grep-checked for warnings only
5. **Graceful degradation** — commands fail cleanly when cluster absent

### What tests explicitly skip

- Actual `create` / `destroy` / full `deploy` (destructive or slow)
- Live AAP API operations
- Network endpoints (in `--quick` mode)
- Interactive prompts (suppressed via `QUIET=true`)

### CI integration

`.github/workflows/test.yaml` runs test scripts on PRs. `.github/workflows/lint.yaml` runs
shellcheck, yamllint, ansible-lint, and markdownlint via `lint.mk` / pre-commit.

### Test patterns

```bash
# Capture output and exit code without side effects
output=$(_run_aap_demo my-command 2>&1) && rc=0 || rc=$?
echo "$output" | grep -q "expected string"
```

Mocking used where commands would touch CRC (e.g., `start`/`stop` delegation checks).

## Consequences

### Positive

- Fast PR feedback (< 1 minute for CLI tests)
- No pull secret or cluster required in CI
- Documents expected CLI behavior in executable form
- `--quick` and `--verbose` modes for local dev

### Negative

- Does not catch regressions in actual OpenShift deploy logic
- grep-based assertions brittle to wording changes
- Bash tests don't cover PowerShell implementation (ADR-010 gap)
- Cluster-state-dependent commands behave differently when CRC exists

### Neutral

- Manual testing still required for release validation
- `aap-demo test` (ATF) is separate — requires deployed AAP and VPN for internal collections

## Alternatives Considered

### Full E2E in CI with CRC

Rejected: resource cost, pull secret management, and 30+ minute runs.

### Pure unit tests (bats with heavy mocking)

Rejected: mock maintenance cost high for monolithic bash script.

### No automated tests

Rejected: CLI regressions are common with argument parsing changes.

## References

- [test/README.md](../../test/README.md)
- [test/test-core-commands.sh](../../test/test-core-commands.sh)
- [.github/workflows/test.yaml](../../.github/workflows/test.yaml)
- [ADR-001](001-project-cli-architecture.md)
- [ADR-010](010-cross-platform-cli.md)
