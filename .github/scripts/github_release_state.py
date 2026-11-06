#!/usr/bin/env python3
"""Decide whether the release job should create the GitHub release for a version.

Writes ``exists=true`` or ``exists=false`` to ``GITHUB_OUTPUT``.

- A published release: ``exists=true``, nothing to do.
- No release (``gh`` says "release not found"): ``exists=false``.
- A draft left by this workflow: ``gh release create`` with assets makes a draft,
  uploads, then publishes, so an interrupted run leaves one behind. That draft
  is deleted and ``exists=false``, so the job recreates the release whole.
- A draft anyone else made: fail and say so. It is never deleted here.
- Any other ``gh`` error (API outage, auth): fail, never read as "missing".

Usage: github_release_state.py <version>
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Callable, List

#: The login GitHub gives releases created with the workflow's GITHUB_TOKEN.
WORKFLOW_AUTHOR = "github-actions[bot]"
Runner = Callable[[List[str]], "subprocess.CompletedProcess[str]"]


def _run(argv: List[str]) -> "subprocess.CompletedProcess[str]":
    return subprocess.run(argv, capture_output=True, text=True, check=False)


def release_exists(version: str, *, run: Runner = _run) -> bool:
    tag = f"v{version}"
    view = run(["gh", "release", "view", tag, "--json", "isDraft,author"])
    if view.returncode != 0:
        output = f"{view.stderr}\n{view.stdout}"
        if "release not found" in output:
            print(f"{tag} has no release")
            return False
        raise SystemExit(f"gh release view {tag} failed:\n{output.strip()}")

    release = json.loads(view.stdout)
    if not release.get("isDraft"):
        print(f"{tag} already has a release; nothing to do")
        return True

    author = (release.get("author") or {}).get("login") or "unknown"
    if author != WORKFLOW_AUTHOR:
        raise SystemExit(
            f"{tag} has a draft release made by {author}. "
            "Publish or delete it, then run this workflow again."
        )
    print(f"{tag} has an incomplete draft from an earlier run; deleting it to recreate the release")
    deleted = run(["gh", "release", "delete", tag, "--yes"])
    if deleted.returncode != 0:
        raise SystemExit(f"gh release delete {tag} failed:\n{deleted.stderr.strip()}")
    return False


def main(argv: List[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    exists = release_exists(argv[1])
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"exists={str(exists).lower()}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
