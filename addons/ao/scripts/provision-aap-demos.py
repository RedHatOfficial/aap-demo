#!/usr/bin/env python3
"""Provision AAP projects and job templates used by the AO demo workflows."""

from __future__ import annotations

import argparse
import json
import ssl
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


PROJECT_NAME = "AAP Orchestrator Demos"
PROJECT_URL = "https://github.com/ansible-tmm/aap-orchestrator-demos.git"

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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--route", required=True)
    parser.add_argument("--token", required=True)
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
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"WARNING: AAP demo provisioning skipped: {exc}")
        raise SystemExit(1)
