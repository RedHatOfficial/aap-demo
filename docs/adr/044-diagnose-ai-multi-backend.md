# ADR-044: Restore `diagnose --ai` with multi-backend support

**Status**: Accepted

**Date**: 2026-11-16

**Authors**: aap-demo maintainers

**Supersedes**: [ADR-035](035-remove-diagnose-ai.md)

---

## Context

[ADR-035](035-remove-diagnose-ai.md) removed `--ai` from the Python CLI because it was
Claude-only, sent cluster text to an agent with no tool limits, and duplicated what an
in-session agent can do from plain `diagnose` output.

Users still want a one-shot analysis path when they are not already in an agent chat, and
Cursor Agent sessions need a way to dump rich context without calling an external CLI.
The bash tree kept Claude-only `--ai`, so the Python gap remained.

## Decision

Restore `aap-demo diagnose --ai` on the Python CLI with automatic backend selection:

| Backend | When | Behavior |
|---------|------|----------|
| `embedded` | `CURSOR_AGENT=1` | Print context + prompt for the active agent; save under the state dir |
| `cursor` | `cursor` on PATH | `cursor agent --print --mode ask` (read-only ask mode) |
| `claude` | `claude` on PATH | Existing `claude -p` flow |
| `auto` (default) | — | embedded → cursor → claude → clear install hints |

`AAP_DIAGNOSE_AI_BACKEND` may force `embedded`, `cursor`, `claude`, or `auto`.

Bash keeps the same backends for the legacy entrypoint. PowerShell prefers
`python -m aap_demo diagnose --ai`, then bash.

## Consequences

### Positive

- Works inside Cursor Agent without a third-party CLI.
- Cursor CLI runs in ask mode so the agent does not get write/shell tools by default.
- Removes the Claude-only vendor lock from the primary Python path.

### Negative

- Cluster diagnostic text can still leave the machine when Cursor CLI or Claude CLI is used.
- Another CLI flag to maintain and test.

### Neutral

- Plain `aap-demo diagnose` is unchanged. Agents can still read that output without `--ai`.

## Alternatives Considered

### Keep ADR-035

Leaves a bash/Python gap and no Cursor-native path.

### Embedded only

Safe for in-session agents, but not useful from a normal terminal.

## References

- [ADR-035: Remove diagnose --ai](035-remove-diagnose-ai.md)
- [ADR-010: Cross-platform CLI](010-cross-platform-cli.md)
