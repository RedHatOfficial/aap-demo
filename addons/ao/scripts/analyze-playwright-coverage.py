#!/usr/bin/env python3
"""Deterministically inventory Playwright tests and propose coverage work.

This intentionally uses source-text heuristics instead of an LLM. It is designed
to produce a conservative report: uncertain matches are reported as gaps rather
than treated as covered.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Any


AREAS = {
    "authentication": ("login", "logout", "oauth", "oidc", "token", "password", "sso"),
    "controller": ("job template", "workflow job", "inventory", "organization", "credential", "project"),
    "execution": ("launch", "job status", "execution", "playbook", "execution environment"),
    "gateway": ("gateway", "/api/gateway", "route", "proxy"),
    "hub": ("hub", "automation hub", "collection", "container", "registry"),
    "eda": ("event-driven", "eda", "rulebook", "activation", "event stream"),
    "permissions": ("permission", "role", "rbac", "access", "forbidden", "unauthorized"),
    "failure handling": ("error", "fail", "invalid", "timeout", "unavailable", "retry"),
    "cleanup": ("delete", "remove", "cleanup", "teardown", "aftereach", "afterall"),
}


def normalize(value: str) -> str:
    value = value.lower()
    value = re.sub(r"\$\{[^}]+\}|['\"`][^'\"`]*['\"`]", "value", value)
    value = re.sub(r"\d+", "n", value)
    return re.sub(r"\s+", " ", value).strip()


def area_names(text: str) -> list[str]:
    lowered = text.lower()
    return [name for name, terms in AREAS.items() if any(term in lowered for term in terms)]


def matching_brace(source: str, opening: int) -> int:
    """Find a closing brace while ignoring strings and comments."""
    depth = 0
    quote = ""
    escaped = False
    line_comment = False
    block_comment = False
    index = opening
    while index < len(source):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""
        if line_comment:
            if char == "\n":
                line_comment = False
        elif block_comment:
            if char == "*" and next_char == "/":
                block_comment = False
                index += 1
        elif quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = ""
        elif char in "'\"`":
            quote = char
        elif char == "/" and next_char == "/":
            line_comment = True
            index += 1
        elif char == "/" and next_char == "*":
            block_comment = True
            index += 1
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    return len(source)


def extract_tests(source: str) -> list[dict[str, Any]]:
    """Extract test blocks with a small balanced-brace scanner."""
    starts = list(re.finditer(r"(?:test|it)\s*\(\s*(['\"`])([^'\"`]+)\1", source))
    tests: list[dict[str, Any]] = []
    for match in starts:
        arrow = source.find("=>", match.end())
        brace = source.find("{", arrow if arrow >= 0 else match.end())
        if brace < 0:
            continue
        end = matching_brace(source, brace)
        body = source[brace:end]
        actions = sorted(set(re.findall(r"\b(?:page|request|context)\.[A-Za-z_][\w]*", body)))
        assertions = sorted(set(re.findall(r"\bexpect\([^\n]{0,180}", body)))
        dependencies = sorted(set(re.findall(r"(?:getByRole|getByText|getByLabel|getByTestId|locator)\([^\n]{0,160}", body)))
        cleanup = sorted(set(re.findall(r"\b(?:delete|remove|cleanup|teardown|afterEach|afterAll)\b[^\n]{0,120}", body, re.I)))
        areas = area_names(match.group(2) + " " + body)
        fingerprint_source = "|".join([
            ",".join(actions),
            ",".join(assertions),
            ",".join(areas),
        ])
        fingerprint = hashlib.sha1(normalize(fingerprint_source).encode()).hexdigest()[:12]
        tests.append({
            "title": match.group(2),
            "areas": areas,
            "actions": actions,
            "assertions": assertions,
            "dependencies": dependencies,
            "cleanup": cleanup,
            "fingerprint": fingerprint,
            "source_lines": source[:match.start()].count("\n") + 1,
        })
    return tests


def redundancy_groups(tests: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[str, list[str]] = defaultdict(list)
    for test in tests:
        groups[test["fingerprint"]].append(test["title"])
    return [
        {"fingerprint": fingerprint, "tests": titles, "recommendation": "merge or keep only the stronger assertions"}
        for fingerprint, titles in groups.items()
        if len(titles) > 1
    ]


def build_report(source: str, source_name: str, deployment_areas: list[str]) -> dict[str, Any]:
    tests = extract_tests(source)
    covered = sorted({area for test in tests for area in test["areas"]})
    expected = deployment_areas or sorted(AREAS)
    missing = [area for area in expected if area not in covered]
    weak = [
        test["title"]
        for test in tests
        if len(test["assertions"]) == 0 or len(test["actions"]) == 0
    ]
    additions = [
        {
            "priority": "P0" if area in {"authentication", "permissions", "failure handling"} else "P1",
            "area": area,
            "title": f"AAP-UI integration: {area}",
            "purpose": f"Verify the {area} integration boundary end to end.",
            "preconditions": ["AAP-demo deployment is healthy", f"{area} capability is enabled or explicitly marked unavailable"],
            "actions": [f"Exercise the primary {area} user journey through the UI and supporting API."],
            "assertions": [f"The {area} operation succeeds", "The UI and API show the same final state", "Expected failure behavior is clear"],
            "cleanup": ["Remove only resources created by the test"],
            "dependencies": ["AAP-demo deployment", area],
            "risk_covered": f"The {area} integration can regress without detection.",
        }
        for area in missing
    ]
    return {
        "source": source_name,
        "test_count": len(tests),
        "tests": tests,
        "covered_areas": covered,
        "redundancy_groups": redundancy_groups(tests),
        "weak_or_low_value_tests": weak,
        "coverage_gaps": missing,
        "recommended_additions": additions,
        "summary": {
            "tests_to_keep": len(tests) - sum(len(group["tests"]) - 1 for group in redundancy_groups(tests)),
            "redundancy_group_count": len(redundancy_groups(tests)),
            "coverage_gap_count": len(missing),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-file", required=True)
    parser.add_argument("--source-name", default="AAP-UI Playwright integration tests")
    parser.add_argument("--deployment-areas", default="authentication,controller,execution,gateway,hub,eda,permissions,failure handling")
    args = parser.parse_args()
    source_path = Path(args.source_file)
    report = build_report(
        source_path.read_text(encoding="utf-8"),
        args.source_name,
        [item.strip() for item in args.deployment_areas.split(",") if item.strip()],
    )
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
