# ADR-034: VM Size Prompt and Host Fit Check on Create

**Status**: Accepted

**Date**: 2026-11-01

**Authors**: aap-demo maintainers

---

## Context

The Python rewrite had no interactive questions in `create`. Bash `create` asks for processors and memory.
Without that question, a person on a smaller computer got the 8-processor, 24 GB default, and only a warning
if the computer was below the MicroShift minimum. A VM larger than the computer failed later, inside `crc start`.

The review of the v2 cutover asked that an impossible size be visible and blocked before the VM is started.
The prompt has to stay out of the way of scripts and CI, which already set the size through flags and
environment variables.

## Decision

`create` asks for processors and memory before its first step when all of these hold:

- no VM exists
- no flag or environment variable set either value
- output is not quiet or structured
- stdin and stdout are terminals, or `AAP_DEMO_INTERACTIVE=1` is set

`deploy` asks too when it creates a missing cluster, because it calls `create`.

Saved values are the defaults, capped to what the host has. Enter keeps a default. End of input keeps them all.
An invalid answer or one that does not fit the host stops the command and is not saved. Changed answers are
written to `crc.cpus` and `crc.memory_mb`, and no other value is added to the config file.

Every `create` then stops before `crc start` if the size exceeds the host's processors, or its memory plus Linux
swap. This also applies when no prompt was shown. If the host cannot be read, the check is skipped.

## Consequences

### Positive

- A person sees the size and the computer's capacity before a long `create`.
- A VM the computer cannot run fails in seconds, with a size that fits.
- Scripts and CI do not get a new question.

### Negative

- A default `create` on a computer below 8 processors or 24 GB now stops without a terminal. It needs an explicit
  size. It used to continue and leave the outcome to CRC.
- A second place in `create` reads terminal input, which tests must keep away from a real terminal.

### Neutral

- A VM that already exists keeps its size. Resizing still means `destroy` and `create`.
- A size that fits can still be too small for AAP. The minimum warning stays.
- Bash's offer of temporary swap on Linux is not ported.

## Alternatives Considered

### 1. Host fit check only

The review would accept this. It was rejected because bash asks, and a person choosing a size at the start is
better than an error followed by a second run.

### 2. Warn instead of stopping

This is what existed before. The warning scrolled past and `crc start` failed later.

### 3. Save with `Config.save`

Rejected because it writes the merged configuration, which would persist unrelated flag and environment values.

## References

- [ADR-003: Infrastructure Backend Selection](003-infrastructure-backend-selection.md)
- `includes/crc-create.sh`: the bash prompt
- [Settings](../reference/settings.md)
