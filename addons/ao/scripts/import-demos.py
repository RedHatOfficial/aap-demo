#!/usr/bin/env python3
"""Import the upstream aap-orchestrator-demos workflows into Automation Orchestrator.

The upstream exports intentionally contain environment-specific placeholders.  This
adapter keeps the exports unchanged and fills in the credentials supplied by the
aap-demo wiring layer at import time.
"""

from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


def request(base: str, token: str, method: str, path: str, body: Any = None) -> Any:
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        f"{base.rstrip('/')}{path}",
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    context = ssl._create_unverified_context()
    try:
        with urllib.request.urlopen(req, context=context, timeout=60) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise RuntimeError(f"{method} {path} returned HTTP {exc.code}: {detail}") from exc


def items(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, dict):
        value = payload.get("resources", payload.get("results", []))
        return value if isinstance(value, list) else []
    return []


def normalize(
    document: dict[str, Any],
    aap_credential_id: str,
    fallback_name: str | None = None,
    agent_credential_id: str | None = None,
) -> dict[str, Any]:
    workflow = dict(document)
    workflow.setdefault("schema_version", "2.0.0")
    if fallback_name:
        workflow.setdefault("name", fallback_name)

    for node in [*workflow.get("triggers", []), *workflow.get("nodes", [])]:
        # Older upstream exports used config; AO 2026.8 expects parameters.
        if "parameters" not in node and "config" in node:
            node["parameters"] = node.pop("config")
        parameters = node.setdefault("parameters", {})
        if node.get("type") == "agentic":
            if "response_schema" in parameters and "responseSchema" not in parameters:
                parameters["responseSchema"] = parameters.pop("response_schema")
            # SELECTED with an empty list is rejected by AO.  The demo MCP server
            # is deliberately wired with all discovered tools, so ALL is the most
            # faithful portable default for exports that did not carry selections.
            if parameters.get("tool_selection_strategy") == "SELECTED" and not parameters.get("tool_selections"):
                parameters["tool_selection_strategy"] = "ALL"
                parameters.pop("tool_selections", None)
            elif "tool_selection_strategy" not in parameters:
                parameters["tool_selection_strategy"] = "ALL"
            # Upstream exports contain environment-specific LLM credential IDs.
            # AO validates those strings but rejects unknown IDs on create.
            if agent_credential_id:
                parameters["credential_id"] = agent_credential_id
            else:
                parameters.pop("credential_id", None)
        elif node.get("type") == "aap_job_template":
            # Always bind AAP nodes to the credential created by aap-demo. The
            # upstream exports may contain a valid-looking UUID from another AO.
            parameters["credential_id"] = aap_credential_id
            if isinstance(parameters.get("job_template_id"), str) and parameters["job_template_id"].startswith(("YOUR_", "REPLACE_WITH_")):
                parameters.pop("job_template_id")

    return workflow


def import_workflows(args: argparse.Namespace) -> int:
    base = f"https://{args.route}/api/v1"
    projects = items(request(base, args.token, "GET", "/projects?limit=100"))
    project_id = args.project_id or next((p["id"] for p in projects if p.get("is_default")), None)
    project_id = project_id or (projects[0]["id"] if projects else None)
    if not project_id:
        raise RuntimeError("Automation Orchestrator has no project to receive demo workflows")

    existing = items(request(base, args.token, "GET", "/workflows?limit=100"))
    existing_by_name = {w.get("name"): w for w in existing}
    existing_by_source = {
        w.get("labels", {}).get("source_file"): w
        for w in existing
        if w.get("labels", {}).get("source_file")
    }
    sources = sorted(Path(args.source_dir).glob("*.json"))
    raw_names = []
    for source in sources:
        raw_names.append(json.loads(source.read_text()).get("name") or source.stem)
    name_counts = {name: raw_names.count(name) for name in set(raw_names)}
    imported = 0
    for source, raw_name in zip(sources, raw_names):
        document = json.loads(source.read_text())
        workflow = normalize(document, args.aap_credential_id, source.stem, args.agent_credential_id)
        name = workflow.get("name") or source.stem
        if name_counts.get(raw_name, 0) > 1 and source.stem.endswith("-legacy"):
            name = f"{name} (legacy)"
        workflow["name"] = name
        payload = {
            "name": name,
            "description": workflow.get("description"),
            "labels": {
                "aap-demo": "true",
                "source": "ansible-tmm/aap-orchestrator-demos",
                "source_file": source.name,
            },
            "workflow_definition": workflow,
            "project_id": project_id,
        }
        current = existing_by_source.get(source.name) or existing_by_name.get(name)
        if current:
            request(base, args.token, "PATCH", f"/workflows/{current['id']}", {
                "description": payload["description"],
                "labels": payload["labels"],
                "workflow_definition": workflow,
                "change_description": "Synchronized from aap-orchestrator-demos by aap-demo",
            })
            action = "updated"
        else:
            created = request(base, args.token, "POST", "/workflows", payload)
            existing_by_name[name] = created
            existing_by_source[source.name] = created
            action = "imported"
        print(f"  ✓ {action}: {name}")
        imported += 1
    print(f"✓ AO demos synchronized ({imported} workflows, project {project_id})")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--route", required=True, help="AO route hostname")
    parser.add_argument("--token", required=True)
    parser.add_argument("--source-dir", required=True)
    parser.add_argument("--aap-credential-id", required=True)
    parser.add_argument("--agent-credential-id")
    parser.add_argument("--project-id")
    args = parser.parse_args()
    try:
        return import_workflows(args)
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"WARNING: AO demo synchronization skipped: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
