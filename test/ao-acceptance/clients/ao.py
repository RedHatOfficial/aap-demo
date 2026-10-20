"""Automation Orchestrator REST resource client for acceptance checks."""

from typing import Any
from urllib.parse import quote

from .http import ApiError, JsonClient


class AoClient(JsonClient):
    """Read, launch, and poll AO workflows."""

    def get(self, path: str) -> dict:
        response = self.request("GET", path)
        if not isinstance(response, dict):
            raise ApiError("GET", path, None, "resource response must be an object")
        return response

    def list_all(self, path: str) -> list[dict]:
        items: list[dict] = []
        next_path: str | None = path
        while next_path:
            page = self.request("GET", next_path)
            if isinstance(page, list):
                page_items = page
                next_value = None
            else:
                page_items = page.get("results", page.get("items", []))
                next_value = page.get("next")
            if not isinstance(page_items, list) or not all(isinstance(item, dict) for item in page_items):
                raise ApiError("GET", next_path, None, "list response did not contain object results")
            items.extend(page_items)
            next_path = next_value if isinstance(next_value, str) and next_value else None
        return items

    def launch_workflow(self, workflow_id: str, inputs: dict | None = None) -> str:
        if not isinstance(workflow_id, str) or not workflow_id:
            raise ValueError("AO workflow identifiers must be non-empty strings")
        payload: dict[str, Any] = {}
        if inputs is not None:
            payload["inputs"] = inputs
        endpoint = f"/api/v1/workflows/{quote(workflow_id, safe='')}/launch"
        response = self.request("POST", endpoint, payload=payload)
        execution_id = response.get("id", response.get("execution_id"))
        if not isinstance(execution_id, str) or not execution_id:
            raise ApiError("POST", endpoint, None, "launch response missing execution id")
        return execution_id

    def workflow_status(self, execution_id: str) -> dict:
        if not isinstance(execution_id, str) or not execution_id:
            raise ValueError("AO execution identifiers must be non-empty strings")
        return self.get(f"/api/v1/executions/{quote(execution_id, safe='')}")
