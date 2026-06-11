# Linting Setup Summary

This document provides a quick reference for the linting infrastructure set up in this repository.

## Quick Start

```bash
# One-time setup (creates .venv-lint, installs all tools + hooks)
./scripts/setup-linting.sh

# Hooks auto-run on commit (no activation needed)
git commit -m "feat: my changes"

# Manual lint (activate venv first)
source .venv-lint/bin/activate
pre-commit run --all-files
make lint
```

**Important**: All Python linting tools are installed in `.venv-lint/` to avoid conflicts. Pre-commit hooks
automatically activate this venv.

## Files Created

### Configuration Files

| File | Purpose |
|------|---------|
| `.pre-commit-config.yaml` | Pre-commit hooks configuration (all linters) |
| `.shellcheckrc` | ShellCheck configuration and rules |
| `.yamllint` | yamllint configuration |
| `.markdownlint.json` | markdownlint rules |
| `.ansible-lint` | ansible-lint configuration |
| `.commitlintrc.json` | Conventional commit rules |
| `.editorconfig` | Editor settings (indentation, line endings, encoding) |
| `.secrets.baseline` | detect-secrets baseline for secret scanning |
| `.markdown-link-check.json` | Link checker configuration |

### GitHub Actions Workflows

| File | Purpose | Triggers |
|------|---------|----------|
| `.github/workflows/lint.yaml` | Main linting workflow | PR, push to main |
| `.github/workflows/commitlint.yaml` | Commit message validation | PR |
| `.github/workflows/test.yaml` | Syntax and dry-run tests | PR, push to main |
| `.github/workflows/pr-checks.yaml` | PR metadata validation | PR |

### Documentation

| File | Purpose |
|------|---------|
| `docs/CONTRIBUTING.md` | Contribution guidelines and workflow |
| `docs/LINTING.md` | Comprehensive linting documentation |
| `docs/LINTING-SETUP.md` | This file - setup summary |

### Scripts and Makefiles

| File | Purpose |
|------|---------|
| `scripts/setup-linting.sh` | Automated linter installation script |
| `lint.mk` | Make targets for linting operations |
| `Makefile` | Updated to include lint.mk |

## Linters Configured

### 1. ShellCheck

**Purpose**: Shell script analysis and best practices
**Files**: `*.sh`
**Config**: `.shellcheckrc`
**Command**: `shellcheck script.sh`

### 2. yamllint

**Purpose**: YAML syntax and formatting validation
**Files**: `*.yaml`, `*.yml`
**Config**: `.yamllint`
**Command**: `yamllint .`

### 3. markdownlint

**Purpose**: Markdown formatting and style
**Files**: `*.md`
**Config**: `.markdownlint.json`
**Command**: `markdownlint .`

### 4. ansible-lint

**Purpose**: Ansible playbook and role best practices
**Files**: Ansible playbooks, roles
**Config**: `.ansible-lint`
**Command**: `ansible-lint`

### 5. detect-secrets

**Purpose**: Secret detection and prevention
**Files**: All files
**Config**: `.secrets.baseline`
**Command**: `detect-secrets scan`

### 6. commitlint

**Purpose**: Conventional commit message enforcement
**Target**: Commit messages
**Config**: `.commitlintrc.json`
**Format**: `type(scope): subject`

### 7. shfmt

**Purpose**: Shell script formatting
**Files**: `*.sh`
**Config**: `.editorconfig`
**Command**: `shfmt -w -i 2 -ci -bn .`

## Installation and Usage

### Installation

```bash
# Run automated setup script
./scripts/setup-linting.sh

# Or manual installation
pip install pre-commit yamllint ansible-lint detect-secrets
npm install -g markdownlint-cli @commitlint/cli @commitlint/config-conventional
brew install shellcheck shfmt  # macOS

# Install pre-commit hooks
pre-commit install --hook-type pre-commit --hook-type commit-msg
```

### Usage

```bash
# Run all linters
make lint

# Run specific linters
make lint-shell      # ShellCheck only
make lint-yaml       # yamllint only
make lint-markdown   # markdownlint only

# Auto-format code
make format

# Run all CI checks locally
make ci

# Run pre-commit manually
pre-commit run --all-files
```

## GitHub Actions Checks

Every pull request triggers:

1. **Lint workflow**: Runs all linters (shellcheck, yamllint, markdownlint, ansible-lint, etc.)
2. **Commit lint workflow**: Validates commit messages and PR title
3. **Test workflow**: Shell syntax checks, dry-run tests, link validation
4. **PR checks workflow**: Metadata validation, size check, conflict detection

All checks must pass before merging.

## Commit Message Format

Required format:

```
type(scope): subject

body

footer
```

**Types**: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`

**Examples**:

```
feat(storage): add LVMS support
fix: resolve DNS issues after restart
docs: update installation guide
```

## Branch Protection Recommendations

Configure the following branch protection rules for `main`:

### Required Status Checks

- `ShellCheck`
- `YAML Lint`
- `Markdown Lint`
- `Ansible Lint`
- `Conventional Commits`
- `PR Title Check`
- `Shell Syntax Check`

### Protection Rules

- [x] Require pull request before merging
- [x] Require approvals: 1
- [x] Dismiss stale approvals when new commits are pushed
- [x] Require status checks to pass before merging
- [x] Require branches to be up to date before merging
- [x] Require conversation resolution before merging
- [x] Do not allow bypassing the above settings

## Common Tasks

### Add a new linter

1. Add to `.pre-commit-config.yaml`
2. Add config file (if needed)
3. Add to `.github/workflows/lint.yaml`
4. Add to `lint.mk`
5. Update `docs/LINTING.md`

### Disable a specific check

**In code** (inline):

```bash
# shellcheck disable=SC2086
echo $VARIABLE
```

**In config** (globally):

```yaml
# .shellcheckrc
disable=SC2086
```

### Update all linters

```bash
pre-commit autoupdate
# or
make update-hooks
```

## Troubleshooting

### Pre-commit hooks not running

```bash
pre-commit uninstall
pre-commit install --hook-type pre-commit --hook-type commit-msg
```

### Linter not found

```bash
# Check installation
which shellcheck yamllint markdownlint

# Reinstall if needed
./scripts/setup-linting.sh
```

### Bypass hooks (emergency only)

```bash
git commit --no-verify -m "emergency fix"
```

Note: CI will still validate the commit.

## References

- [CONTRIBUTING.md](CONTRIBUTING.md) - Full contribution guidelines
- [LINTING.md](LINTING.md) - Detailed linting documentation
- [Pre-commit documentation](https://pre-commit.com/)
- [Conventional Commits](https://www.conventionalcommits.org/)

## Adding Status Badges to README

Add these badges to the main README.md:

```markdown
[![Lint](https://github.com/YOUR-ORG/aap-demo/workflows/Lint/badge.svg)](https://github.com/YOUR-ORG/aap-demo/actions/workflows/lint.yaml)
[![Commit Lint](https://github.com/YOUR-ORG/aap-demo/workflows/Commit%20Lint/badge.svg)](https://github.com/YOUR-ORG/aap-demo/actions/workflows/commitlint.yaml)
[![Test](https://github.com/YOUR-ORG/aap-demo/workflows/Test/badge.svg)](https://github.com/YOUR-ORG/aap-demo/actions/workflows/test.yaml)
[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit&logoColor=white)](https://github.com/pre-commit/pre-commit)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-yellow.svg)](https://conventionalcommits.org)
```

## Next Steps

1. Run the setup script: `./scripts/setup-linting.sh`
2. Test the installation: `pre-commit run --all-files`
3. Fix any existing violations: `make format` then `make lint`
4. Configure GitHub branch protection rules
5. Update README.md with status badges
6. Communicate changes to contributors

## Support

For questions or issues with the linting setup:

1. Check [LINTING.md](LINTING.md) for detailed troubleshooting
2. Check [CONTRIBUTING.md](CONTRIBUTING.md) for workflow guidelines
3. Open an issue with the `tooling` or `ci` label
