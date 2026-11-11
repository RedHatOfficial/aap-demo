"""Build Fleet-specific AO adaptations without modifying upstream workflows."""

from __future__ import annotations

import argparse
import copy
import json
import os
import ssl
import sys
import urllib.request
from typing import Any, Callable, Dict


def unavailable_workflow_reasons() -> Dict[str, str]:
    """Report upstream scenarios not yet adapted for Fleet, not inferred live availability."""
    return {
        "snow-disk-autoremediate.json": "ServiceNow and LLM integrations; Fleet adaptation pending",
        "snow-incident-response.json": "ServiceNow and LLM integrations; Fleet adaptation pending",
        "cert-demo-101-manual.json": "LLM and certificate service inputs; Fleet adaptation pending",
        "cert-demo-101-webhook.json": "LLM, webhook and certificate inputs; adaptation pending",
        "rhel-cve-remediation.json": "Lightspeed, Gitea and LLM; Fleet adaptation pending",
        "rhel-cve-remediation-legacy.json": "Lightspeed, Gitea and LLM; Fleet adaptation pending",
        "disk-demo-tier-switch.json": "Mattermost and disk remediation; Fleet adaptation pending",
        "multi-os-cloud-patching.json": "AWS and Windows resources; Fleet adaptation pending",
        "ticket-enrichment.json": "ServiceNow and LLM integrations; Fleet adaptation pending",
    }


def stale_service_workflows(
    request: Callable[..., Dict[str, Any]], *, disk_ready: bool = False, service_ready: bool = False
) -> list[str]:
    response = request("GET", "/workflows?limit=100")
    if response.get("next"):
        raise RuntimeError("AO workflow list is incomplete")
    names = set()
    if not service_ready:
        names.add("Fleet | Disk and Service Demo")
    if not disk_ready:
        names.add("Fleet | disk-demo-101")
    rows = response.get("resources", response.get("results", []))
    return sorted(
        row["name"]
        for row in rows
        if row.get("name") in names and (row.get("labels") or {}).get("aap-demo-fleet") == "true"
    )


def adapt_disk_workflow(
    source: Dict[str, Any],
    credential_id: str,
    integration_id: str,
    *,
    include_service: bool = False,
) -> Dict[str, Any]:
    """Retain the real disk check; external notifications and remediation remain separate."""
    workflow = copy.deepcopy(source)
    triggers = [
        item for item in workflow.get("triggers", []) if item.get("type") == "manual_trigger"
    ]
    checks = [
        item
        for item in workflow.get("nodes", [])
        if item.get("type") == "aap_job_template"
        and item.get("parameters", item.get("config", {})).get("job_template_name")
        == "Disk Utilization Check"
    ]
    if len(triggers) != 1 or len(checks) != 1 or not credential_id or not integration_id:
        raise ValueError(
            "disk workflow must have one manual trigger, one disk check, and AAP bindings"
        )
    trigger, check = triggers[0], checks[0]
    parameters = check.pop("config", {}) if "parameters" not in check else check["parameters"]
    parameters["job_template_name"] = "Fleet | Disk Utilization Check"
    parameters["credential_id"] = credential_id
    parameters["integration_id"] = integration_id
    parameters.pop("job_template_id", None)
    parameters.get("extra_vars", {}).pop("test_disk_use_percent", None)
    if not parameters.get("extra_vars"):
        parameters.pop("extra_vars", None)
    check["parameters"] = parameters
    workflow["name"] = "Fleet | Disk Utilization Check"
    workflow["description"] = "Check the selected Fleet pod's persistent /var filesystem."
    workflow["triggers"] = [trigger]
    workflow["nodes"] = [check]
    workflow["edges"] = [{"from": trigger["id"], "to": check["id"]}]
    if include_service:
        workflow["name"] = "Fleet | Disk and Service Demo"
        workflow["description"] = "Check Fleet disk usage and start a short-lived demo service."
        workflow["nodes"].append(
            {
                "id": "fleet_service",
                "type": "aap_job_template",
                "name": "Start Fleet demo service",
                "parameters": {
                    "credential_id": credential_id,
                    "integration_id": integration_id,
                    "job_template_name": "Fleet | Start Demo Service",
                    "organization_name": "Ansible Product Demos (APD)",
                },
                "position": {"x": 720, "y": 435},
            }
        )
        workflow["edges"].append({"from": check["id"], "to": "fleet_service"})
    workflow.setdefault("schema_version", "2.0.0")
    return workflow


def adapt_disk_demo_101(
    source: Dict[str, Any], credential_id: str, integration_id: str
) -> Dict[str, Any]:
    """Preserve disk-demo-101 routing while keeping Fleet operations safe and explicit."""
    workflow = copy.deepcopy(source)
    triggers = [t for t in workflow.get("triggers", []) if t.get("type") == "manual_trigger"]
    mapping = {
        "Disk Utilization Check": "Fleet | Disk Utilization Check",
        "Linux - Remediate - Continue": "Fleet | Linux - Remediate - Continue",
        "Linux - Remediate - Disk Cleanup": "Fleet | Disk Cleanup Preview",
        "Linux - Remediate - Disk Expand": None,
        "Disk Utilization - Fallback": None,
    }
    found = {}
    switches = []
    for node in workflow.get("nodes", []):
        if node.get("type") == "switch":
            switches.append(node)
        if node.get("type") != "aap_job_template":
            continue
        parameters = node.get("parameters", node.get("config", {}))
        name = parameters.get("job_template_name")
        if name in mapping:
            if name in found:
                raise ValueError(f"disk-demo-101 contains duplicate node {name!r}")
            found[name] = node
    if len(triggers) != 1 or len(switches) != 1 or set(found) != set(mapping):
        raise ValueError("disk-demo-101 is missing a required trigger, switch, or route")
    if not credential_id or not integration_id:
        raise ValueError("disk-demo-101 requires AAP credential and integration bindings")
    for source_name, target_name in mapping.items():
        node = found[source_name]
        if target_name is None:
            node["name"] = "Manual intervention required"
            node["parameters"] = {
                "job_template_name": "Fleet | Manual Intervention Required",
                "organization_name": "Ansible Product Demos (APD)",
                "credential_id": credential_id,
                "integration_id": integration_id,
            }
            node.pop("config", None)
            continue
        parameters = node.pop("config", {}) if "parameters" not in node else node["parameters"]
        if source_name == "Linux - Remediate - Disk Cleanup":
            node["name"] = "Preview disk cleanup (estimates only)"
        parameters.update(
            {
                "job_template_name": target_name,
                "credential_id": credential_id,
                "integration_id": integration_id,
                "organization_name": "Default",
            }
        )
        parameters.pop("job_template_id", None)
        if source_name == "Disk Utilization Check":
            parameters.get("extra_vars", {}).pop("test_disk_use_percent", None)
            if not parameters.get("extra_vars"):
                parameters.pop("extra_vars", None)
        node["parameters"] = parameters
    retained = [*found.values(), switches[0]]
    keep_ids = {node["id"] for node in retained} | {triggers[0]["id"]}
    workflow["nodes"] = retained
    workflow["triggers"] = triggers
    workflow["edges"] = [
        edge
        for edge in workflow.get("edges", [])
        if edge.get("from") in keep_ids and edge.get("to") in keep_ids
    ]
    route_ids = {name: found[name]["id"] for name in mapping}
    switch_id = switches[0]["id"]
    expected_edges = {
        (triggers[0]["id"], route_ids["Disk Utilization Check"], None),
        (route_ids["Disk Utilization Check"], switch_id, None),
        (switch_id, route_ids["Linux - Remediate - Continue"], "case_0"),
        (switch_id, route_ids["Linux - Remediate - Disk Cleanup"], "case_1"),
        (switch_id, route_ids["Linux - Remediate - Disk Expand"], "case_2"),
        (switch_id, route_ids["Disk Utilization - Fallback"], "default"),
    }
    actual_edges = {
        (edge.get("from"), edge.get("to"), edge.get("from_port")) for edge in workflow["edges"]
    }
    if len(workflow["edges"]) != 6 or actual_edges != expected_edges:
        raise ValueError("disk-demo-101 is missing required routing edges")
    workflow["name"] = "Fleet | disk-demo-101"
    workflow["description"] = (
        "Check Fleet /var and route by usage; cleanup is preview-only, and PVC expansion "
        "requires manual intervention. Mattermost notifications are not sent."
    )
    workflow.setdefault("schema_version", "2.0.0")
    return workflow


def sync_disk_workflow(
    request: Callable[..., Dict[str, Any]],
    credential_id: str,
    integration_id: str,
    *,
    include_service: bool = False,
    demo_101: bool = False,
) -> str:
    """Create the Fleet copy once; never overwrite an existing or edited workflow."""
    projects = request("GET", "/projects?limit=100")
    workflows = request("GET", "/workflows?limit=100")
    if projects.get("next") or workflows.get("next"):
        raise RuntimeError("AO project or workflow list is incomplete")
    project_items = projects.get("resources", projects.get("results", []))
    workflow_items = workflows.get("resources", workflows.get("results", []))
    defaults = [p for p in project_items if p.get("is_default")]
    sources = [
        w
        for w in workflow_items
        if (w.get("labels") or {}).get("source_file") == "disk-demo-101.json"
    ]
    if len(defaults) != 1 or len(sources) != 1:
        raise RuntimeError("AO default project or source disk workflow is missing or ambiguous")
    source = request("GET", f"/workflows/{sources[0]['id']}")
    definition = (source.get("version") or {}).get("workflow_definition")
    if not isinstance(definition, dict):
        raise RuntimeError("AO source disk workflow definition is unavailable")
    adapted = (
        adapt_disk_demo_101(definition, credential_id, integration_id)
        if demo_101
        else adapt_disk_workflow(
            definition, credential_id, integration_id, include_service=include_service
        )
    )
    existing = [w for w in workflow_items if w.get("name") == adapted["name"]]
    if existing:
        if len(existing) != 1 or (existing[0].get("labels") or {}).get("aap-demo-fleet") != "true":
            raise RuntimeError("Fleet disk workflow name is already in use by another workflow")
        detail = request("GET", f"/workflows/{existing[0]['id']}")
        current = (detail.get("version") or {}).get("workflow_definition")
        if current != adapted or detail.get("project_id") != defaults[0]["id"]:
            raise RuntimeError("Fleet disk workflow has changed; review it before retrying")
        return str(existing[0]["id"])
    created = request(
        "POST",
        "/workflows",
        {
            "name": adapted["name"],
            "description": adapted["description"],
            "project_id": defaults[0]["id"],
            "labels": {
                "aap-demo": "true",
                "aap-demo-fleet": "true",
                "source_file": (
                    "fleet-disk-demo-101-routed.json"
                    if demo_101
                    else "fleet-disk-service-demo.json"
                    if include_service
                    else "fleet-disk-demo-101.json"
                ),
            },
            "workflow_definition": adapted,
        },
    )
    if not created.get("id"):
        raise RuntimeError("AO did not return the Fleet disk workflow ID")
    return str(created["id"])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--route", required=True)
    parser.add_argument("--credential-id", required=True)
    parser.add_argument("--integration-id", required=True)
    parser.add_argument("--include-service", action="store_true")
    parser.add_argument("--include-disk-demo-101", action="store_true")
    args = parser.parse_args()
    token = os.environ.get("AO_ACCESS_TOKEN", "")
    if not token:
        raise RuntimeError("AO access token is unavailable")
    base = f"https://{args.route}/api/v1"
    context = ssl._create_unverified_context()

    def request(method: str, path: str, payload: Any = None) -> Dict[str, Any]:
        data = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request(
            base + path,
            data=data,
            method=method,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, context=context, timeout=60) as response:
            content = response.read()
            return json.loads(content) if content else {}

    workflow_id = sync_disk_workflow(request, args.credential_id, args.integration_id)
    print(f"Fleet AO disk workflow ready: {workflow_id}")
    if args.include_disk_demo_101:
        workflow_id = sync_disk_workflow(
            request, args.credential_id, args.integration_id, demo_101=True
        )
        print(f"Fleet AO disk-demo-101 workflow ready: {workflow_id}")
        print(
            "  Cleanup is preview-only; PVC expansion requires manual intervention; "
            "Mattermost notifications are omitted."
        )
    else:
        print("Fleet disk-demo-101 unavailable: the manual-intervention template is not ready.")
    if args.include_service:
        workflow_id = sync_disk_workflow(
            request, args.credential_id, args.integration_id, include_service=True
        )
        print(f"Fleet AO disk-and-service workflow ready: {workflow_id}")
    else:
        print("Fleet disk-and-service workflow unavailable: the service template is not ready.")
    if not args.include_service or not args.include_disk_demo_101:
        for name in stale_service_workflows(
            request, disk_ready=args.include_disk_demo_101, service_ready=args.include_service
        ):
            print(f"  WARNING: {name} remains visible in AO but is not ready to run.")
    print("Other imported workflows are not yet adapted to Fleet:")
    for name, reason in unavailable_workflow_reasons().items():
        print(f"  {name}: {reason}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"ERROR: Fleet AO workflow synchronization failed: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
