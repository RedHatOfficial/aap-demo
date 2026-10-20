"""AAP REST resource client used by live acceptance checks."""

from typing import Any

from .http import ApiError, JsonClient


class AapClient(JsonClient):
    """Read and launch AAP controller resources."""

    def get(self, path: str) -> dict:
        return self.request("GET", path)

    def list_all(self, path: str) -> list[dict]:
        items: list[dict] = []
        next_path: str | None = path
        while next_path:
            page = self.get(next_path)
            results = page.get("results", page.get("items", []))
            if not isinstance(results, list) or not all(isinstance(item, dict) for item in results):
                raise ApiError("GET", next_path, None, "list response did not contain object results")
            items.extend(results)
            next_value = page.get("next")
            next_path = next_value if isinstance(next_value, str) and next_value else None
        return items

    def launch_job_template(self, template_id: int, extra_vars: dict | None = None) -> int:
        if isinstance(template_id, bool) or not isinstance(template_id, int):
            raise ValueError("AAP job template identifiers must be numeric")
        payload: dict[str, Any] = {}
        if extra_vars is not None:
            payload["extra_vars"] = extra_vars
        response = self.request("POST", f"/api/v2/job_templates/{template_id}/launch/", payload=payload)
        job_id = response.get("id", response.get("job"))
        if isinstance(job_id, bool) or not isinstance(job_id, int):
            raise ApiError("POST", f"/api/v2/job_templates/{template_id}/launch/", None, "launch response missing numeric job id")
        return job_id

    def job_status(self, job_id: int) -> dict:
        if isinstance(job_id, bool) or not isinstance(job_id, int):
            raise ValueError("AAP job identifiers must be numeric")
        return self.get(f"/api/v2/jobs/{job_id}/")
