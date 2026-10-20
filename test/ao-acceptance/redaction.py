"""Redact credentials before values become diagnostics or artifacts."""

import re
from typing import Any


REDACTED = "[REDACTED]"
_SECRET_KEYS = {"token", "password", "secret", "api_key", "authorization"}
_BEARER_TOKEN = re.compile(r"(?i)\bbearer\s+[^\s,;\"'}]+")
_SECRET_VALUE = re.compile(
    r"(?i)(?P<prefix>[\"']?(?:token|password|secret|api_key)[\"']?\s*[:=]\s*)(?P<value>\"(?:\\.|[^\"])*\"|'(?:\\.|[^'])*'|[^\r\n,}\]&;]*)"
)
_QUERY_SECRET = re.compile(r"(?i)([?&](?:token|password|secret|api_key)=)[^\r\n&#;]*")


def redact_text(text: str) -> str:
    """Replace bearer credentials and common secret values in free-form text."""
    redacted = _BEARER_TOKEN.sub(f"Bearer {REDACTED}", text)
    redacted = _SECRET_VALUE.sub(_replace_secret_value, redacted)
    return _QUERY_SECRET.sub(rf"\1{REDACTED}", redacted)


def _replace_secret_value(match: re.Match[str]) -> str:
    value = match.group("value")
    if value.startswith('"'):
        return f'{match.group("prefix")}"{REDACTED}"'
    if value.startswith("'"):
        return f"{match.group('prefix')}'{REDACTED}'"
    return f"{match.group('prefix')}{REDACTED}"


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
