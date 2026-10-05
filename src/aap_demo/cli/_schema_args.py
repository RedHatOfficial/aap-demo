"""Generate argparse arguments from a JSON Schema document (design §9.3).

Three deliberate omissions, each with a reason:

* ``minimum``/``maximum`` are not turned into argparse type-checkers. The merged
  result is validated by ``jsonschema`` immediately afterwards, and a second
  range check in a second place is exactly the drift this mechanism exists to
  prevent — argparse handles *parsing*, jsonschema handles *validity*.
* ``required`` is not enforced here: a value may arrive from config or an env
  var, so requiredness is a property of the resolved document.
* Nested objects are not flattened into dotted flags. A nested section gets its
  own document and its own ``add_schema_arguments`` call against the same
  parser, which is how ``crc.*`` and ``deploy.*`` both land on ``aap-demo create``.
"""

from __future__ import annotations

import argparse
from typing import Any, Dict, Mapping, Optional

from aap_demo.core import schema

_TYPES = {"string": str, "integer": int, "number": float}

#: Options that may be hand-written because they are verbs or output modifiers,
#: not settings — they have no config or GUI analogue. ``test_schema_parity``
#: fails on any optional argument outside this list that is not schema-derived.
#: The design's §3.1 allowlist is the first group; the rest are per-command
#: modifiers of the same kind (a flag that changes what a command *does*, not a
#: value it persists).
CLI_ONLY_OPTIONS = frozenset(
    {
        # §3.1's explicit allowlist
        "--output",
        "--quiet",
        "-q",
        "--yes",
        "-y",
        "--config",
        "--verbose",
        "-v",
        "-h",
        "--help",
        # global, CLI-shaped: they select a target or an escape hatch, not a setting
        "--kubeconfig",
        "--context",
        "--force",
        "--set",
        "--version",
        "-V",
        # per-command verb modifiers
        "--reset",
        "--ai",
        "--all",
        "--dry-run",
        "--check",
        "--purge-creds",
        "--refresh-catalog",
        "--extra-vars",
        "-e",
        "--stdin",
    }
)


def _dest_for(section_name: str, key: str) -> str:
    return f"{section_name}__{key}"


def add_schema_arguments(
    parser: argparse.ArgumentParser,
    section_name: str,
    *,
    resolved: Optional[Mapping[str, Any]] = None,
    doc: Optional[Dict[str, Any]] = None,
    suppress: bool = False,
) -> None:
    """Add one argparse argument per property in a schema section.

    ``resolved`` is the post-config-resolution value map, so ``--help`` shows the
    *effective* default rather than the schema default. ``suppress`` builds the
    same parser with ``SUPPRESS`` defaults, which is how ``cli/main.py`` learns
    which values the user actually typed and which merely defaulted.
    """
    document = doc if doc is not None else schema.section(section_name)
    values = resolved or {}

    properties = document.get("properties", {})
    for key, prop in sorted(properties.items(), key=lambda kv: kv[1].get("x-order", 1000)):
        flags = schema.cli_flag(prop, key)
        if flags is None:
            continue

        default = values.get(key, prop.get("default"))
        kwargs: Dict[str, Any] = {
            "dest": _dest_for(section_name, key),
            "help": prop.get("description"),
            "default": argparse.SUPPRESS if suppress else default,
        }

        prop_type = prop.get("type")
        if prop_type == "boolean":
            kwargs["action"] = "store_true" if not default else "store_false"
        elif prop_type in _TYPES:
            kwargs["type"] = _TYPES[prop_type]
            if "enum" in prop:
                # No metavar for an enum: argparse then renders the choices
                # themselves in --help, which is the useful thing to show. A
                # metavar would replace them with the widget name.
                kwargs["choices"] = prop["enum"]
            else:
                kwargs["metavar"] = prop.get("x-gui", {}).get("widget", key).upper()
        else:
            raise ValueError(
                f"{section_name}.{key}: type {prop_type!r} has no argparse mapping; "
                "mark it 'x-cli: false' or give it a scalar type"
            )

        parser.add_argument(*flags, **kwargs)


def collect_overrides(namespace: argparse.Namespace) -> Dict[str, Dict[str, Any]]:
    """Pull schema-derived values back out of a parsed namespace.

    Only values the user actually supplied should override config, so callers
    pass the *supplied* namespace produced by a second parse with suppressed
    defaults; see ``cli/main.py``.
    """
    overrides: Dict[str, Dict[str, Any]] = {}
    for dest, value in vars(namespace).items():
        if "__" not in dest:
            continue
        section_name, _, key = dest.partition("__")
        if section_name not in schema.sections():
            continue
        overrides.setdefault(section_name, {})[key] = value
    return overrides
