"""``python -m aap_demo`` — the same code path as the ``aap-demo`` console script."""

from __future__ import annotations

import sys

from aap_demo.cli.main import main

if __name__ == "__main__":
    sys.exit(main())
