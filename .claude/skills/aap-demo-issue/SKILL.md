---
name: aap-demo-issue
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

# aap-demo-issue Skill

Guide users through creating well-structured GitHub issues for the aap-demo project, ensuring consistency with existing templates and project conventions.

## Core Principle: Tight Scoping

**CRITICAL**: Issues must be as tightly scoped as possible.

### For Enhancements/Features
- **One specific capability or change** per issue
- **Single, focused outcome** with clear acceptance criteria
- **Minimal implementation details** - describe what and why, not how
- If bundling multiple concerns, split into separate issues

### For Bug Reports
- **Specific error or failure** with reproduction steps
- **Complete diagnostic information**: logs, `aap-demo diagnose` output, environment
- **Observable symptom** that can be verified as fixed

**What makes a good bug report**:
- Reproduction steps that consistently trigger the bug
- Error logs showing the actual failure
- Output from `aap-demo diagnose` or `must-gather`
- Environment details (INFRA, OS, addons, versions)

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
Required information:
- Affected documentation area (Quick Start, Commands, Addons, etc.)
- Current state of documentation
- Proposed changes or additions
- Whether it's a clarification, addition, or correction

**Labels**: `type: documentation`

### Feature Requests / Enhancements
**Template**: Markdown format

**KEEP IT TIGHT**: One specific capability per issue. If you find yourself listing multiple implementation steps, split into separate issues.

Required information:
- **Problem**: What specific need does this address? (1-2 sentences)
- **Proposed Solution**: What single capability should be added? (1-2 sentences)
- **Expected Outcome**: How will users know it works? (2-3 bullet points)
- **Context**: Brief relevant background (ADRs, existing patterns)
- **ADR Required**: Yes/No for architectural decisions

**Omit from issues**:
- Step-by-step implementation plans
- Code examples or pseudocode
- Detailed technical design
- Multiple phases or stages

**Labels**: `enhancement`, `addon` (if addon-specific)

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

### 3. Populate Issue Fields

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

**For features/enhancements**:
- **Title**: Start with verb + single specific capability (e.g., "Create OAuth2 app in AAP for AO")
- **Problem**: What need does this address? (1-2 sentences max)
- **Proposed Solution**: What one thing should be added? (1-2 sentences max)
- **Expected Outcome**: 2-3 bullet points describing how users verify it works
- **Context**: Brief relevant background (related ADRs, existing patterns)
- **ADR Required**: Yes/No (for architectural decisions)

**DO NOT INCLUDE**:
- Implementation phases or steps
- Technical design details
- Code examples or API signatures
- Multiple related features (split into separate issues)

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

1. **Tightly scoped**: One specific problem or capability per issue - if you find yourself using "and" multiple times in the title, split it
2. **Clear titles**: Descriptive, specific (Bug/Feature/Docs prefix optional if obvious from context)
3. **Reproducible**: Bug reports must include clear reproduction steps and diagnostic output
4. **Complete diagnostics**: For bugs, always include `aap-demo diagnose` output, error logs, environment details
5. **Formatted**: Use code blocks for logs, commands, config files
6. **High-level only**: For features, describe what/why, not how - no implementation plans in the issue

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

**Title**: "Feature: <Single specific capability>" (not "Feature: Add X and Y and Z")

**Required info**:
- Problem: What specific need? (1-2 sentences)
- Proposed Solution: What one capability? (1-2 sentences)
- Expected Outcome: How to verify it works (2-3 bullets)
- Context: Related ADRs, existing patterns
- ADR Required: Yes/No

**Omit**: Implementation phases, code examples, technical design

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

### Example: Creating a Feature Request (Properly Scoped)

```bash
gh issue create --repo RedHatOfficial/aap-demo \
  --title "Feature: Deploy OPA to cluster via addon" \
  --label "enhancement,addon" \
  --body "## Problem

Users need to validate Ansible playbooks against organizational policies before execution, but currently must manually deploy and configure OPA.

## Proposed Solution

Add an OPA addon that deploys Open Policy Agent to the cluster via \`aap-demo enable opa\`.

## Expected Outcome

- \`aap-demo enable opa\` successfully deploys OPA to the cluster
- \`aap-demo status\` shows OPA addon status and route
- \`aap-demo disable opa\` cleanly removes OPA resources

## Context

- Similar pattern to existing addons (portal, ao, mcp-server)
- Integration with AAP would be a separate issue/ADR

## ADR Required

No - follows established addon pattern. Integration architecture would need separate ADR.
"
```

### Example: Feature Request That's Too Broad (Don't Do This)

```bash
# ❌ Too broad - bundles addon creation + AAP integration + policy management
gh issue create --repo RedHatOfficial/aap-demo \
  --title "Feature: Add OPA addon with AAP admission controller integration" \
  --body "...includes deployment, integration, policy samples, AAP webhook config..."

# ✅ Better - split into focused issues:
# Issue 1: "Feature: Deploy OPA to cluster via addon"
# Issue 2: "Feature: Configure AAP to validate playbooks via OPA admission controller"
# Issue 3: "Feature: Add sample OPA policies for common validations"
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
