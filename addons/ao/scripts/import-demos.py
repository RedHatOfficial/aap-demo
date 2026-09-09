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
import tarfile
import tempfile
import urllib.error
import urllib.request
from contextlib import contextmanager
from pathlib import Path
from typing import Any


UPSTREAM_REPOSITORY = "https://github.com/ansible-tmm/aap-orchestrator-demos"
UPSTREAM_REF = "abcc1a1482a"


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


@contextmanager
def workflow_sources(source_dir: str | None, repository: str, ref: str):
    """Yield upstream workflows without storing exports in this repository."""
    if source_dir:
        yield Path(source_dir)
        return

    archive_url = f"{repository.rstrip('/')}/archive/{ref}.tar.gz"
    with tempfile.TemporaryDirectory(prefix="aap-demo-ao-demos-") as temp_dir:
        archive_path = Path(temp_dir) / "demos.tar.gz"
        try:
            with urllib.request.urlopen(archive_url, timeout=60) as response:
                archive_path.write_bytes(response.read())
            extract_dir = Path(temp_dir) / "source"
            extract_dir.mkdir()
            with tarfile.open(archive_path, "r:gz") as archive:
                root = Path(temp_dir).resolve()
                for member in archive.getmembers():
                    target = (root / member.name).resolve()
                    if target != root and root not in target.parents:
                        raise RuntimeError("upstream demo archive contains an unsafe path")
                archive.extractall(extract_dir)
        except (OSError, tarfile.TarError, urllib.error.URLError) as exc:
            raise RuntimeError(f"unable to download upstream demos from {archive_url}: {exc}") from exc

        roots = [path for path in extract_dir.iterdir() if path.is_dir()]
        if len(roots) != 1 or not (roots[0] / "demos").is_dir():
            raise RuntimeError(f"upstream demo archive does not contain a demos directory: {archive_url}")
        yield roots[0]


def normalize(
    document: dict[str, Any],
    aap_credential_id: str,
    aap_integration_id: str | None = None,
    fallback_name: str | None = None,
    agent_credential_id: str | None = None,
    webhook_service_account_id: str | None = None,
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
        if node.get("type") == "webhook_trigger":
            # AO 2026.9 requires at least one authorized service account.
            # Older exports predate the field, so preserve explicit allowlists
            # and bind otherwise-unrestricted demo webhooks to our local caller.
            if webhook_service_account_id:
                parameters.setdefault(
                    "authorized_service_account_ids", [webhook_service_account_id]
                )
        elif node.get("type") == "agentic":
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
            if aap_integration_id:
                # AO keeps the runtime credential and the selected AAP
                # integration as separate fields. Set both so the workflow
                # builder opens with the aap-demo AAP integration selected.
                parameters["integration_id"] = aap_integration_id
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

    service_account_name = "aap-demo webhook caller"
    service_accounts = items(request(base, args.token, "GET", "/service_accounts?limit=100"))
    webhook_service_account = next(
        (
            account
            for account in service_accounts
            if account.get("name") == service_account_name
            and account.get("project_id") == project_id
        ),
        None,
    )
    if not webhook_service_account:
        webhook_service_account = request(
            base,
            args.token,
            "POST",
            "/service_accounts",
            {
                "name": service_account_name,
                "description": "Authorizes webhook-triggered workflows synchronized by aap-demo",
                "project_id": project_id,
            },
        )
        print(f"  ✓ AO service account created: {service_account_name}")
    webhook_service_account_id = webhook_service_account.get("id")
    if not webhook_service_account_id:
        raise RuntimeError("AO webhook service account did not return an id")

    existing = items(request(base, args.token, "GET", "/workflows?limit=100"))
    existing_by_name = {w.get("name"): w for w in existing}
    existing_by_source = {
        w.get("labels", {}).get("source_file"): w
        for w in existing
        if w.get("labels", {}).get("source_file")
    }
    with workflow_sources(args.source_dir, args.repository, args.ref) as source_dir:
        sources = sorted(source_dir.glob("*.json") if args.source_dir else source_dir.rglob("ao/*.json"))
        if not sources:
            raise RuntimeError(f"no workflow exports found in {source_dir}")
        raw_names = []
        for source in sources:
            raw_names.append(json.loads(source.read_text()).get("name") or source.stem)
        name_counts = {name: raw_names.count(name) for name in set(raw_names)}
        imported = 0
        for source, raw_name in zip(sources, raw_names):
            document = json.loads(source.read_text())
            workflow = normalize(
                document,
                args.aap_credential_id,
                args.aap_integration_id,
                source.stem,
                args.agent_credential_id,
                webhook_service_account_id,
            )
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
    parser.add_argument("--source-dir", help="Local workflow directory (testing override)")
    parser.add_argument("--repository", default=UPSTREAM_REPOSITORY)
    parser.add_argument("--ref", default=UPSTREAM_REF)
    parser.add_argument("--aap-credential-id", required=True)
    parser.add_argument("--aap-integration-id")
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
