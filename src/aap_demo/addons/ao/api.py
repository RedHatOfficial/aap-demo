"""HTTPS calls to AO's and AAP's routes, verified against the cluster ingress CA.

The Bash wiring used ``curl -k``. Here the routes' certificates are checked:
the cluster's self-signed ingress CA is trusted next to the system store, so a
local route verifies and a public one still does.
"""

from __future__ import annotations

import base64
import json
import ssl
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Tuple

from aap_demo.addons.common.kube import as_dict
from aap_demo.cluster import ingress_ca
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError

TIMEOUT = 60
LIST_LIMIT = 100

Opener = Callable[..., Any]


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect must not carry a password or token to another host."""

    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


def _open(request: urllib.request.Request, *, timeout: float, context: ssl.SSLContext) -> Any:
    opener = urllib.request.build_opener(_NoRedirect, urllib.request.HTTPSHandler(context=context))
    return opener.open(request, timeout=timeout)


def tls_context(ctx: AppContext, ca: Optional[str] = None) -> ssl.SSLContext:
    context = ssl.create_default_context()
    if ca is None:
        ca = ingress_ca.fetch_cluster_ca(ctx)
    if ca:
        context.load_verify_locations(cadata=ca)
    return context


@dataclass
class Response:
    status: int
    body: Any

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300 and not (
            isinstance(self.body, dict) and "code" in self.body
        )

    def field(self, name: str) -> str:
        return str(as_dict(self.body).get(name) or "")

    def items(self) -> List[Dict[str, Any]]:
        """AO list endpoints return ``resources``; older ones ``results``."""
        body = as_dict(self.body)
        found = body.get("resources", body.get("results", []))
        return [as_dict(item) for item in found or [] if isinstance(item, dict)]


@dataclass
class Http:
    context: Optional[ssl.SSLContext]
    opener: Opener = _open
    timeout: float = TIMEOUT

    def call(
        self,
        method: str,
        url: str,
        *,
        body: Optional[Any] = None,
        headers: Optional[Dict[str, str]] = None,
    ) -> Response:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header("Content-Type", "application/json")
        for key, value in (headers or {}).items():
            request.add_header(key, value)
        try:
            with self.opener(request, timeout=self.timeout, context=self.context) as response:
                status, raw = response.status, response.read()
        except urllib.error.HTTPError as exc:
            status, raw = exc.code, exc.read()
        except (urllib.error.URLError, OSError) as exc:
            raise AddonError(
                f"could not reach {urllib.parse.urlsplit(url).netloc}", hint=str(exc)
            ) from exc
        try:
            parsed: Any = json.loads(raw) if raw else {}
        except ValueError:
            parsed = {"raw": raw.decode("utf-8", "replace")}
        return Response(status=status, body=parsed)


def aap_token(http: Http, route: str, password: str, *, description: str) -> str:
    """A write-scoped AAP gateway token for one AO integration."""
    basic = base64.b64encode(f"admin:{password}".encode()).decode()
    response = http.call(
        "POST",
        f"https://{route}/api/gateway/v1/tokens/",
        body={"description": description, "scope": "write"},
        headers={"Authorization": f"Basic {basic}"},
    )
    return response.field("token")


@dataclass
class AoClient:
    """AO's REST API (``/api/v1``) with a bearer token from ``/auth/login``."""

    http: Http
    route: str
    token: str = ""
    _project: Optional[str] = field(default=None, repr=False)

    @property
    def base(self) -> str:
        return f"https://{self.route}/api/v1"

    def login(self, password: str) -> None:
        response = self.http.call(
            "POST", f"{self.base}/auth/login", body={"username": "admin", "password": password}
        )
        self.token = response.field("access_token")
        if not self.token:
            raise AddonError("Could not authenticate to the Automation Orchestrator API")

    def call(self, method: str, path: str, body: Optional[Any] = None) -> Response:
        return self.http.call(
            method,
            f"{self.base}{path}",
            body=body,
            headers={"Authorization": f"Bearer {self.token}"},
        )

    def get(self, path: str) -> Response:
        return self.call("GET", path)

    def find(self, path: str, **match: str) -> Optional[Dict[str, Any]]:
        for item in self.get(path).items():
            if all(str(item.get(key)) == value for key, value in match.items()):
                return item
        return None

    def default_project(self) -> str:
        if self._project is None:
            item = self.find("/projects?limit=10&is_default=true", is_default="True")
            if item is None:
                listed = self.get("/projects?limit=10").items()
                item = listed[0] if listed else None
            self._project = str(item.get("id")) if item else ""
        return self._project


def quote(value: str) -> str:
    return urllib.parse.quote(value, safe="")


def error_text(response: Response) -> str:
    return json.dumps(response.body)[:500]


__all__: Tuple[str, ...] = ("AoClient", "Http", "Response", "aap_token", "tls_context")
