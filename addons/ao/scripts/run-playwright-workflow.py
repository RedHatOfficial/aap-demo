#!/usr/bin/env python3
"""Run one exact Ansible UI Playwright test through an AO workflow."""

from __future__ import annotations

import argparse
import json
import ssl
import sys
import time
import urllib.error
import urllib.request
from typing import Any


TERMINAL_STATUSES = {"completed", "failed", "canceled", "cancelled"}


def build_execution_payload(
    workflow_id: str,
    ref: str,
    test_path: str,
    test_title: str,
    target_name: str,
    execute_mutations: bool,
) -> dict[str, object]:
    """Build the minimal AO execution request for one selected test."""
    return {
        "workflow_id": workflow_id,
        "trigger_node_id": "trigger_manual",
        "input_data": {
            "ref": ref,
            "test_path": test_path,
            "test_title": test_title,
            "target_name": target_name,
            "execute_mutations": execute_mutations,
        },
        "use_published": False,
    }


def request_json(
    route: str,
    token: str,
    method: str,
    path: str,
    body: dict[str, object] | None = None,
) -> dict[str, Any]:
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(
        f"https://{route.rstrip('/')}/api/v1{path}",
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
        with urllib.request.urlopen(request, context=context, timeout=60) as response:
            raw = response.read()
            value = json.loads(raw) if raw else {}
            return value if isinstance(value, dict) else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise RuntimeError(f"{method} {path} returned HTTP {exc.code}: {detail}") from exc


def print_status(execution: dict[str, Any]) -> None:
    status = execution.get("status", "unknown")
    output = {
        "execution_id": execution.get("id") or execution.get("execution_id"),
        "status": status,
        "workflow_version": execution.get("workflow_version"),
        "error_details": execution.get("error_details"),
    }
    print(json.dumps(output, sort_keys=True))


def run(args: argparse.Namespace) -> int:
    if not args.test_title.strip():
        print("ERROR: --test-title must not be empty", file=sys.stderr)
        return 2
    payload = build_execution_payload(
        args.workflow_id,
        args.ref,
        args.test_path,
        args.test_title,
        args.target_name,
        args.execute_mutations,
    )
    created = request_json(args.route, args.token, "POST", "/executions", payload)
    execution_id = created.get("id") or created.get("execution_id")
    if not execution_id:
        raise RuntimeError("AO execution response did not include an execution id")

    while True:
        execution = request_json(
            args.route,
            args.token,
            "GET",
            f"/executions/{execution_id}",
        )
        if execution.get("status") in TERMINAL_STATUSES:
            print_status(execution)
            return 0 if execution.get("status") == "completed" else 1
        time.sleep(args.poll_interval)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--route", required=True, help="AO route hostname")
    parser.add_argument("--token", required=True, help="AO bearer token")
    parser.add_argument("--workflow-id", required=True)
    parser.add_argument("--ref", default="devel")
    parser.add_argument("--test-path", required=True)
    parser.add_argument("--test-title", required=True)
    parser.add_argument("--target-name", required=True)
    parser.add_argument("--execute-mutations", action="store_true")
    parser.add_argument("--poll-interval", type=float, default=5.0, help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        return run(args)
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"ERROR: AO Playwright execution failed: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
