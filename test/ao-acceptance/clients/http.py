"""A small authenticated JSON transport with safe failure diagnostics."""

import json
import ssl
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlparse
from urllib.request import HTTPSHandler, HTTPRedirectHandler, Request, build_opener

try:
    from redaction import redact_text
except ImportError:  # Package import when this directory gains a parent package.
    from ..redaction import redact_text


_ERROR_BODY_LIMIT = 4096


class _NoRedirectHandler(HTTPRedirectHandler):
    """Surface redirects as API errors instead of forwarding bearer tokens."""

    def redirect_request(self, request, response, code, message, headers, newurl):
        return None


class ApiError(RuntimeError):
    """A failed API request with only redacted diagnostic text."""

    def __init__(
        self,
        method: str,
        url: str,
        status: int | None,
        body: str,
        *,
        untrusted_body: bool = False,
    ):
        self.method = method
        self.url = redact_text(url)
        self.status = status
        self.body = (
            "[REDACTED] response body omitted because it may contain unlabeled secrets"
            if untrusted_body and body
            else _safe_body(body)
        )
        status_text = str(status) if status is not None else "unavailable"
        super().__init__(f"{method} {self.url} failed ({status_text}): {self.body}")


def _safe_body(body: str) -> str:
    return redact_text(body)[:_ERROR_BODY_LIMIT]


class JsonClient:
    """Issue token-authenticated JSON requests without logging request data."""

    def __init__(self, base_url: str, token: str, *, ca_file: str | None = None):
        self.base_url = base_url.rstrip("/") + "/"
        self.token = token
        self.context = ssl.create_default_context(cafile=ca_file)
        self._origin = urlparse(self.base_url)
        self._opener = build_opener(HTTPSHandler(context=self.context), _NoRedirectHandler())

    def request(
        self,
        method: str,
        path: str,
        *,
        payload: dict | None = None,
        timeout: int = 60,
    ) -> dict | list[object]:
        url = self._url_for(path)
        data = None
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json"}
        if payload is not None:
            data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = Request(url, data=data, headers=headers, method=method.upper())
        try:
            with self._opener.open(request, timeout=timeout) as response:
                status = getattr(response, "status", None)
                if status is None:
                    status = response.getcode()
                body = response.read().decode("utf-8", errors="replace")
        except HTTPError as error:
            try:
                body = error.read().decode("utf-8", errors="replace")
            finally:
                error.close()
            raise ApiError(
                method.upper(), url, error.code, body, untrusted_body=True
            ) from None
        except (URLError, OSError, ValueError) as error:
            raise ApiError(method.upper(), url, None, str(error)) from None
        if not 200 <= status < 300:
            raise ApiError(
                method.upper(), url, status, body, untrusted_body=True
            )
        try:
            decoded = json.loads(body)
        except json.JSONDecodeError:
            raise ApiError(method.upper(), url, None, "response was not valid JSON") from None
        if not isinstance(decoded, (dict, list)):
            raise ApiError(method.upper(), url, None, "response JSON must be an object or list")
        return decoded

    def _url_for(self, path: str) -> str:
        url = urljoin(self.base_url, path)
        parsed = urlparse(url)
        if (parsed.scheme, parsed.netloc) != (self._origin.scheme, self._origin.netloc):
            raise ApiError("GET", url, None, "refusing pagination link outside API origin")
        return url
