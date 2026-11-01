# ADR-035: Remove `diagnose --ai` from the Python CLI

**Status**: Accepted

**Date**: 2026-11-01

**Authors**: aap-demo maintainers

---

## Context

`aap-demo diagnose --ai` passes pod logs and events to `claude -p`. That ties a general command to
one vendor's CLI and login. It also hands text that a workload controls to an agent with no tool
limits, and it doesn't use the project's troubleshooting skill.

An agent can already run `aap-demo diagnose` and work from the output, using `AGENTS.md` and the
project skills.

## Decision

The Python CLI has no `--ai` flag. `aap-demo diagnose --ai` is a usage error, and the `diagnose`
report no longer suggests it.

The bash CLI keeps its `--ai` flag, because the bash tree isn't changing in this cutover.

## Consequences

### Positive

- `aap-demo` no longer depends on any AI vendor's CLI.
- aap-demo no longer sends cluster data to a third party or passes it to an agent.

### Negative

- This is a new gap against bash.
- A user without an agent gets the report and no written analysis.

### Neutral

- `diagnose` output and exit codes are otherwise unchanged.

## Alternatives Considered

### Keep it for Claude only, with tools turned off

Closes the tool access problem, but keeps the vendor dependency and can't use the skill.

### Make the agent configurable

Each CLI has its own flags for turning off tools, so this adds the most to build and maintain, with
no known demand.

## References

- [ADR-001: Project CLI Architecture](001-project-cli-architecture.md)
