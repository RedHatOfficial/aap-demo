#!/usr/bin/env python3
"""Provision AAP projects and job templates used by the AO demo workflows."""

from __future__ import annotations

import argparse
import json
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


PROJECT_NAME = "AAP Orchestrator Demos"
PROJECT_URL = "https://github.com/ansible-tmm/aap-orchestrator-demos.git"
CONTROL_PROJECT_NAME = "AAP Demo Control Plane"
CONTROL_PROJECT_URL = "https://github.com/RedHatOfficial/aap-demo.git"
CONTROL_TEMPLATE_NAME = "Sync AO Workflows from TMM"
CONTROL_PLAYBOOK = "addons/ao/playbooks/sync-ao-demos.yml"

TEMPLATES = [
    ("Renew Certificate", "cert-lifecycle/playbooks/renew_certificate.yml"),
    ("Renew Java Keystore Certificate", "cert-lifecycle/playbooks/renew_keystore_certificate.yml"),
    ("Validate Cert Renewal", "cert-lifecycle/playbooks/validate_certificate.yml"),
    ("Notify Mattermost", "cert-lifecycle/playbooks/notify_mattermost.yml"),
    ("Disk Utilization Check", "disk-utilization/playbooks/check_disk.yml"),
    ("Linux - Remediate - Disk Cleanup", "disk-utilization/playbooks/remediate_disk_cleanup.yml"),
    ("Linux - Remediate - Continue", "disk-utilization/playbooks/remediate_disk_continue.yml"),
    ("Linux - Remediate - Disk Expand", "disk-utilization/playbooks/remediate_disk_expand.yml"),
    ("Disk Utilization - Fallback", "disk-utilization/playbooks/remediate_disk_fallback.yml"),
    ("Notify Chatroom", "disk-utilization/playbooks/notify_chatroom.yml"),
    ("CVE - Fetch and Commit", "cve-remediation/aap/playbooks/cve_fetch_and_commit.yml"),
    ("CVE - Sync and Deploy Remediation", "cve-remediation/aap/playbooks/cve_sync_and_deploy.yml"),
    ("CVE - Notify Mattermost Investigation", "cve-remediation/aap/playbooks/notify_mattermost_cve.yml"),
    ("SNOW - Auto Remediation", "ai-incident-triage/aap/playbooks/snow_auto_remediation.yml"),
    ("Incidents | Update Ticket", "ticket-enrichment/playbooks/update_snow_ticket.yml"),
    ("Incidents | Capacity - Disk Cleanup", "ticket-enrichment/playbooks/remediate_disk_cleanup.yml"),
    ("Incidents | High CPU - Process Cleanup", "ticket-enrichment/playbooks/remediate_process_cleanup.yml"),
]


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
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {self.token}"},
        )
        try:
            with urllib.request.urlopen(request, context=self.context, timeout=60) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")
            raise RuntimeError(f"{method} {path} returned HTTP {exc.code}: {detail}") from exc

    def find(self, endpoint: str, name: str) -> dict[str, Any] | None:
        result = self.request(f"/{endpoint}/?name={urllib.parse.quote(name)}")
        return next(iter(result.get("results", [])), None)

    def wait_for_project_sync(self, project_id: int, timeout: int = 180) -> None:
        """Wait until git SCM has playbooks; create job templates fails before that."""
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
                if playbooks:
                    return
            if last_status in {"failed", "error", "canceled"}:
                raise RuntimeError(f"AAP project {project_id} sync ended with status {last_status}")
            time.sleep(5)
        raise RuntimeError(
            f"AAP project {project_id} did not publish playbooks within {timeout}s (status={last_status})"
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--route", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--ao-api-url")
    parser.add_argument("--ao-api-host", default="")
    parser.add_argument("--ao-token")
    parser.add_argument("--ao-credential-id", default="")
    parser.add_argument("--ao-integration-id", default="")
    parser.add_argument("--control-repository", default=CONTROL_PROJECT_URL)
    parser.add_argument("--control-branch", default="main")
    parser.add_argument("--ao-demo-ref", default="abcc1a1482a")
    args = parser.parse_args()
    api = AAP(args.route, args.token)

    organizations = api.request("/organizations/?name=Default").get("results", [])
    if not organizations:
        raise RuntimeError("AAP Default organization was not found")
    organization = organizations[0]

    project = api.find("projects", PROJECT_NAME)
    project_payload = {
        "name": PROJECT_NAME,
        "description": "Playbooks used by the aap-orchestrator-demos AO workflows",
        "organization": organization["id"],
        "scm_type": "git",
        "scm_url": PROJECT_URL,
        "scm_branch": "main",
        "scm_update_on_launch": True,
        "scm_delete_on_update": False,
    }
    if project:
        project_id = project["id"]
        api.request(f"/projects/{project_id}/", "PATCH", project_payload)
        print(f"  ✓ AAP project updated: {PROJECT_NAME}")
    else:
        project_id = api.request("/projects/", "POST", project_payload)["id"]
        print(f"  ✓ AAP project created: {PROJECT_NAME}")

    print("  ✓ AAP project configured for SCM update on launch")
    api.wait_for_project_sync(project_id)
    print("  ✓ AAP project playbooks synced")

    existing = {item["name"]: item for item in api.request("/job_templates/?page_size=200").get("results", [])}
    inventories = api.request(f"/inventories/?organization={organization['id']}&page_size=1").get("results", [])
    inventory_id = inventories[0]["id"] if inventories else None
    for name, playbook in TEMPLATES:
        payload = {
            "name": name,
            "description": f"AAP Orchestrator demo playbook: {playbook}",
            "job_type": "run",
            "organization": organization["id"],
            "project": project_id,
            "playbook": playbook,
            "ask_variables_on_launch": True,
        }
        if inventory_id:
            payload["inventory"] = inventory_id
        current = existing.get(name)
        if current:
            api.request(f"/job_templates/{current['id']}/", "PATCH", payload)
            print(f"  ✓ AAP template updated: {name}")
        else:
            api.request("/job_templates/", "POST", payload)
            print(f"  ✓ AAP template created: {name}")
    print(f"✓ AAP demo project synchronized ({len(TEMPLATES)} job templates)")

    if args.ao_api_url and args.ao_token:
        control_project = api.find("projects", CONTROL_PROJECT_NAME)
        control_payload = {
            "name": CONTROL_PROJECT_NAME,
            "description": "AAP playbooks that synchronize AO control-plane resources",
            "organization": organization["id"],
            "scm_type": "git",
            "scm_url": args.control_repository,
            "scm_branch": args.control_branch,
            "scm_update_on_launch": True,
            "scm_delete_on_update": False,
        }
        if control_project:
            control_project_id = control_project["id"]
            api.request(f"/projects/{control_project_id}/", "PATCH", control_payload)
            print(f"  ✓ AAP control project updated: {CONTROL_PROJECT_NAME}")
        else:
            control_project_id = api.request("/projects/", "POST", control_payload)["id"]
            print(f"  ✓ AAP control project created: {CONTROL_PROJECT_NAME}")
        api.wait_for_project_sync(control_project_id)
        print("  ✓ AAP control project playbooks synced")

        control_template = api.find("job_templates", CONTROL_TEMPLATE_NAME)
        control_template_payload = {
            "name": CONTROL_TEMPLATE_NAME,
            "description": "Synchronize AO workflows from the pinned TMM GitHub repository",
            "job_type": "run",
            "organization": organization["id"],
            "project": control_project_id,
            "playbook": CONTROL_PLAYBOOK,
            "ask_variables_on_launch": True,
        }
        if inventory_id:
            control_template_payload["inventory"] = inventory_id
        else:
            control_template_payload["ask_inventory_on_launch"] = True
        if control_template:
            control_template_id = control_template["id"]
            api.request(f"/job_templates/{control_template_id}/", "PATCH", control_template_payload)
            print(f"  ✓ AAP control job template updated: {CONTROL_TEMPLATE_NAME}")
        else:
            control_template_id = api.request("/job_templates/", "POST", control_template_payload)["id"]
            print(f"  ✓ AAP control job template created: {CONTROL_TEMPLATE_NAME}")

        launch = api.request(
            f"/job_templates/{control_template_id}/launch/",
            "POST",
            {
                "extra_vars": {
                    "ao_api_url": args.ao_api_url,
                    "ao_api_host": args.ao_api_host,
                    "ao_api_token": args.ao_token,
                    "ao_demo_ref": args.ao_demo_ref,
                    "ao_aap_credential_id": args.ao_credential_id,
                    "ao_aap_integration_id": args.ao_integration_id,
                }
            },
        )
        job_id = launch.get("job")
        if not job_id:
            raise RuntimeError(f"AAP did not return a job id for {CONTROL_TEMPLATE_NAME}")
        print(f"  ✓ AAP launched {CONTROL_TEMPLATE_NAME} (job {job_id})")
        for _ in range(60):
            job = api.request(f"/jobs/{job_id}/")
            if job.get("status") in {"successful", "failed", "error", "canceled"}:
                if job["status"] != "successful":
                    raise RuntimeError(f"AAP job {job_id} ended with status {job['status']}")
                break
            time.sleep(5)
        else:
            raise RuntimeError(f"AAP job {job_id} did not finish within five minutes")
        print("✓ AO workflows synchronized by AAP")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"WARNING: AAP demo provisioning skipped: {exc}")
        raise SystemExit(1)
