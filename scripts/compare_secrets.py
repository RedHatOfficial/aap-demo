#!/usr/bin/env python3
"""Fail when a detect-secrets scan holds a finding that the baseline does not.

Findings are compared by file, type, and secret hash. Comparing totals would let
a new secret pass whenever an old one was removed in the same change.
"""

from __future__ import annotations

import json
import sys
from collections import Counter
from typing import Tuple

Finding = Tuple[str, str, str]


def findings(path: str) -> "Counter[Finding]":
    with open(path, encoding="utf-8") as handle:
        document = json.load(handle)
    return Counter(
        (filename, item["type"], item["hashed_secret"])
        for filename, items in document.get("results", {}).items()
        for item in items
    )


def new_findings(scan: str, baseline: str) -> "Counter[Finding]":
    return findings(scan) - findings(baseline)


def main() -> int:
    added = new_findings(sys.argv[1], sys.argv[2])
    if added:
        print(f"New secrets detected: {sum(added.values())}", file=sys.stderr)
        for filename, kind, _ in sorted(added):
            print(f"  {filename}: {kind}", file=sys.stderr)
        return 1
    print("No new secrets")
    return 0


if __name__ == "__main__":
    sys.exit(main())
