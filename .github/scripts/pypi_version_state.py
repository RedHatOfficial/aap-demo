#!/usr/bin/env python3
"""Decide whether the publish workflow should upload this version.

Writes ``published=true`` or ``published=false`` to ``GITHUB_OUTPUT``. Any answer
from PyPI other than 200 or 404 fails the job, so an outage is not read as
"not published".
"""

from __future__ import annotations

import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

PACKAGE_FILE = Path("src/aap_demo/__init__.py")
ALLOWED_VERSION = re.compile(r"2\.0\.0\.dev\d+")
VERSION_LINE = re.compile(r'^__version__ = "([^"]+)"$', re.MULTILINE)


def read_version(text: str) -> str:
    match = VERSION_LINE.search(text)
    if match is None:
        raise ValueError("__version__ was not found")
    return match.group(1)


def is_allowed(version: str) -> bool:
    return ALLOWED_VERSION.fullmatch(version) is not None


def is_published(version: str, *, opener=urllib.request.urlopen) -> bool:
    url = f"https://pypi.org/pypi/aap-demo/{version}/json"
    try:
        with opener(url, timeout=30):
            return True
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise


def main() -> int:
    version = read_version(PACKAGE_FILE.read_text(encoding="utf-8"))
    if not is_allowed(version):
        print(f"Refusing to publish {version}: expected 2.0.0.devN", file=sys.stderr)
        return 1
    published = is_published(version)
    print(f"{version} on PyPI: {published}")
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"published={str(published).lower()}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
