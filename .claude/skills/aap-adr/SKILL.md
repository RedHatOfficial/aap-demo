---
name: aap-adr
description: >
  Assist in authoring Architecture Decision Records (ADRs) for the aap-demo project.
  Activates when users want to document architectural decisions, create ADRs,
  or update the ADR index. Ensures ADRs follow project conventions with proper
  numbering, format, and comprehensive decision documentation.
allowed-tools:
  - Bash(find *)
  - Bash(ls *)
  - Bash(git *)
  - Read
argument-hint: "[decision topic or ADR number]"
---

# aap-adr Skill

Assist in authoring Architecture Decision Records (ADRs) for the aap-demo project, following established conventions and format.

## What is an ADR?

An Architecture Decision Record (ADR) captures an important architectural decision made along with its context and consequences. ADRs help understand why certain decisions were made and provide a historical record of the project's evolution.

## When to Create an ADR

ADRs should be created for decisions that:

- **Affect addon architecture** (new addon design, integration patterns)
- **Change deployment model** (infrastructure backend changes, storage architecture)
- **Introduce platform support** (Windows support, new OS, new cluster type)
- **Modify CLI behavior** (breaking changes, new command patterns)
- **Change storage or networking** (StorageClass selection, DNS resolution)
- **Update security model** (SCCs, Pod Security, authentication)
- **Establish development patterns** (testing strategy, CI/CD approach)

**Don't create ADRs for**:
- Small bug fixes
- Documentation updates
- Minor refactoring
- Trivial configuration changes

## ADR Format

aap-demo uses a simplified ADR format based on [Michael Nygard's template](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions):

### Required Sections

1. **Title**: `# ADR-NNN: Short Noun Phrase`
2. **Status**: Proposed | Accepted | Deprecated | Superseded
3. **Date**: YYYY-MM-DD
4. **Authors**: Optional (name or leave blank)
5. **Context**: Problem statement, background, constraints
6. **Decision**: Specific approach and implementation
7. **Consequences**: Positive, negative, and neutral impacts
8. **Alternatives Considered**: Other options and why rejected
9. **References**: Related ADRs, issues, PRs, external docs

## Workflow

### 1. Determine Next ADR Number

Scan `docs/adr/` for the highest numbered ADR:

```bash
find docs/adr -name "[0-9]*-*.md" | sort | tail -1
```

Current highest: `031-windows-git-bash-wrapper.md`

**Next number**: 032

Numbers may have gaps (removed or consolidated drafts) — this is acceptable.

### 2. Generate Kebab-Case Title

Convert decision topic to kebab-case filename:

**Examples**:
- "Claude Code skills for development" → `032-claude-code-development-skills.md`
- "Automation Orchestrator operator deployment" → `033-ao-operator-deployment.md`
- "Storage architecture for AAP" → `034-storage-architecture.md`

**Guidelines**:
- Use noun phrases (not verbs)
- Keep under 50 characters if possible
- Use hyphens, not underscores
- All lowercase
- Descriptive but concise

### 3. Copy Template

Template location: `docs/adr/000-template.md`

```bash
cp docs/adr/000-template.md docs/adr/032-your-title.md
```

### 4. Populate Template Sections

#### Status

Start with **"Proposed"** for new ADRs. Update to:
- **"Accepted"** — When decision is finalized and being implemented
- **"Deprecated"** — When decision is no longer recommended
- **"Superseded"** — When replaced by another ADR (link to it)

#### Date

Use ISO format: `YYYY-MM-DD`

Example: `2026-10-08`

#### Authors (Optional)

- Your name
- Or leave blank
- Or "aap-demo contributors"

#### Context Section

Answer these questions:

**What problem are we solving?**
- Background information
- Current situation
- Pain points or limitations

**What constraints exist?**
- Technical limitations
- Platform requirements
- Compatibility requirements
- Resource constraints

**What forces are at play?**
- Competing concerns
- Trade-offs to consider
- Stakeholder needs

**What have we tried?**
- Previous approaches
- Why they didn't work
- Lessons learned

**Example Context**:
```markdown
## Context

Currently, aap-demo lacks dedicated Claude Code skills to guide contributors 
through common development workflows (issue creation, ADR authoring, addon 
development). This leads to:

- Inconsistent issue quality and missing required information
- ADRs that don't follow the template or skip important sections  
- Addons with incomplete deploy.sh scripts or missing documentation
- New contributors struggling to understand project conventions

Constraints:
- Skills must work with existing GitHub templates and workflows
- Must integrate with Claude Code's skill activation system
- Should leverage existing MCP tools (GitHub integration)
- Need to be maintainable as project conventions evolve

We tried documenting these processes in CONTRIBUTING.md, but:
- Static documentation gets out of sync with reality
- Contributors skip reading lengthy docs
- No validation that conventions are followed
```

#### Decision Section

Be specific about:

**What exactly are we doing?**
- The chosen approach
- Key implementation details
- How it works

**Why this approach over alternatives?**
- Primary reasoning
- Key benefits
- Why alternatives were rejected

**How will it be implemented?**
- Technical specifics
- Files/components affected
- Integration points

**Example Decision**:
```markdown
## Decision

We will create three Claude Code skills in `.claude/skills/`:

1. **aap-issue-creation** — Guide GitHub issue creation
2. **aap-adr** — Assist ADR authoring  
3. **aap-addon-development** — Guide addon development

Each skill will:
- Have YAML frontmatter defining name, description, allowed-tools
- Provide interactive workflow guidance
- Reference existing templates and patterns
- Validate against project conventions
- Integrate with GitHub MCP tools where available

Skills activate automatically based on description triggers or via 
explicit `/skill-name` invocation.

This approach leverages Claude Code's skill system rather than:
- Custom CLI tooling (more maintenance)
- Static documentation (less interactive)
- GitHub Actions automation (limited to CI context)
```

#### Consequences Section

Document trade-offs honestly across three categories:

**Positive**:
- What becomes easier?
- What problems are solved?
- What quality improvements result?

**Negative**:
- What becomes harder?
- What new maintenance burden?
- What limitations remain?

**Neutral**:
- What stays the same?
- What is unaffected?

**Example Consequences**:
```markdown
## Consequences

### Positive

- **Consistency**: All issues/ADRs/addons follow project conventions
- **Discoverability**: New contributors find guidance via skill system
- **Quality**: Validation catches missing info before creation
- **Efficiency**: Faster development with clear patterns
- **Self-documenting**: Skills encode conventions directly

### Negative

- **Maintenance**: Skills need updates when conventions change
- **Learning curve**: Contributors must learn skill invocation
- **Tool dependency**: Requires Claude Code (not standalone git workflow)

### Neutral

- Existing issues/ADRs/addons remain valid (no migration needed)
- Current contribution process still works (skills are additive)
```

#### Alternatives Considered

For each alternative:

1. Brief description
2. Why not chosen
3. What would have been different

**Example Alternatives**:
```markdown
## Alternatives Considered

### 1. GitHub Issue Templates Only

Use only YAML form templates for issue creation.

**Why not chosen**: No validation, no duplicate checking, no context gathering. 
Contributors still skip fields or provide incomplete info.

### 2. CLI Tooling (aap-demo issue, aap-demo adr, etc.)

Build commands into aap-demo.sh for issue/ADR creation.

**Why not chosen**: 
- Limited to aap-demo repository context
- Can't leverage AI for content guidance
- More code to maintain
- Doesn't help with GitHub API integration

### 3. GitHub Actions Automation

Validate issues/PRs via GitHub Actions.

**Why not chosen**:
- Only validates after creation (not preventive)
- Limited to CI context (can't help during authoring)
- No interactive guidance
```

#### References

Link to:
- Related ADRs (use relative links)
- GitHub issues or PRs
- External documentation
- Technical resources

**Example References**:
```markdown
## References

- [GitHub Issue #73](https://github.com/RedHatOfficial/aap-demo/issues/73) — Original feature request
- [ADR-001: Project CLI Architecture](001-project-cli-architecture.md) — Overall project structure
- [Michael Nygard's ADR template](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)
- [Claude Code Skills Documentation](https://docs.anthropic.com/en/docs/claude-code/skills)
```

### 5. Search for Related ADRs

Before finalizing, search for related ADRs to cross-reference:

```bash
# Search by keyword
grep -r "addon" docs/adr/*.md

# Search by topic
find docs/adr -name "*storage*"
find docs/adr -name "*operator*"
```

Add cross-references in the References section.

### 6. Update ADR Index

Edit `docs/adr/README.md` and add entry to the index table:

**Format**:
```markdown
| [NNN](NNN-title.md) | Title | Status |
```

**Example**:
```markdown
| [032](032-claude-code-development-skills.md) | Claude Code Development Skills | Proposed |
```

Insert in numerical order (after 031).

## Naming Conventions

### ADR Numbers

- **Format**: Three-digit zero-padded (001, 002, ..., 032)
- **Next available**: 032
- **Gaps allowed**: Yes (removed or consolidated drafts)
- **Sequence**: Numeric order in index

### ADR Filenames

- **Pattern**: `NNN-kebab-case-title.md`
- **Case**: All lowercase
- **Separator**: Hyphens (not underscores)
- **Length**: Concise but descriptive (prefer < 50 chars)

**Good examples**:
- `032-claude-code-skills.md`
- `033-ao-wiring-automation.md`
- `034-multi-cluster-support.md`

**Bad examples**:
- `032-Claude-Code-Skills.md` (wrong case)
- `032_claude_code_skills.md` (underscores)
- `032-add-new-claude-code-skills-for-issue-adr-and-addon.md` (too long)

## Best Practices

### Before Writing

1. **Check for existing ADRs** on similar topics
2. **Discuss the decision** with maintainers if significant
3. **Gather context** — git history, issues, related code
4. **Consider alternatives** — document options evaluated

### While Writing

1. **Be specific in Decision section** — avoid vague statements
2. **Document trade-offs honestly** — every decision has consequences
3. **Include implementation details** — enough to guide implementation
4. **Cross-reference related ADRs** — build a connected decision graph
5. **Keep it concise** — aim for scannable content (not novels)

### After Writing

1. **Update index in README.md** — don't forget this step
2. **Link from related docs** — mention ADR in README, CLAUDE.md if relevant
3. **Create tracking issue** — if ADR requires implementation work
4. **Update status** — change to "Accepted" when finalized

## ADR Lifecycle

### Status Transitions

```
Proposed → Accepted → (optionally) Deprecated/Superseded
```

**Proposed**: Under discussion, not yet implemented

**Accepted**: Decision made, implementation proceeding or complete

**Deprecated**: No longer recommended (explain why in ADR)

**Superseded**: Replaced by newer ADR (link to replacement)

### Updating Existing ADRs

**For minor updates** (typos, clarifications):
- Edit ADR directly
- Add note to Date field: "Updated: YYYY-MM-DD"

**For significant changes**:
- Consider creating a new ADR that supersedes the old one
- Mark old ADR as "Superseded by ADR-NNN"
- Link bidirectionally between ADRs

## Common ADR Patterns

### Addon Architecture ADRs

When creating ADRs for new addons:

**Context**: Explain the addon's purpose, user need, integration requirements

**Decision**: Detail addon structure, dependencies, deploy/delete logic

**Consequences**: 
- Positive: What capabilities it enables
- Negative: Maintenance burden, resource usage
- Neutral: What's unchanged

**Examples**: ADR-011 (MCP Server), ADR-017 (AO), ADR-024 (Ollama)

### Platform Support ADRs

When adding platform support:

**Context**: Why this platform matters, current limitations

**Decision**: Implementation approach, tooling, prerequisites

**Consequences**:
- Positive: User base expansion
- Negative: Platform-specific code, testing burden
- Neutral: Other platforms unaffected

**Examples**: ADR-029 (Windows Feature Parity), ADR-031 (Git Bash Wrapper)

### CLI Architecture ADRs

When changing CLI behavior:

**Context**: Current pain points, user feedback

**Decision**: New commands, argument patterns, output format

**Consequences**:
- Positive: Better UX
- Negative: Breaking changes, migration needed
- Neutral: Backwards compatibility when possible

**Examples**: ADR-001 (Project Architecture), ADR-010 (Cross-Platform CLI)

## Validation Checklist

Before finalizing an ADR:

- [ ] Number is correct and sequential
- [ ] Filename follows `NNN-kebab-case-title.md` convention
- [ ] All required sections present (Status, Date, Context, Decision, Consequences, Alternatives, References)
- [ ] Status is one of: Proposed, Accepted, Deprecated, Superseded
- [ ] Date in YYYY-MM-DD format
- [ ] Context explains the "why"
- [ ] Decision is specific and actionable
- [ ] Consequences cover positive, negative, and neutral
- [ ] Alternatives documented with reasons for rejection
- [ ] Related ADRs cross-referenced
- [ ] Index updated in `docs/adr/README.md`

## Examples

### Example: Creating an ADR

```bash
# 1. Find next number
find docs/adr -name "[0-9]*-*.md" | sort | tail -1
# Output: docs/adr/031-windows-git-bash-wrapper.md
# Next: 032

# 2. Copy template
cp docs/adr/000-template.md docs/adr/032-claude-code-development-skills.md

# 3. Edit file (populate all sections)
# ... edit 032-claude-code-development-skills.md ...

# 4. Update index
# Edit docs/adr/README.md, add:
# | [032](032-claude-code-development-skills.md) | Claude Code Development Skills | Proposed |

# 5. Commit
git add docs/adr/032-claude-code-development-skills.md docs/adr/README.md
git commit -m "docs(adr): Add ADR-032: Claude Code Development Skills"
```

### Example: Searching for Related ADRs

```bash
# Find ADRs about addons
grep -l "addon" docs/adr/*.md | grep -v "000-template"

# Find ADRs about Windows
find docs/adr -name "*windows*"

# Find ADRs mentioning specific technologies
grep -l "operator" docs/adr/*.md
grep -l "storage" docs/adr/*.md
```

## Integration with Other Skills

- **aap-issue-creation skill**: Reference ADR in feature request issues
- **aap-addon-development skill**: Create ADR before developing significant addon
- Document ADR numbers in commit messages: `feat(addon): implement OPA addon (ADR-033)`

## Reading Order for New Contributors

Recommended ADR reading sequence from `docs/adr/README.md`:

1. **ADR-001** — What aap-demo is and how CLI is structured
2. **ADR-003** — Why CRC MicroShift is the default
3. **ADR-005 + ADR-009** — How AAP gets installed
4. **ADR-006 + ADR-007 + ADR-012** — Common deployment failure areas
5. **ADR-008** — How optional components (addons) plug in

Then specific ADRs based on area of interest (portal, APME, Windows, testing).
