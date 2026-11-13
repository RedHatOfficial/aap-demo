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
from pathlib import Path
from typing import Any

PROJECT_NAME = "AAP Orchestrator Demos"
PROJECT_URL = "https://github.com/ansible-tmm/aap-orchestrator-demos.git"
FLEET_PROJECT_NAME = "AAP Demo Fleet Workflow Sources"
FLEET_PROJECT_MARKER = "Managed by aap-demo product-demos Fleet integration"
CONTROL_PROJECT_NAME = "AAP Demo Control Plane"
CONTROL_PROJECT_URL = "https://github.com/RedHatOfficial/aap-demo.git"
CONTROL_TEMPLATE_NAME = "Sync AO Workflows from TMM"
CONTROL_PLAYBOOK = "addons/ao/playbooks/sync-ao-demos.yml"
CONTROL_FORKS = 10
EXIT_LICENSE_REQUIRED = 2
FLEET_INVENTORY = "aap-demo-fleet"
FLEET_CREDENTIAL = "aap-demo-fleet-ssh"

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
    (
        "CVE - Notify Mattermost Investigation",
        "cve-remediation/aap/playbooks/notify_mattermost_cve.yml",
    ),
    ("SNOW - Auto Remediation", "ai-incident-triage/aap/playbooks/snow_auto_remediation.yml"),
    ("Incidents | Update Ticket", "ticket-enrichment/playbooks/update_snow_ticket.yml"),
    (
        "Incidents | Capacity - Disk Cleanup",
        "ticket-enrichment/playbooks/remediate_disk_cleanup.yml",
    ),
    (
        "Incidents | High CPU - Process Cleanup",
        "ticket-enrichment/playbooks/remediate_process_cleanup.yml",
    ),
]

FLEET_TEMPLATE_NAMES = {
    "Disk Utilization Check",
    "Linux - Remediate - Continue",
    "Linux - Remediate - Disk Cleanup",
}
FLEET_TEMPLATE_MARKER = "Managed by aap-demo product-demos Fleet integration"


def control_job_extra_vars(args: argparse.Namespace) -> dict[str, str]:
    """Build the AO sync playbook inputs from provision command arguments."""
    return {
        "ao_api_url": args.ao_api_url,
        "ao_api_host": args.ao_api_host,
        "ao_api_token": args.ao_token,
        "ao_demo_ref": args.ao_demo_ref,
        "ao_demo_repository": getattr(args, "ao_demo_repository", PROJECT_URL)
        .rstrip("/")
        .removesuffix(".git"),
        "ao_aap_credential_id": args.ao_credential_id,
        "ao_aap_integration_id": args.ao_integration_id,
        "ao_agent_credential_id": args.ao_agent_credential_id,
        "ao_agent_integration_id": args.ao_agent_integration_id,
        "ao_agent_model_id": args.ao_agent_model_id,
    }


def report_missing_license(route: str) -> None:
    """Tell the user how to register AAP before retrying the sync job."""
    print("WARNING: AAP does not have a registered subscription.")
    print(f"  Please log into AAP at https://{route} and register a subscription.")


def demo_project_payload(organization_id: int, repository: str, ref: str) -> dict[str, Any]:
    return {
        "name": PROJECT_NAME,
        "description": "Playbooks used by the aap-orchestrator-demos AO workflows",
        "organization": organization_id,
        "scm_type": "git",
        "scm_url": repository,
        "scm_branch": ref,
        "scm_update_on_launch": True,
        "scm_delete_on_update": False,
    }


def resolve_fleet_binding(api: Any, organization_id: int, host: str) -> tuple[int, int]:
    """Resolve existing Fleet objects without reading or changing their secrets."""

    def unique(endpoint: str, name: str, query: str) -> dict[str, Any]:
        result = api.request(f"/{endpoint}/?{query}&name={urllib.parse.quote(name, safe='')}")
        matches = [item for item in result.get("results", []) if item.get("name") == name]
        if len(matches) != 1 or result.get("next"):
            raise RuntimeError(f"expected exactly one {endpoint} entry named {name!r}")
        return matches[0]

    inventory = unique("inventories", FLEET_INVENTORY, f"organization={organization_id}")
    credential = unique("credentials", FLEET_CREDENTIAL, f"organization={organization_id}")
    kind = credential.get("kind") or (credential.get("summary_fields") or {}).get(
        "credential_type", {}
    ).get("kind")
    if kind != "ssh":
        raise RuntimeError(f"Fleet credential {FLEET_CREDENTIAL!r} is not a machine credential")
    try:
        unique("hosts", host, f"inventory={inventory['id']}")
    except RuntimeError as exc:
        raise RuntimeError(f"Fleet host {host!r} is missing or ambiguous in inventory") from exc
    return int(inventory["id"]), int(credential["id"])


def provision_fleet_templates(
    api: Any,
    organization_id: int,
    project_id: int,
    inventory_id: int,
    credential_id: int,
    host: str,
    *,
    legacy_project_id: int | None = None,
) -> None:
    """Create separately named Fleet templates without modifying the upstream templates."""
    for name, playbook in TEMPLATES:
        if name not in FLEET_TEMPLATE_NAMES:
            continue
        fleet_name = (
            "Fleet | Disk Cleanup Preview"
            if name == "Linux - Remediate - Disk Cleanup"
            else f"Fleet | {name}"
        )
        current = api.find("job_templates", fleet_name)
        if current and (
            current.get("description") != FLEET_TEMPLATE_MARKER
            or current.get("organization") != organization_id
        ):
            raise RuntimeError(f"refusing to overwrite existing job template {fleet_name!r}")
        payload = {
            "name": fleet_name,
            "description": FLEET_TEMPLATE_MARKER,
            "organization": organization_id,
            "job_type": "check" if name == "Linux - Remediate - Disk Cleanup" else "run",
            "project": project_id,
            "playbook": playbook,
            "inventory": inventory_id,
            "limit": host,
            "ask_variables_on_launch": True,
        }
        ensure_owned_template(
            api, payload, credential_id, current, legacy_project_id=legacy_project_id
        )


def ensure_owned_template(
    api: Any,
    payload: dict[str, Any],
    credential_id: int,
    current: Any,
    *,
    legacy_project_id: int | None = None,
) -> None:
    name = payload["name"]
    if current:
        if legacy_project_id is not None and current.get("project") == legacy_project_id:
            previous = {**payload, "project": legacy_project_id}
            if any(current.get(key) != value for key, value in previous.items()):
                raise RuntimeError(
                    f"Fleet job template {name!r} has changed; review before retrying"
                )
            api.request(
                f"/job_templates/{current['id']}/", "PATCH", {"project": payload["project"]}
            )
            current = {**current, "project": payload["project"]}
        if any(current.get(key) != value for key, value in payload.items()):
            raise RuntimeError(f"Fleet job template {name!r} has changed; review before retrying")
        template_id = current["id"]
    else:
        template_id = api.request("/job_templates/", "POST", payload)["id"]
    credentials_path = f"/job_templates/{template_id}/credentials/"
    credentials = api.request(credentials_path)
    if credentials.get("next"):
        raise RuntimeError(f"too many credentials attached to Fleet template {name!r}")
    if not any(item.get("id") == credential_id for item in credentials.get("results", [])):
        api.request(credentials_path, "POST", {"id": credential_id})


def provision_service_template(
    api: Any,
    organization_id: int,
    project_id: int,
    inventory_id: int,
    credential_id: int,
    host: str,
) -> None:
    """Bind the Product Demos service playbook to the selected Fleet host."""
    name = "Fleet | Start Demo Service"
    current = api.find("job_templates", name)
    payload = {
        "name": name,
        "description": FLEET_TEMPLATE_MARKER,
        "organization": organization_id,
        "job_type": "run",
        "project": project_id,
        "playbook": "linux/fleet_ao_smoke.yml",
        "inventory": inventory_id,
        "limit": host,
        "ask_variables_on_launch": False,
        "extra_vars": json.dumps({"_hosts": host}),
    }
    old_script = (
        "systemctl is-active --quiet aap-demo-fleet-smoke.service || "
        "systemd-run --collect --unit=aap-demo-fleet-smoke /usr/bin/sleep 300"
    )
    previous = {
        **payload,
        "playbook": "linux/run_script.yml",
        "extra_vars": json.dumps({"_hosts": host, "shell_script": old_script}),
    }
    if current and all(current.get(key) == value for key, value in previous.items()):
        api.request(f"/job_templates/{current['id']}/", "PATCH", payload)
        current = {**current, **payload}
    ensure_owned_template(api, payload, credential_id, current)


def provision_manual_intervention_template(
    api: Any,
    organization_id: int,
    project_id: int,
    inventory_id: int,
    credential_id: int,
    host: str,
) -> None:
    script = (
        "printf '%s\\n' 'Fleet PVC expansion is not supported or disk usage could not be "
        "classified; manual intervention is required.' >&2"
    )
    legacy_script = f"{script}; exit 1"
    _provision_script_template(
        api,
        organization_id,
        project_id,
        inventory_id,
        credential_id,
        host,
        "Fleet | Manual Intervention Required",
        script,
        legacy_scripts=(legacy_script,),
    )


def _provision_script_template(
    api: Any,
    organization_id: int,
    project_id: int,
    inventory_id: int,
    credential_id: int,
    host: str,
    name: str,
    script: str,
    *,
    legacy_scripts: tuple[str, ...] = (),
) -> None:
    current = api.find("job_templates", name)
    if current and (
        current.get("description") != FLEET_TEMPLATE_MARKER
        or current.get("organization") != organization_id
    ):
        raise RuntimeError(f"refusing to overwrite existing job template {name!r}")
    payload = {
        "name": name,
        "description": FLEET_TEMPLATE_MARKER,
        "organization": organization_id,
        "job_type": "run",
        "project": project_id,
        "playbook": "linux/run_script.yml",
        "inventory": inventory_id,
        "limit": host,
        "ask_variables_on_launch": False,
        "extra_vars": json.dumps({"_hosts": host, "shell_script": script}),
    }
    legacy_extra_vars = {
        json.dumps({"_hosts": host, "shell_script": legacy_script})
        for legacy_script in legacy_scripts
    }
    if current and current.get("extra_vars") in legacy_extra_vars:
        unchanged = all(
            current.get(key) == value for key, value in payload.items() if key != "extra_vars"
        )
        if unchanged:
            api.request(f"/job_templates/{current['id']}/", "PATCH", payload)
            current = {**current, **payload}
    ensure_owned_template(api, payload, credential_id, current)


def product_demos_project(api: Any) -> tuple[int, int]:
    """Find the Product Demos project in its own organization."""
    org_name = "Ansible Product Demos (APD)"
    organizations = api.request(f"/organizations/?name={urllib.parse.quote(org_name, safe='')}")
    orgs = [row for row in organizations.get("results", []) if row.get("name") == org_name]
    if len(orgs) != 1 or organizations.get("next"):
        raise RuntimeError("Product Demos organization is missing or ambiguous")
    org_id = orgs[0]["id"]
    projects = api.request(f"/projects/?organization={org_id}&name=Ansible%20Product%20Demos")
    found = [
        row for row in projects.get("results", []) if row.get("name") == "Ansible Product Demos"
    ]
    if len(found) != 1 or projects.get("next"):
        raise RuntimeError("Product Demos project is missing or ambiguous")
    return int(org_id), int(found[0]["id"])


def ensure_fleet_project(
    api: Any, organization_id: int, ref: str, *, repository: str = PROJECT_URL
) -> int:
    """Keep Fleet playbooks pinned separately from the shared AO demo project."""
    if not ref:
        raise RuntimeError("Fleet demo source ref must not be empty")
    payload = {
        "name": FLEET_PROJECT_NAME,
        "description": FLEET_PROJECT_MARKER,
        "organization": organization_id,
        "scm_type": "git",
        "scm_url": repository,
        "scm_branch": ref,
        "scm_update_on_launch": True,
        "scm_delete_on_update": False,
    }
    current = api.find("projects", FLEET_PROJECT_NAME)
    if current:
        if any(current.get(key) != value for key, value in payload.items()):
            raise RuntimeError("Fleet demo source project has changed; review before retrying")
        project_id = current["id"]
    else:
        project_id = api.request("/projects/", "POST", payload)["id"]
    api.wait_for_project_sync(project_id)
    return int(project_id)


def provision_optional_fleet_templates(
    api: Any, inventory_id: int, credential_id: int, host: str
) -> tuple[bool, bool]:
    """Provision service and manual-response templates independently."""
    try:
        org_id, project_id = product_demos_project(api)
        api.wait_for_project_sync(project_id)
    except RuntimeError as exc:
        print(f"WARNING: Fleet service and manual-intervention demos unavailable: {exc}")
        return False, False
    ready = []
    for label, provision in (
        ("service", provision_service_template),
        ("manual-intervention", provision_manual_intervention_template),
    ):
        try:
            if label == "service":
                playbooks = api.request(f"/projects/{project_id}/playbooks/")
                if isinstance(playbooks, dict):
                    playbooks = playbooks.get("results") or playbooks.get("playbooks") or []
                if "linux/fleet_ao_smoke.yml" not in playbooks:
                    raise RuntimeError(
                        "linux/fleet_ao_smoke.yml is missing from the synced Product Demos "
                        "project; use a revision containing ansible/product-demos PR 403"
                    )
            provision(api, org_id, project_id, inventory_id, credential_id, host)
            ready.append(True)
        except RuntimeError as exc:
            print(f"WARNING: Fleet {label} demo unavailable: {exc}")
            ready.append(False)
    return ready[0], ready[1]


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
        # Reusing an already-synced project is common on re-enable and avoids
        # starting another potentially slow SCM update just to discover that
        # the required playbooks are already available.
        project = self.request(f"/projects/{project_id}/")
        last_status = str(project.get("status") or "unknown")
        if last_status == "successful":
            playbooks = self.request(f"/projects/{project_id}/playbooks/")
            if isinstance(playbooks, dict):
                playbooks = playbooks.get("results") or playbooks.get("playbooks") or []
            if playbooks:
                return

        try:
            self.request(f"/projects/{project_id}/update/", "POST")
        except RuntimeError as exc:
            if "HTTP 400" not in str(exc):
                raise
        deadline = time.time() + timeout
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
            f"AAP project {project_id} did not publish playbooks within {timeout}s "
            f"(status={last_status})"
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
    parser.add_argument("--ao-agent-credential-id", default="")
    parser.add_argument("--ao-agent-integration-id", default="")
    parser.add_argument("--ao-agent-model-id", default="")
    parser.add_argument("--control-repository", default=CONTROL_PROJECT_URL)
    parser.add_argument("--control-branch", default="main")
    parser.add_argument("--ao-demo-ref", default="abcc1a1482a")
    parser.add_argument("--ao-demo-repository", default=PROJECT_URL)
    parser.add_argument("--fleet-host", default="")
    parser.add_argument("--fleet-service-status-file", default="")
    parser.add_argument("--fleet-manual-status-file", default="")
    args = parser.parse_args()
    if args.fleet_service_status_file:
        Path(args.fleet_service_status_file).write_text("unavailable\n", encoding="utf-8")
    if args.fleet_manual_status_file:
        Path(args.fleet_manual_status_file).write_text("unavailable\n", encoding="utf-8")
    api = AAP(args.route, args.token)

    organizations = api.request("/organizations/?name=Default").get("results", [])
    if not organizations:
        raise RuntimeError("AAP Default organization was not found")
    organization = organizations[0]
    fleet_binding = (
        resolve_fleet_binding(api, organization["id"], args.fleet_host) if args.fleet_host else None
    )

    project = api.find("projects", PROJECT_NAME)
    project_payload = demo_project_payload(
        organization["id"], args.ao_demo_repository, args.ao_demo_ref
    )
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
    if fleet_binding:
        fleet_project_id = ensure_fleet_project(
            api, organization["id"], args.ao_demo_ref, repository=args.ao_demo_repository
        )
        provision_fleet_templates(
            api,
            organization["id"],
            fleet_project_id,
            fleet_binding[0],
            fleet_binding[1],
            args.fleet_host,
            legacy_project_id=project_id,
        )
        service_ready, manual_ready = provision_optional_fleet_templates(
            api, fleet_binding[0], fleet_binding[1], args.fleet_host
        )
        if service_ready and args.fleet_service_status_file:
            Path(args.fleet_service_status_file).write_text("ready\n", encoding="utf-8")
        if manual_ready and args.fleet_manual_status_file:
            Path(args.fleet_manual_status_file).write_text("ready\n", encoding="utf-8")

    existing = {
        item["name"]: item
        for item in api.request("/job_templates/?page_size=200").get("results", [])
    }
    inventories = api.request(f"/inventories/?organization={organization['id']}&page_size=1").get(
        "results", []
    )
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
            "forks": CONTROL_FORKS,
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
            control_template_id = api.request("/job_templates/", "POST", control_template_payload)[
                "id"
            ]
            print(f"  ✓ AAP control job template created: {CONTROL_TEMPLATE_NAME}")

        try:
            launch = api.request(
                f"/job_templates/{control_template_id}/launch/",
                "POST",
                {
                    "extra_vars": {
                        **control_job_extra_vars(args),
                    }
                },
            )
        except RuntimeError as exc:
            if "HTTP 403" in str(exc) and "License is missing" in str(exc):
                report_missing_license(args.route)
                return EXIT_LICENSE_REQUIRED
            raise
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
        raise SystemExit(1) from exc
