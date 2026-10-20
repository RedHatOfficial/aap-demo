"""Authenticated MCP JSON-RPC client with allowlisted observations."""

from urllib.parse import urlparse

try:
    from .http import ApiError, JsonClient
except ImportError:  # Direct execution via run.sh or python runner.py.
    from http import ApiError, JsonClient


class McpClient:
    """Call MCP without exposing bearer tokens or untrusted tool output."""

    def __init__(
        self,
        endpoint: str,
        token: str,
        *,
        ca_file: str | None = None,
        timeout_seconds: int = 60,
    ):
        parsed = urlparse(endpoint)
        if parsed.scheme != "https" or not parsed.netloc:
            raise ValueError("MCP endpoint must be an absolute HTTPS URL")
        self.endpoint = endpoint
        self.token = token
        self.ca_file = ca_file
        self.timeout_seconds = timeout_seconds
        self._path = parsed.path or "/"
        if parsed.query:
            self._path = f"{self._path}?{parsed.query}"
        self._client = JsonClient(
            f"{parsed.scheme}://{parsed.netloc}", token, ca_file=ca_file
        )

    def list_tools(self) -> list[str]:
        """Return only validated MCP tool names."""
        payload = self._request(
            "ao-acceptance-tools", "tools/list", {}
        )
        result = payload.get("result")
        tools = result.get("tools") if isinstance(result, dict) else None
        if not isinstance(tools, list):
            raise RuntimeError("MCP tools/list response did not contain tools")
        names = [tool.get("name") if isinstance(tool, dict) else None for tool in tools]
        if not names or not all(isinstance(name, str) and name for name in names):
            raise RuntimeError("MCP tools/list response contained an invalid tool")
        return names

    def call_tool(self, name: str, arguments: dict) -> dict[str, object]:
        """Call one tool and retain only a content-shape/status observation."""
        payload = self._request(
            "ao-acceptance-call",
            "tools/call",
            {"name": name, "arguments": arguments},
        )
        result = payload.get("result")
        if not isinstance(result, dict):
            raise RuntimeError("MCP tools/call response did not contain a result")
        content = result.get("content", [])
        if not isinstance(content, list):
            raise RuntimeError("MCP tools/call response contained invalid content")
        content_types = [
            item.get("type") for item in content
            if isinstance(item, dict) and isinstance(item.get("type"), str)
        ]
        return {
            "tool_name": name,
            "content_types": content_types,
            "is_error": result.get("isError") is True,
        }

    def pod_request(
        self, method: str, params: dict, *, ca_pem: str = ""
    ) -> dict[str, object]:
        """Build stdin-only data for an authenticated in-pod MCP probe."""
        return {
            "endpoint": self.endpoint,
            "token": self.token,
            "ca_pem": ca_pem,
            "request": {
                "jsonrpc": "2.0",
                "id": "ao-acceptance-pod",
                "method": method,
                "params": params,
            },
        }

    def _request(self, request_id: str, method: str, params: dict) -> dict:
        response = self._client.request(
            "POST",
            self._path,
            payload={
                "jsonrpc": "2.0",
                "id": request_id,
                "method": method,
                "params": params,
            },
            timeout=self.timeout_seconds,
        )
        if not isinstance(response, dict):
            raise RuntimeError("MCP response was not a JSON object")
        if "error" in response:
            # MCP error data is untrusted and can contain secrets or tool output.
            raise ApiError("POST", self.endpoint, None, "MCP returned an error")
        return response
