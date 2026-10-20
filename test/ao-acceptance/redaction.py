"""Redact credentials before values become diagnostics or artifacts."""

import re
from typing import Any


REDACTED = "[REDACTED]"
_SECRET_KEYS = {"token", "password", "secret", "api_key", "authorization"}
_BEARER_TOKEN = re.compile(r"(?i)\bbearer\s+[^\s,;\"'}]+")
_JSON_OR_ASSIGNMENT_SECRET = re.compile(
    r"(?i)([\"']?(?:token|password|secret|api_key)[\"']?\s*[:=]\s*[\"']?)[^\s,}\]\"']+"
)
_QUERY_SECRET = re.compile(r"(?i)([?&](?:token|password|secret|api_key)=)[^&#\s]+")


def redact_text(text: str) -> str:
    """Replace bearer credentials and common secret values in free-form text."""
    redacted = _BEARER_TOKEN.sub(f"Bearer {REDACTED}", text)
    redacted = _JSON_OR_ASSIGNMENT_SECRET.sub(rf"\1{REDACTED}", redacted)
    return _QUERY_SECRET.sub(rf"\1{REDACTED}", redacted)


def redact(value: object) -> object:
    """Return a recursively redacted copy suitable for diagnostics."""
    if isinstance(value, dict):
        return {
            key: REDACTED if str(key).lower() in _SECRET_KEYS else redact(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [redact(item) for item in value]
    if isinstance(value, tuple):
        return tuple(redact(item) for item in value)
    if isinstance(value, str):
        return redact_text(value)
    return value
