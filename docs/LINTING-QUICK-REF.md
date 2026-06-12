# Linting Quick Reference

One-page reference for common linting tasks.

## Installation

```bash
./scripts/setup-linting.sh
```

## Daily Commands

```bash
# Before committing
make lint                    # Run all linters
make format                  # Auto-fix formatting

# Run specific linters
make lint-shell             # ShellCheck
make lint-yaml              # yamllint
make lint-markdown          # markdownlint

# Pre-commit
pre-commit run --all-files  # Run all hooks manually

# Local CI
make ci                     # Run all CI checks
```

## Commit Message Format

```
type(scope): subject

Examples:
  feat: add idle_aap command
  fix(storage): resolve PVC pending
  docs: update installation guide
```

**Types**: feat, fix, docs, style, refactor, perf, test, build, ci, chore

## Inline Disable

### ShellCheck

```bash
# shellcheck disable=SC2086
echo $VARIABLE
```

### yamllint

```yaml
# yamllint disable-line rule:line-length
long_line: "..."
```

### markdownlint

```markdown
<!-- markdownlint-disable MD013 -->
Long line
<!-- markdownlint-enable MD013 -->
```

## Common Fixes

### Quote variables

```bash
# Bad
echo $VAR

# Good
echo "${VAR}"
```

### YAML line length

```yaml
# Bad
description: Very long description that exceeds limit

# Good
description: >
  Very long description
  that exceeds limit
```

### Conventional commits

```bash
# Bad
git commit -m "Added feature"

# Good
git commit -m "feat: add new feature"
```

## Emergency Bypass

```bash
# Skip pre-commit (NOT RECOMMENDED)
git commit --no-verify -m "fix: emergency"
```

## Help

```bash
make help                   # Show all make targets
pre-commit run --help       # Pre-commit help
shellcheck --help           # ShellCheck help
```

## Files

| Tool | Config File |
|------|-------------|
| pre-commit | `.pre-commit-config.yaml` |
| shellcheck | `.shellcheckrc` |
| yamllint | `.yamllint` |
| markdownlint | `.markdownlint.json` |
| commitlint | `.commitlintrc.json` |

## Docs

- [LINTING.md](LINTING.md) - Full documentation
- [CONTRIBUTING.md](CONTRIBUTING.md) - Contribution guide
- [LINTING-SETUP.md](LINTING-SETUP.md) - Setup summary
