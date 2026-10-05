"""``--output rich|basic|json|yaml`` renderers over structured results.

``rich`` and ``basic`` are presentations of the human log. ``json`` and
``yaml`` are the machine formats. ``text`` is accepted as an alias of
``basic`` so older invocations keep working.
"""

from __future__ import annotations

import json
from typing import Any, Callable, Optional

import yaml

FORMATS = ("rich", "basic", "json", "yaml")
HUMAN = {"rich", "basic", "text"}


def normalize(output: str) -> str:
    """Map the retired ``text`` presentation onto ``basic``."""
    if output == "text":
        return "basic"
    return output


def is_structured(output: str) -> bool:
    return output in {"json", "yaml"}


def render(
    console: Any,
    data: Any,
    *,
    output: str = "basic",
    text: Optional[Callable[[], str]] = None,
) -> None:
    output = normalize(output)
    if output == "json":
        console.out(json.dumps(data, indent=2, sort_keys=False, default=str))
    elif output == "yaml":
        console.out(yaml.safe_dump(data, sort_keys=False, default_flow_style=False).rstrip())
    else:
        console.out(text() if text is not None else str(data))
