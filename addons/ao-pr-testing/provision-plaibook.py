#!/usr/bin/env python3
"""Provision the AAP project and job template used by the PR-testing addon."""

from __future__ import annotations

import argparse
import json
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


class AAP:
    def __init__(self, route: str, token: str) -> None:
        self.base = f"https://{route}/api/controller/v2"
        self.token = token
        self.context = ssl._create_unverified_context()

    def request(self, path: str, method: str = "GET", payload: Any = None) -> Any:
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(
            f"{self.base}{path}",
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, context=self.context, timeout=60) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")
            raise RuntimeError(f"{method} {path} returned HTTP {exc.code}: {detail}") from exc

    def find(self, endpoint: str, name: str) -> dict[str, Any] | None:
        encoded = urllib.parse.quote(name)
        result = self.request(f"/{endpoint}/?name={encoded}&page_size=200")
        return next(iter(result.get("results", [])), None)

    def wait_for_project_sync(
        self, project_id: int, playbook: str, timeout: int = 300
    ) -> None:
        try:
            self.request(f"/projects/{project_id}/update/", "POST")
        except RuntimeError as exc:
            if "HTTP 400" not in str(exc):
                raise

        deadline = time.time() + timeout
        last_status = "unknown"
        while time.time() < deadline:
            project = self.request(f"/projects/{project_id}/")
            last_status = str(project.get("status") or "unknown")
            if last_status == "successful":
                playbooks = self.request(f"/projects/{project_id}/playbooks/")
                if isinstance(playbooks, dict):
                    playbooks = playbooks.get("results") or playbooks.get("playbooks") or []
                if any(
                    (
                        item == playbook
                        if isinstance(item, str)
                        else item.get("name") == playbook
                    )
                    for item in playbooks or []
                ):
                    return
            if last_status in {"failed", "error", "canceled"}:
                raise RuntimeError(f"plaibook project sync ended with status {last_status}")
            time.sleep(5)
        raise RuntimeError(
            f"plaibook project did not publish {playbook} within {timeout}s "
            f"(status={last_status})"
        )

    def ensure_job_template_credential(self, template_id: int, credential_id: int) -> None:
        current = self.request(f"/job_templates/{template_id}/credentials/")
        credentials = current.get("results", []) if isinstance(current, dict) else []
        if any(item.get("id") == credential_id for item in credentials):
            return
        self.request(
            f"/job_templates/{template_id}/credentials/",
            "POST",
            {"id": credential_id},
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--route", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--project-name", required=True)
    parser.add_argument("--project-url", required=True)
    parser.add_argument("--project-branch", required=True)
    parser.add_argument("--inventory-name", required=True)
    parser.add_argument("--job-template-name", required=True)
    parser.add_argument("--playbook", default="review.yml")
    parser.add_argument("--execution-environment-id", required=True, type=int)
    parser.add_argument("--job-timeout", default=900, type=int)
    parser.add_argument("--credential-id", type=int)
    parser.add_argument("--extra-vars-json", required=True)
    args = parser.parse_args()

    extra_vars = json.loads(args.extra_vars_json)
    if not isinstance(extra_vars, dict):
        raise ValueError("--extra-vars-json must contain an object")

    api = AAP(args.route, args.token)
    organizations = api.request("/organizations/?name=Default&page_size=10").get("results", [])
    if not organizations:
        raise RuntimeError("AAP Default organization was not found")
    organization_id = organizations[0]["id"]

    project_payload = {
        "name": args.project_name,
        "description": "ansible-plaibook PR review project managed by ao-pr-testing",
        "organization": organization_id,
        "scm_type": "git",
        "scm_url": args.project_url,
        "scm_branch": args.project_branch,
        "scm_update_on_launch": True,
        "scm_delete_on_update": False,
    }
    project = api.find("projects", args.project_name)
    if project:
        project_id = project["id"]
        api.request(f"/projects/{project_id}/", "PATCH", project_payload)
        print(f"  AAP plaibook project updated: {args.project_name}", file=sys.stderr)
    else:
        project_id = api.request("/projects/", "POST", project_payload)["id"]
        print(f"  AAP plaibook project created: {args.project_name}", file=sys.stderr)
    api.wait_for_project_sync(project_id, args.playbook)
    print("  AAP plaibook project synchronized", file=sys.stderr)

    inventory = api.find("inventories", args.inventory_name)
    if inventory:
        inventory_id = inventory["id"]
    else:
        inventory_id = api.request(
            "/inventories/",
            "POST",
            {
                "name": args.inventory_name,
                "description": "Localhost inventory for ansible-plaibook review jobs",
                "organization": organization_id,
            },
        )["id"]
        print(f"  AAP plaibook inventory created: {args.inventory_name}", file=sys.stderr)

    template_payload = {
        "name": args.job_template_name,
        "description": "Run ansible-plaibook PR review in the shared plaibook EE",
        "job_type": "run",
        "organization": organization_id,
        "project": project_id,
        "playbook": args.playbook,
        "inventory": inventory_id,
        "execution_environment": args.execution_environment_id,
        "timeout": args.job_timeout,
        "ask_variables_on_launch": True,
        "extra_vars": json.dumps(extra_vars, sort_keys=True),
    }
    template = api.find("job_templates", args.job_template_name)
    if template:
        template_id = template["id"]
        api.request(f"/job_templates/{template_id}/", "PATCH", template_payload)
        print(f"  AAP plaibook job template updated: {args.job_template_name}", file=sys.stderr)
    else:
        template_id = api.request("/job_templates/", "POST", template_payload)["id"]
        print(f"  AAP plaibook job template created: {args.job_template_name}", file=sys.stderr)

    if args.credential_id:
        api.ensure_job_template_credential(template_id, args.credential_id)

    print(template_id)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
