"""Redact credentials before values become diagnostics or artifacts."""

import re


REDACTED = "[REDACTED]"
_SECRET_KEYS = {
    "token", "password", "secret", "apikey", "authorization", "accesstoken",
    "clientsecret", "credential", "credentials", "bearer",
}
_SECRET_NAME = r"(?:[a-z0-9]+(?:[-_][a-z0-9]+)*[-_])?(?:token|password|secret|api[-_]?key|access[-_]?token|client[-_]?secret|credentials?|bearer)"
_BEARER_TOKEN = re.compile(r"(?i)\bbearer\s+[^\s,;\"'}]+")
_OPAQUE_SECRET = re.compile(
    r"\b(?:AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-(?:proj-)?[A-Za-z0-9_-]{16,}|(?:api|provider)[-_]?(?:key|secret|token)[-_][A-Za-z0-9_-]{12,})\b"
)
_SECRET_VALUE = re.compile(
    rf"(?i)(?P<prefix>[\"']?{_SECRET_NAME}[\"']?\s*[:=]\s*)(?P<value>\[REDACTED\]|\"(?:\\.|[^\"])*\"|'(?:\\.|[^'])*'|[^\r\n,}}\]&;]*)"
)
_QUERY_SECRET = re.compile(rf"(?i)([?&]{_SECRET_NAME}=)[^\r\n&#;]*")


def redact_text(text: str) -> str:
    """Replace bearer credentials and common secret values in free-form text."""
    redacted = _BEARER_TOKEN.sub(f"Bearer {REDACTED}", text)
    redacted = _SECRET_VALUE.sub(_replace_secret_value, redacted)
    redacted = _QUERY_SECRET.sub(rf"\1{REDACTED}", redacted)
    return _OPAQUE_SECRET.sub(REDACTED, redacted)


def _replace_secret_value(match: re.Match[str]) -> str:
    value = match.group("value")
    if value.strip("\"'") == REDACTED:
        return f"{match.group('prefix')}{value}"
    if value.startswith('"'):
        return f'{match.group("prefix")}"{REDACTED}"'
    if value.startswith("'"):
        return f"{match.group('prefix')}'{REDACTED}'"
    return f"{match.group('prefix')}{REDACTED}"


def redact(value: object) -> object:
    """Return a recursively redacted copy suitable for diagnostics."""
    if isinstance(value, dict):
        return {
            key: REDACTED if _is_secret_key(key) else redact(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [redact(item) for item in value]
    if isinstance(value, tuple):
        return tuple(redact(item) for item in value)
    if isinstance(value, str):
        return redact_text(value)
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, BaseException):
        return redact_text(str(value))
    # Diagnostics must be fail-closed: an arbitrary object can expose secrets
    # through its repr, so never serialize it merely to make a report complete.
    return f"[diagnostic omitted unsafe value of type {type(value).__name__}]"


def _normalized_key(key: object) -> str:
    return str(key).casefold().replace("-", "").replace("_", "")


def _is_secret_key(key: object) -> bool:
    """Recognize both canonical fields and prefixed HTTP header names."""
    normalized = _normalized_key(key)
    return normalized in _SECRET_KEYS or any(
        normalized.endswith(secret_name) for secret_name in _SECRET_KEYS
    )
