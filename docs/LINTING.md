# Linting and Code Quality

This document describes the linting and code quality tools configured for aap-demo.

## Overview

The repository uses multiple linters to ensure code quality and consistency:

- **ShellCheck**: Shell script linting and best practices
- **yamllint**: YAML formatting and syntax validation
- **markdownlint**: Markdown formatting and style
- **ansible-lint**: Ansible playbook and role best practices
- **detect-secrets**: Secret detection and prevention
- **commitlint**: Conventional commit message enforcement
- **shfmt**: Shell script formatting

## Quick Start

### Install Pre-commit

```bash
# Install pre-commit
pip install pre-commit

# Install git hooks
pre-commit install --hook-type pre-commit --hook-type commit-msg

# Run on all files
pre-commit run --all-files
```

### Using Make

```bash
# Run all linters
make lint

# Run specific linters
make lint-shell
make lint-yaml
make lint-markdown
make lint-ansible

# Auto-format code
make format

# Run all CI checks locally
make ci

# Update pre-commit hooks
make update-hooks
```

## Linters in Detail

### ShellCheck

Analyzes shell scripts for common mistakes and best practices.

**Configuration**: `.shellcheckrc`

**Key rules**:

- Use `set -e` for error handling
- Quote variables: `"${VARIABLE}"`
- Use `[[` instead of `[` for conditionals
- Avoid useless `cat` and `echo`

**Run manually**:

```bash
shellcheck script.sh
find . -name "*.sh" -exec shellcheck {} \;
```

**Disable specific warnings**:

```bash
# shellcheck disable=SC2181
if [ $? -ne 0 ]; then
  echo "Command failed"
fi
```

### yamllint

Validates YAML files for syntax and formatting.

**Configuration**: `.yamllint`

**Key rules**:

- 2-space indentation
- 120 character line length
- Proper comment spacing
- Consistent key ordering

**Run manually**:

```bash
yamllint .
yamllint config/manifests/
```

**Inline disable**:

```yaml
# yamllint disable-line rule:line-length
very_long_line: "This line is intentionally long and won't trigger line-length warning"
```

### markdownlint

Ensures consistent Markdown formatting.

**Configuration**: `.markdownlint.json`

**Key rules**:

- ATX-style headings (`#` not underlines)
- 120 character line length (soft)
- Consistent list styles
- Proper code block formatting

**Run manually**:

```bash
markdownlint .
markdownlint --fix .  # Auto-fix issues
```

**Inline disable**:

```markdown
<!-- markdownlint-disable MD013 -->
This is a very long line that won't be flagged
<!-- markdownlint-enable MD013 -->
```

### ansible-lint

Validates Ansible playbooks and roles.

**Configuration**: `.ansible-lint`

**Key rules**:

- Use fully qualified collection names
- Task names should be descriptive
- Avoid command module when alternatives exist
- Use `changed_when` for command tasks

**Run manually**:

```bash
ansible-lint
ansible-lint playbook.yml
```

**Skip specific rules**:

```yaml
- name: Example task
  command: /bin/custom-command
  tags:
    - skip_ansible_lint
```

### detect-secrets

Scans for accidentally committed secrets.

**Configuration**: `.secrets.baseline`

**Run manually**:

```bash
# Scan for secrets
detect-secrets scan

# Update baseline
detect-secrets scan --baseline .secrets.baseline

# Audit findings
detect-secrets audit .secrets.baseline
```

**Inline allowlist**:

```bash
# pragma: allowlist secret
API_TOKEN="example-key-12345"
```

### commitlint

Enforces conventional commit message format.

**Configuration**: `.commitlintrc.json`

**Format**:

```
type(scope): subject

body

footer
```

**Types**:

- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation
- `style`: Formatting
- `refactor`: Code restructuring
- `perf`: Performance
- `test`: Tests
- `build`: Build system
- `ci`: CI/CD
- `chore`: Maintenance

**Examples**:

```
feat(storage): add LVMS support

Add topolvm-provisioner storage class for RWO volumes.

Closes #123
```

```
fix: resolve DNS issues after restart

CoreDNS config was not persisted.
```

### shfmt

Formats shell scripts consistently.

**Settings** (via `.editorconfig`):

- 2-space indentation
- Space after redirect
- Binary operators at line start
- Switch case indentation

**Run manually**:

```bash
# Check formatting
shfmt -d .

# Fix formatting
shfmt -w -i 2 -ci -bn .
```

## GitHub Actions

Three workflows run on every pull request:

### 1. Lint Workflow (`.github/workflows/lint.yaml`)

Runs all linters:

- ShellCheck
- yamllint
- markdownlint
- ansible-lint
- detect-secrets
- shfmt
- kubeconform (Kubernetes manifest validation)

### 2. Commit Lint Workflow (`.github/workflows/commitlint.yaml`)

Validates:

- All commit messages in PR
- PR title format

### 3. Test Workflow (`.github/workflows/test.yaml`)

Runs:

- Shell syntax checks
- Dry-run tests
- Executable permission checks
- Link validation

## Configuration Files

| File | Purpose |
|------|---------|
| `.pre-commit-config.yaml` | Pre-commit hook configuration |
| `.shellcheckrc` | ShellCheck settings |
| `.yamllint` | yamllint configuration |
| `.markdownlint.json` | markdownlint rules |
| `.ansible-lint` | ansible-lint configuration |
| `.commitlintrc.json` | Conventional commit rules |
| `.editorconfig` | Editor settings (indentation, line endings) |
| `.secrets.baseline` | detect-secrets baseline |
| `.markdown-link-check.json` | Link checker configuration |

## Common Issues and Fixes

### ShellCheck SC2086: Quote variables

**Issue**:

```bash
rm -rf $DIR/*.tmp
```

**Fix**:

```bash
rm -rf "${DIR}"/*.tmp
```

### yamllint: Line too long

**Issue**:

```yaml
description: This is a very long description that exceeds the 120 character limit
```

**Fix**:

```yaml
description: >
  This is a very long description that exceeds
  the 120 character limit
```

### markdownlint MD013: Line too long

**Issue**:

```markdown
This is a very long line of text that exceeds the recommended line length limit.
```

**Fix**:

```markdown
This is a very long line of text that exceeds the recommended
line length limit.
```

Or disable for specific lines:

```markdown
<!-- markdownlint-disable MD013 -->
This is a very long line that won't be flagged.
<!-- markdownlint-enable MD013 -->
```

### ansible-lint: Use FQCN

**Issue**:

```yaml
- name: Install package
  yum:
    name: httpd
```

**Fix**:

```yaml
- name: Install package
  ansible.builtin.yum:
    name: httpd
```

### Commit message rejected

**Issue**:

```
Add new feature
```

**Fix**:

```
feat: add idle_aap command for resource scaling
```

## Bypassing Hooks (Emergency Use Only)

If you need to bypass hooks in an emergency:

```bash
# Skip pre-commit hooks
git commit --no-verify -m "emergency fix"

# Skip commit message validation
SKIP=commitizen git commit -m "emergency fix"
```

**Warning**: Only use in genuine emergencies. All commits will still be validated by CI.

## Updating Linters

```bash
# Update pre-commit hooks to latest versions
pre-commit autoupdate

# Or using make
make update-hooks
```

## IDE Integration

### VS Code

Install extensions:

- [ShellCheck](https://marketplace.visualstudio.com/items?itemName=timonwong.shellcheck)
- [YAML](https://marketplace.visualstudio.com/items?itemName=redhat.vscode-yaml)
- [markdownlint](https://marketplace.visualstudio.com/items?itemName=DavidAnson.vscode-markdownlint)
- [Conventional Commits](https://marketplace.visualstudio.com/items?itemName=vivaxy.vscode-conventional-commits)

Settings (`.vscode/settings.json`):

```json
{
  "shellcheck.enable": true,
  "yaml.validate": true,
  "yaml.format.enable": true,
  "markdown.preview.breaks": true,
  "files.trimTrailingWhitespace": true,
  "files.insertFinalNewline": true,
  "editor.formatOnSave": true
}
```

### Vim/Neovim

Install plugins:

- [ALE](https://github.com/dense-analysis/ale) for linting
- [vim-shellcheck](https://github.com/itspriddle/vim-shellcheck)
- [vim-yaml](https://github.com/stephpy/vim-yaml)

## Troubleshooting

### Pre-commit hooks not running

```bash
# Reinstall hooks
pre-commit uninstall
pre-commit install --hook-type pre-commit --hook-type commit-msg

# Verify installation
ls -la .git/hooks/
```

### Linter not found

```bash
# Install missing linters
pip install pre-commit yamllint ansible-lint detect-secrets
npm install -g markdownlint-cli @commitlint/cli @commitlint/config-conventional
brew install shellcheck shfmt  # macOS
```

### Hook is slow

```bash
# Run specific hooks only
SKIP=ansible-lint git commit -m "feat: quick fix"

# Or disable temporarily
pre-commit uninstall
```

### False positives

If a linter produces false positives:

1. Check if there's a better way to write the code
2. Use inline disable comments (see examples above)
3. Update the configuration file to adjust rules
4. Report the issue to the linter project

## Resources

- [ShellCheck Wiki](https://github.com/koalaman/shellcheck/wiki)
- [yamllint Documentation](https://yamllint.readthedocs.io/)
- [markdownlint Rules](https://github.com/DavidAnson/markdownlint/blob/main/doc/Rules.md)
- [ansible-lint Documentation](https://ansible.readthedocs.io/projects/lint/)
- [Conventional Commits](https://www.conventionalcommits.org/)
- [pre-commit Documentation](https://pre-commit.com/)

## Questions?

See [CONTRIBUTING.md](CONTRIBUTING.md) for general contribution guidelines.
