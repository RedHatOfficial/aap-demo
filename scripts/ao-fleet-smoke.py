#!/usr/bin/env python3
"""Launch an AO workflow and verify a Fleet pod service changed state."""

from __future__ import annotations

import argparse
import json
import os
import ssl
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from typing import Any, Callable, Dict, Optional


def run_smoke(
    request: Callable[..., Dict[str, Any]],
    service_state: Callable[[], str],
    workflow_id: str,
    trigger_id: str,
    expected_state: str,
    *,
    timeout: int = 900,
    sleep: Callable[[float], None] = time.sleep,
) -> str:
    before = service_state()
    if before == expected_state:
        raise RuntimeError(f"service is already {expected_state}; cannot verify a state change")
    execution = request(
        "POST", "/executions", {"workflow_id": workflow_id, "trigger_node_id": trigger_id}
    )
    execution_id = execution.get("id")
    if not execution_id:
        raise RuntimeError("AO did not return an execution ID")
    deadline = time.monotonic() + timeout
    status = "pending"
    while time.monotonic() < deadline:
        status = str(
            request("GET", f"/executions/{urllib.parse.quote(str(execution_id), safe='')}").get(
                "status", ""
            )
        )
        if status in {"completed", "completed_with_errors", "failed", "cancelled"}:
            break
        sleep(2)
    else:
        raise RuntimeError(f"AO execution {execution_id} timed out (last status: {status})")
    if status != "completed":
        raise RuntimeError(f"AO execution {execution_id} ended with status {status}")
    activities = request(
        "GET", f"/executions/{urllib.parse.quote(str(execution_id), safe='')}/activities"
    )
    if activities.get("next"):
        raise RuntimeError("AO activity list is incomplete")
    items = activities.get("resources", activities.get("results", []))
    if not any(
        (item.get("input_data") or {}).get("job_template_name") == "Fleet | Start Demo Service"
        and (item.get("output_data") or {}).get("job_status") == "successful"
        for item in items
    ):
        raise RuntimeError("AO execution did not run the Fleet service job successfully")
    after = service_state()
    if before == after:
        raise RuntimeError(f"service state did not change (remained {after})")
    if after != expected_state:
        raise RuntimeError(f"service ended in state {after}, expected {expected_state}")
    return str(execution_id)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ao-url", required=True, help="AO URL including /api/v1")
    parser.add_argument("--workflow-id", required=True)
    parser.add_argument("--trigger-id", required=True)
    parser.add_argument("--namespace", default="fleet")
    parser.add_argument("--pod", required=True)
    parser.add_argument("--service", required=True)
    parser.add_argument("--expected-state", required=True, choices=("active", "inactive"))
    parser.add_argument("--ca-file", help="CA certificate for the AO route")
    args = parser.parse_args()
    token = os.environ.get("AO_API_TOKEN", "")
    if not token:
        raise RuntimeError("set AO_API_TOKEN to an AO API token before running the smoke test")
    context = ssl.create_default_context(cafile=args.ca_file)

    def request(method: str, path: str, body: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(
            args.ao_url.rstrip("/") + path,
            data=data,
            method=method,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, context=context, timeout=30) as response:
            return json.load(response)

    def service_state() -> str:
        result = subprocess.run(
            [
                "oc",
                "exec",
                "-n",
                args.namespace,
                args.pod,
                "--",
                "systemctl",
                "is-active",
                args.service,
            ],
            capture_output=True,
            text=True,
        )
        state = result.stdout.strip()
        if state not in {"active", "inactive", "failed", "activating", "deactivating"}:
            raise RuntimeError("unable to read the requested service state from the Fleet pod")
        return state

    execution_id = run_smoke(
        request, service_state, args.workflow_id, args.trigger_id, args.expected_state
    )
    print(
        f"PASS: AO execution {execution_id} completed and service changed to {args.expected_state}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
