---
name: aap-issue-creation
description: >
  Guide users in creating well-structured GitHub issues for the aap-demo project.
  Activates when users want to create issues, report bugs, suggest features, or
  document problems. Ensures issues follow project templates and conventions,
  with appropriate labels, context, and test plans.
allowed-tools:
  - Bash(gh *)
  - Bash(git *)
  - Read
argument-hint: "[issue type or description]"
---

# aap-issue-creation Skill

Guide users through creating well-structured GitHub issues for the aap-demo project, ensuring consistency with existing templates and project conventions.

## When to Use

- Reporting bugs or deployment failures
- Requesting features or enhancements
- Documenting issues with documentation or missing docs
- Proposing new addons
- Any time a GitHub issue needs to be created for aap-demo

## Issue Types and Templates

### Bug Reports
**Template**: `.github/ISSUE_TEMPLATE/bug_report.yaml`

Required information:
- Problem summary with clear description
- Steps to reproduce
- Expected vs actual behavior
- Environment details (INFRA type, addons, MicroShift version)
- Diagnostic output from `aap-demo diagnose` or `must-gather`
- Error logs and stack traces

**Labels**: `type: bug`, relevant component labels

### Documentation Issues
**Template**: `.github/ISSUE_TEMPLATE/documentation.yaml`

Required information:
- Affected documentation area (Quick Start, Commands, Addons, etc.)
- Current state of documentation
- Proposed changes or additions
- Whether it's a clarification, addition, or correction

**Labels**: `type: documentation`

### Feature Requests / Enhancements
**Template**: Markdown format (see `github-plugin-apme.md` as example)

Required information:
- Clear problem statement and use case
- Proposed solution
- Implementation considerations (addon vs core command vs both)
- Whether an ADR is needed for architectural decisions
- Alternatives considered

**Labels**: `type: enhancement`, `type: feature`

### Addon-Specific Issues
For issues related to specific addons, include:
- Addon name in title (e.g., "Bug: portal addon fails on ARM")
- Addon status from `aap-demo status`
- Addon-specific logs or diagnostics

**Labels**: `addon:<addon-name>`

## Workflow

### 1. Check for Duplicates
Before creating any issue, search existing issues to prevent duplicates:

```bash
gh issue list --repo RedHatOfficial/aap-demo --search "<keywords>"
```

Or use GitHub MCP tools:
```
mcp__github__search_issues with query matching the problem
```

If duplicate found, reference it instead of creating a new issue.

### 2. Gather Context

For **bug reports**, collect:
```bash
# Git context
git branch --show-current
git log --oneline -5

# Environment
cat ~/.aap-demo/config

# Current deployment state
aap-demo status

# Diagnostics (if cluster is running)
aap-demo diagnose
```

For **features/enhancements**, identify:
- Related ADRs (search `docs/adr/`)
- Existing similar functionality
- Affected components

### 3. Select Appropriate Template

Read available templates:
```bash
ls -1 .github/ISSUE_TEMPLATE/
```

Templates:
- **bug_report.yaml** — Structured bug reports (YAML form)
- **documentation.yaml** — Documentation issues (YAML form)
- **github-plugin-apme.md** — Example markdown template for feature work

Choose based on issue type.

### 4. Populate Issue Fields

**For bug reports**:
- **Problem Summary**: Clear, concise description
- **Steps to Reproduce**: Numbered steps
- **Expected Behavior**: What should happen
- **Actual Behavior**: What actually happens
- **Environment**: 
  - INFRA type (crc, minc, lab)
  - Enabled addons
  - MicroShift/OpenShift version
  - OS (macOS, Linux, Windows)
- **Diagnostic Output**: Paste relevant `aap-demo diagnose` output
- **Logs**: Include error messages, stack traces
- **Additional Context**: Screenshots, configuration files

**For documentation issues**:
- **Area**: Select from dropdown (Quick Start, Commands, Addons, etc.)
- **Proposed Changes**: Detailed description of what to add/fix/clarify
- **Affected Files**: List files needing updates
- **Priority**: Critical gap vs nice-to-have

**For features**:
- **Title**: Start with verb (Add, Support, Enable, etc.)
- **Problem**: What need does this address?
- **Proposed Solution**: High-level approach
- **Implementation**: Addon, core command, both?
- **ADR Required**: Yes/No (significant architectural changes need ADRs)
- **Alternatives**: Other approaches considered
- **Test Plan**: How to verify the feature works

### 5. Apply Labels

Common label patterns:
- **Type**: `type: bug`, `type: enhancement`, `type: documentation`, `type: feature`
- **Component**: `addon:<name>`, `platform: windows`, `platform: linux`, `platform: macos`
- **Priority**: `priority: high`, `priority: critical`
- **Status**: `status: needs-triage`, `good first issue`

### 6. Create Issue

**Using GitHub CLI** (preferred):
```bash
gh issue create --repo RedHatOfficial/aap-demo \
  --title "Bug: Deployment fails with PVC pending" \
  --body-file issue-body.md \
  --label "type: bug"
```

**Using GitHub MCP** (if available):
```
mcp__github__create_issue with:
  - owner: RedHatOfficial
  - repo: aap-demo
  - title: <descriptive title>
  - body: <formatted body>
  - labels: [appropriate labels]
```

**Interactive mode**:
```bash
gh issue create --repo RedHatOfficial/aap-demo --web
```

### 7. Return Issue URL

After creation, provide the issue URL to the user:
```
Issue created: https://github.com/RedHatOfficial/aap-demo/issues/NNN
```

## Best Practices

### Before Creating an Issue

1. **Search first**: Always check for duplicates
2. **Run diagnostics**: For bugs, run `aap-demo diagnose` first
3. **Gather context**: Collect environment details, logs, reproduction steps
4. **Check existing docs**: Issue might be documented in README, ADRs, or troubleshooting guides

### Issue Quality

1. **Clear titles**: Descriptive, specific, starts with type (Bug, Feature, Docs)
2. **Reproducible**: Bug reports should include clear reproduction steps
3. **Complete**: All required template fields populated
4. **Formatted**: Use code blocks for logs, commands, config files
5. **Scoped**: One issue per problem/feature (split if too broad)

### Environment Details to Include

For any bug report, include:
```markdown
## Environment

- **INFRA**: crc / minc / lab
- **OS**: macOS 14.5 / Ubuntu 22.04 / Windows 11
- **Enabled addons**: mcp-server, portal, ao
- **AAP version**: 2.7 (from kubectl get aap -o yaml)
- **MicroShift version**: 4.16.3 (from crc version)
```

### Diagnostic Commands

Run these before creating bug reports:

```bash
# Quick health check
aap-demo diagnose

# Full diagnostics bundle
aap-demo must-gather

# Specific component logs
kubectl logs -l app.kubernetes.io/managed-by=aap-gateway-operator -n aap-operator --tail=100

# Pod status
kubectl get pods -n aap-operator

# Route status
kubectl get routes -n aap-operator
```

## Common Issue Patterns

### Deployment Failures

**Title**: "Bug: AAP deployment fails at <stage>"

**Required info**:
- Output of `aap-demo diagnose`
- Operator logs
- Failed pod descriptions
- Storage class status (for PVC issues)

### Addon Issues

**Title**: "Bug: <addon-name> addon <specific problem>"

**Required info**:
- Output of `aap-demo status <addon>`
- Addon deploy.sh output
- Addon-specific logs
- Prerequisites verification

### Documentation Gaps

**Title**: "Docs: Missing documentation for <topic>"

**Required info**:
- What is undocumented
- Where users would expect to find it
- Proposed documentation structure
- Related ADRs or code

### Feature Requests

**Title**: "Feature: Add <capability>"

**Required info**:
- Use case and motivation
- How this fits with existing functionality
- Implementation approach (addon, core, both)
- Whether ADR needed
- Test plan

## Examples

### Example: Creating a Bug Report

```bash
# 1. Search for duplicates
gh issue list --repo RedHatOfficial/aap-demo --search "PVC pending"

# 2. Gather diagnostics
aap-demo diagnose > /tmp/diagnostics.txt

# 3. Get environment
cat ~/.aap-demo/config

# 4. Create issue
gh issue create --repo RedHatOfficial/aap-demo \
  --title "Bug: aap-hub-file-storage PVC stuck in Pending state" \
  --label "type: bug" \
  --body "## Problem Summary
  
AAP deployment fails with aap-hub-file-storage PVC stuck in Pending state.

## Steps to Reproduce

1. aap-demo destroy
2. aap-demo create
3. aap-demo deploy
4. Observe PVC status: kubectl get pvc -n aap-operator

## Expected Behavior

PVC should bind to nfs-local-rwx StorageClass and become Bound within 2 minutes.

## Actual Behavior

PVC remains in Pending state indefinitely. Deployment does not complete.

## Environment

- INFRA: crc
- OS: macOS 14.5
- Enabled addons: none
- MicroShift version: 4.16.3

## Diagnostic Output

\`\`\`
$(cat /tmp/diagnostics.txt)
\`\`\`

## Additional Context

kubectl describe pvc aap-hub-file-storage -n aap-operator shows:
\`\`\`
Events:
  Type     Reason              Message
  ----     ------              -------
  Warning  ProvisioningFailed  Failed to provision volume: no StorageClass named nfs-local-rwx
\`\`\`
"
```

### Example: Creating a Feature Request

```bash
gh issue create --repo RedHatOfficial/aap-demo \
  --title "Feature: Add OPA (Open Policy Agent) addon" \
  --label "type: enhancement" \
  --body "## Problem

Users need to validate Ansible playbooks against organizational policies before execution.

## Proposed Solution

Create an OPA addon that:
- Deploys OPA to the cluster
- Integrates with AAP via admission controller
- Provides sample policies for common validations

## Implementation

- **Type**: Addon (addons/opa/)
- **ADR Required**: Yes (integration architecture)
- **Dependencies**: AAP deployed

## Alternatives

1. External OPA instance (requires network config)
2. Built-in AAP validation (not flexible enough)

## Test Plan

- [ ] aap-demo enable opa successfully deploys OPA
- [ ] Sample policy blocks non-compliant playbooks
- [ ] aap-demo disable opa cleanly removes resources
"
```

## Integration with Other Skills

- **aap-adr skill**: When feature requires architectural decision, create ADR first
- **aap-addon-development skill**: Addon issues may lead to new addon development
- Use issue creation to track implementation of ADRs or addons

## Error Handling

If `gh` CLI is not available:
```bash
# Fallback to web interface
open "https://github.com/RedHatOfficial/aap-demo/issues/new/choose"
```

If GitHub MCP is unavailable:
- Fall back to `gh` CLI
- If both unavailable, provide formatted issue body for manual creation

If template is missing:
- Use generic markdown format
- Follow examples from existing issues
