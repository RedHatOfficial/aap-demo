"""Error hierarchy and the exit codes it maps to (design §3.4).

Codes 0/1/2 are preserved exactly as the bash tool used them so anything scripted
against ``aap-demo`` keeps working; 3-7 are refinements of what is currently 1.
"""

from __future__ import annotations

from typing import Optional


class AapDemoError(Exception):
    """Base for every error the CLI turns into a non-zero exit."""

    exit_code = 1

    def __init__(self, message: str, *, hint: Optional[str] = None) -> None:
        super().__init__(message)
        self.message = message
        self.hint = hint


class UsageError(AapDemoError):
    exit_code = 2


class PrerequisiteError(AapDemoError):
    """A required external tool, backend, or credential store is missing."""

    exit_code = 3


class ClusterUnreachableError(AapDemoError):
    exit_code = 4


class UserAbortedError(AapDemoError):
    exit_code = 5

    def __init__(self, message: str = "Aborted.", *, hint: Optional[str] = None) -> None:
        super().__init__(message, hint=hint)


class AddonError(AapDemoError):
    exit_code = 6


class PlaybookError(AapDemoError):
    exit_code = 7


class ConfigError(AapDemoError):
    """Config file or resolved-configuration validation failure."""

    exit_code = 2


class NotImplementedYetError(AapDemoError):
    """A command whose bash behavior has not been ported to Python yet.

    Phase 0 ships the whole command surface as a skeleton; commands outside the
    phase-0 scope raise this rather than pretending to succeed.
    """

    exit_code = 1

    def __init__(self, command: str) -> None:
        super().__init__(
            f"'{command}' is not yet implemented in the Python rewrite.",
            hint="Use the bash aap-demo for this command during the rewrite overlap.",
        )
        self.command = command


EXIT_CODES = {
    0: "success",
    1: "generic failure",
    2: "usage error",
    3: "prerequisite missing",
    4: "cluster unreachable / not created",
    5: "user aborted a confirmation",
    6: "addon error",
    7: "day-2 playbook run failed",
}
