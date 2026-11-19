#!/usr/bin/env python3
"""Download the files PyPI serves for one aap-demo version, for the GitHub release.

The release attaches what PyPI has, not a rebuild, so the two cannot differ.
Each file is checked against the sha256 PyPI lists for it. A version with no
wheel or no sdist fails, and so does any download that does not match.

PyPI's JSON API can answer 404, or list only some files, for a minute or so
after an upload. The lookup waits for both files before it gives up.

Usage: pypi_release_files.py <version> <dest-dir>
"""

from __future__ import annotations

import hashlib
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict, List

PACKAGE = "aap-demo"
Opener = Callable[..., Any]
NEEDED = {"bdist_wheel", "sdist"}
ATTEMPTS = 12
WAIT_SECONDS = 10


def release_files(
    version: str,
    *,
    opener: Opener = urllib.request.urlopen,
    sleep: Callable[[float], None] = time.sleep,
) -> List[Dict[str, Any]]:
    url = f"https://pypi.org/pypi/{PACKAGE}/{version}/json"
    found: List[str] = []
    for attempt in range(1, ATTEMPTS + 1):
        try:
            with opener(url, timeout=30) as response:
                files = json.load(response).get("urls") or []
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                raise
            found = ["not found (404)"]
        else:
            kinds = {entry.get("packagetype") for entry in files}
            if NEEDED <= kinds:
                return files
            found = sorted(str(kind) for kind in kinds)
        if attempt < ATTEMPTS:
            print(f"{PACKAGE} {version} on PyPI: {found}, waiting", file=sys.stderr)
            sleep(WAIT_SECONDS)
    raise SystemExit(f"{PACKAGE} {version} on PyPI needs a wheel and an sdist, found {found}")


def download(entry: Dict[str, Any], dest: Path, *, opener: Opener = urllib.request.urlopen) -> Path:
    name = Path(entry["filename"]).name
    with opener(entry["url"], timeout=60) as response:
        data = response.read()
    expected = entry["digests"]["sha256"]
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        raise SystemExit(f"{name}: sha256 {actual} does not match PyPI's {expected}")
    path = dest / name
    path.write_bytes(data)
    return path


def main(argv: List[str]) -> int:
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    version, dest = argv[1], Path(argv[2])
    dest.mkdir(parents=True, exist_ok=True)
    for entry in release_files(version):
        print(f"verified {download(entry, dest).name}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
