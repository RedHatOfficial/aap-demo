# Contributing to aap-demo

Thank you for contributing to aap-demo. This document provides guidelines for code quality, commit messages,
and the development workflow.

## Table of Contents

- [Development Setup](#development-setup)
- [Code Quality](#code-quality)
- [Commit Message Format](#commit-message-format)
- [Pull Request Process](#pull-request-process)
- [Linting Tools](#linting-tools)

## Development Setup

### Prerequisites

- Bash 4.0+
- Python 3.11+
- Node.js 20+ (for commitlint)
- Git 2.0+

### Install Pre-commit Hooks

```bash
# Install pre-commit
pip install pre-commit

# Install the git hooks
pre-commit install --hook-type pre-commit --hook-type commit-msg

# Run on all files to verify setup
pre-commit run --all-files
```

### Optional: Install Individual Linters

```bash
# ShellCheck (shell script linter)
brew install shellcheck  # macOS
sudo apt install shellcheck  # Ubuntu/Debian

# yamllint (YAML linter)
pip install yamllint

# markdownlint (Markdown linter)
npm install -g markdownlint-cli

# ansible-lint (Ansible linter)
pip install ansible-lint

# detect-secrets (secret detection)
pip install detect-secrets

# shfmt (shell formatter)
brew install shfmt  # macOS
# or download from https://github.com/mvdan/sh/releases
```

## Code Quality

### Shell Scripts

All shell scripts must:

1. Start with `#!/usr/bin/env bash`
2. Use `set -e` or equivalent error handling
3. Pass ShellCheck with severity warning or higher
4. Follow 2-space indentation
5. Use meaningful variable names with braces: `${VARIABLE}`

Example:

```bash
#!/usr/bin/env bash
set -e

NAMESPACE="${NAMESPACE:-aap-operator}"

function deploy_aap() {
  local cr_file="$1"
  kubectl apply -f "${cr_file}" -n "${NAMESPACE}"
}
```

### YAML Files

All YAML files must:

1. Use 2-space indentation
2. Pass yamllint validation
3. For Kubernetes manifests: use standard apiVersion/kind/metadata/spec structure
4. Keep lines under 120 characters

### Markdown Files

All Markdown files must:

1. Use ATX-style headings (`#` not underlines)
2. Keep lines under 120 characters (soft limit)
3. Use consistent list styles (dashes for unordered, numbers for ordered)
4. Pass markdownlint validation

## Commit Message Format

We use [Conventional Commits](https://www.conventionalcommits.org/) specification.

### Format

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

### Types

- **feat**: New feature
- **fix**: Bug fix
- **docs**: Documentation changes
- **style**: Code style changes (formatting, no logic change)
- **refactor**: Code refactoring (no feature change or bug fix)
- **perf**: Performance improvement
- **test**: Adding or updating tests
- **build**: Build system or dependency changes
- **ci**: CI/CD pipeline changes
- **chore**: Other changes (maintenance, tooling)
- **revert**: Revert a previous commit

### Examples

```
feat: add idle_aap support for resource scaling

Add idle_aap true/false command to scale AAP components
up and down via the gateway operator.

Closes #123
```

```
fix: resolve DNS issues after CRC restart

CoreDNS configuration was not persisted across restarts.
Now applying config on every start command.

Fixes #456
```

```
docs: update QUICK-START with troubleshooting steps
```

### Scope (Optional)

Use scope to specify what part of the codebase is affected:

- `crc`: OpenShift Local cluster management
- `aap`: AAP deployment
- `storage`: Storage (NFS, LVMS, PVC)
- `olm`: Operator Lifecycle Manager
- `addons`: Addons (console, registry, etc.)
- `ci`: CI/CD workflows

Example: `feat(storage): add LVMS storage class support`

## Pull Request Process

### Before Creating a PR

1. Run all linters locally:

   ```bash
   pre-commit run --all-files
   ```

2. Test your changes:

   ```bash
   # For shell scripts
   bash -n script.sh

   # For aap-demo commands
   ./aap-demo.sh help
   ./aap-demo.sh status --dry-run
   ```

3. Update documentation if needed

### PR Checklist

- [ ] Code passes all linters (shellcheck, yamllint, markdownlint)
- [ ] Commits follow conventional commits format
- [ ] PR title follows conventional commits format
- [ ] Tests pass (if applicable)
- [ ] Documentation updated (if needed)
- [ ] No secrets committed (checked by detect-secrets)

### PR Title Format

PR titles must follow the same format as commit messages:

```
feat: Add new deployment option
fix: Resolve PVC pending issue
docs: Update installation guide
```

### Review Process

1. All automated checks must pass
2. At least one approval required
3. No unresolved conversations
4. Branch must be up to date with main

## Linting Tools

### Running Linters Manually

```bash
# ShellCheck - check all shell scripts
find . -name "*.sh" -exec shellcheck {} \;

# yamllint - check all YAML files
yamllint .

# markdownlint - check all Markdown files
markdownlint .

# ansible-lint - check Ansible content
ansible-lint

# detect-secrets - scan for secrets
detect-secrets scan

# shfmt - format shell scripts
shfmt -w -i 2 -ci -bn .
```

### CI/CD Checks

GitHub Actions automatically runs these checks on every PR:

1. **ShellCheck**: Validates shell script syntax and best practices
2. **yamllint**: Validates YAML formatting and structure
3. **markdownlint**: Validates Markdown formatting
4. **ansible-lint**: Validates Ansible playbooks and roles
5. **commitlint**: Validates commit message format
6. **detect-secrets**: Scans for leaked secrets
7. **link-check**: Validates links in Markdown files
8. **manifest-validation**: Validates Kubernetes manifests with kubeconform

### Auto-fixing Issues

Some linters can auto-fix issues:

```bash
# markdownlint - fix markdown issues
markdownlint --fix .

# shfmt - format shell scripts
shfmt -w -i 2 -ci -bn .

# pre-commit - run all auto-fixers
pre-commit run --all-files
```

## Questions?

If you have questions about contributing, please:

1. Check existing issues and discussions
2. Open a new issue with the `question` label
3. Join the community chat (if applicable)

Thank you for contributing!
