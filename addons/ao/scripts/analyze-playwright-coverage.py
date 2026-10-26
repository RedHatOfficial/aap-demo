#!/usr/bin/env python3
"""Build a deterministic Playwright integration coverage report."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable

AREA_TERMS = {
    "authentication": ("login", "logout", "oauth", "oidc", "token", "password", "sso"),
    "controller": ("controller", "job template", "workflow job", "inventory", "organization", "credential", "project"),
    "execution": ("launch", "job status", "execution", "playbook", "execution environment", "run job"),
    "gateway": ("gateway", "/api/gateway", "route", "proxy"),
    "hub": ("hub", "automation hub", "collection", "container registry", "private automation hub"),
    "eda": ("event-driven", "eda", "rulebook", "activation", "event stream"),
    "permissions": ("permission", "role", "rbac", "access", "forbidden", "unauthorized"),
    "failure handling": ("error", "fail", "invalid", "timeout", "unavailable", "retry", "empty state"),
    "cleanup": ("delete", "remove", "cleanup", "teardown", "aftereach", "afterall"),
}
DEFAULT_AREAS = ["authentication", "controller", "execution", "gateway", "hub", "eda", "permissions", "failure handling", "cleanup"]


def normalize(value: str) -> str:
    value = value.lower()
    value = re.sub(r"\$\{[^}]+\}|['\"`][^'\"`]*['\"`]", "value", value)
    value = re.sub(r"\d+", "n", value)
    return re.sub(r"\s+", " ", value).strip()


def area_names(text: str) -> list[str]:
    lowered = text.lower()
    return [name for name, terms in AREA_TERMS.items() if any(term in lowered for term in terms)]


def matching_brace(source: str, opening: int) -> int:
    depth = 0
    quote = ""
    escaped = False
    line_comment = block_comment = False
    index = opening
    while index < len(source):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""
        if line_comment:
            if char == "\n": line_comment = False
        elif block_comment:
            if char == "*" and next_char == "/": block_comment = False; index += 1
        elif quote:
            if escaped: escaped = False
            elif char == "\\": escaped = True
            elif char == quote: quote = ""
        elif char in "'\"`": quote = char
        elif char == "/" and next_char == "/": line_comment = True; index += 1
        elif char == "/" and next_char == "*": block_comment = True; index += 1
        elif char == "{": depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0: return index + 1
        index += 1
    return len(source)


def extract_tests(source: str, file_path: str = "") -> list[dict[str, Any]]:
    starts = list(re.finditer(r"(?:test|it)\s*(?:\.\w+)?\s*\(\s*(['\"`])([^'\"`]+)\1", source))
    tests: list[dict[str, Any]] = []
    for match in starts:
        arrow = source.find("=>", match.end())
        brace = source.find("{", arrow if arrow >= 0 else match.end())
        if brace < 0: continue
        end = matching_brace(source, brace)
        body = source[brace:end]
        actions = sorted(set(re.findall(r"\b(?:page|request|context)\.[A-Za-z_][\w]*", body)))
        assertions = sorted(set(re.findall(r"\bexpect\([^\n]{0,220}", body)))
        locators = sorted(set(re.findall(r"\b(?:getByRole|getByText|getByLabel|getByTestId|locator)\([^\n]{0,180}", body)))
        resources = sorted(set(re.findall(r"\b(?:create|update|delete|remove|launch|cancel|sync|assign|unassign)\w*\b[^\n]{0,120}", body, re.I)))
        cleanup = sorted(set(re.findall(r"\b(?:delete|remove|cleanup|teardown|afterEach|afterAll)\b[^\n]{0,120}", body, re.I)))
        areas = area_names(match.group(2) + " " + body + " " + file_path)
        fingerprint_source = "|".join([",".join(actions), ",".join(assertions), ",".join(locators), ",".join(areas)])
        tests.append({
            "file": file_path, "title": match.group(2), "areas": areas, "actions": actions,
            "assertions": assertions, "locators": locators, "resources": resources, "cleanup": cleanup,
            "fingerprint": hashlib.sha1(normalize(fingerprint_source).encode()).hexdigest()[:12],
            "source_lines": source[:match.start()].count("\n") + 1,
        })
    return tests


def load_files(source_root: Path, include_path: str = "") -> list[tuple[str, str]]:
    files = []
    candidates = [source_root] if source_root.is_file() else sorted(source_root.rglob("*"))
    for path in candidates:
        relative = path.as_posix()
        if not path.is_file() or path.suffix not in {".ts", ".tsx", ".js", ".jsx"}: continue
        if include_path and include_path not in relative and not relative.endswith(include_path): continue
        if not re.search(r"(?:\.spec|\.test)\.(?:ts|tsx|js|jsx)$", relative): continue
        files.append((relative, path.read_text(encoding="utf-8")))
    return files


def redundancy_groups(tests: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for test in tests: groups[test["fingerprint"]].append(test)
    return [{
        "fingerprint": fingerprint,
        "tests": [{"file": t["file"], "title": t["title"]} for t in members],
        "reason": "same observable actions, assertions, locators, and mapped areas",
        "recommendation": "compare business purpose; merge only if the stronger test subsumes the others",
    } for fingerprint, members in groups.items() if len(members) > 1]


def additions_for_gaps(gaps: list[str]) -> list[dict[str, Any]]:
    journeys = {
        "authentication": ("sign in and session recovery", ["login succeeds", "expired/invalid session is handled", "logout removes access"]),
        "controller": ("create and use a controller resource", ["resource appears in the UI", "dependent workflow can select it"]),
        "execution": ("launch and observe automation", ["launch succeeds", "status transitions are visible", "final result matches the API"]),
        "gateway": ("exercise gateway routing and API access", ["route is reachable", "UI and API identify the same resource"]),
        "hub": ("browse and consume automation content", ["content is discoverable", "version and availability are accurate"]),
        "eda": ("exercise an EDA activation journey", ["activation state is accurate", "event processing result is visible"]),
        "permissions": ("verify role-based access boundaries", ["authorized action succeeds", "unauthorized action is rejected without side effects"]),
        "failure handling": ("exercise a meaningful failure path", ["error is actionable", "partial resources are not left behind"]),
        "cleanup": ("verify resource lifecycle cleanup", ["created resources are removed", "subsequent runs start clean"]),
    }
    result = []
    for area in gaps:
        journey, assertions = journeys.get(area, (f"exercise the {area} integration", [f"the {area} operation succeeds"]))
        result.append({"priority": "P0" if area in {"authentication", "permissions", "failure handling"} else "P1", "area": area,
                       "title": f"AAP-UI integration: {journey}", "purpose": f"Cover the missing {area} boundary with one meaningful end-to-end journey.",
                       "preconditions": ["AAP-demo is healthy", f"{area} capability is enabled or explicitly marked unavailable"],
                       "actions": [f"Exercise {journey} through the UI and supporting API where available."], "assertions": assertions,
                       "cleanup": ["Remove only resources created by the test and verify cleanup."], "dependencies": ["AAP-demo deployment", area],
                       "risk_covered": f"A regression in {area} could escape the current integration suite."})
    return result


def build_report_from_files(files: list[tuple[str, str]], source_name: str, deployment_areas: list[str]) -> dict[str, Any]:
    tests = [test for file_path, source in files for test in extract_tests(source, file_path)]
    expected = deployment_areas or DEFAULT_AREAS
    covered = sorted({area for test in tests for area in test["areas"]})
    gaps = [area for area in expected if area not in covered]
    groups = redundancy_groups(tests)
    weak = [{"file": t["file"], "title": t["title"], "reasons": [
        *(["no observable browser/API actions"] if not t["actions"] else []),
        *(["no expect assertion"] if not t["assertions"] else []),
        *(["no cleanup evidence for resource-changing test"] if t["resources"] and not t["cleanup"] else []),
    ]} for t in tests if not t["actions"] or not t["assertions"] or (t["resources"] and not t["cleanup"])]
    compact_tests = [{
        "file": t["file"], "title": t["title"], "areas": t["areas"],
        "actions": t["actions"], "assertion_count": len(t["assertions"]),
        "locator_count": len(t["locators"]), "resource_action_count": len(t["resources"]),
        "cleanup_evidence": bool(t["cleanup"]), "source_lines": t["source_lines"],
    } for t in tests]
    matrix = [{"area": area, "covered": area in covered, "test_count": sum(area in t["areas"] for t in tests),
               "sample_tests": [{"file": t["file"], "title": t["title"]} for t in tests if area in t["areas"]][:10]} for area in expected]
    redundant_count = sum(len(group["tests"]) - 1 for group in groups)
    return {"source": source_name, "file_count": len(files), "files": [path for path, _ in files], "test_count": len(tests),
            "tests": compact_tests, "covered_areas": covered, "coverage_matrix": matrix, "redundancy_groups": groups,
            "weak_or_low_value_tests": weak, "coverage_gaps": gaps, "recommended_additions": additions_for_gaps(gaps),
            "summary": {"tests_to_keep_or_review": len(tests) - redundant_count, "redundancy_group_count": len(groups),
                        "redundant_test_count_estimate": redundant_count, "coverage_gap_count": len(gaps), "weak_test_count": len(weak)},
            "limitations": ["Coverage uses source evidence and configured deployment areas; it does not claim an area is available unless supplied.",
                            "Redundancy groups are conservative review candidates, not automatic deletion recommendations."]}


def build_report(source: str, source_name: str, deployment_areas: list[str]) -> dict[str, Any]:
    return build_report_from_files([("source.ts", source)], source_name, deployment_areas)


def main() -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--source-file")
    group.add_argument("--source-root")
    parser.add_argument("--include-path", default="")
    parser.add_argument("--source-name", default="AAP-UI Playwright integration tests")
    parser.add_argument("--deployment-areas", default=",".join(DEFAULT_AREAS))
    args = parser.parse_args()
    files = load_files(Path(args.source_file or args.source_root), args.include_path)
    if not files: raise SystemExit(f"no Playwright spec files found matching {args.include_path!r}")
    print(json.dumps(build_report_from_files(files, args.source_name, [x.strip() for x in args.deployment_areas.split(",") if x.strip()]), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__": raise SystemExit(main())
