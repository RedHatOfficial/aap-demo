"""JSON Schema documents — the single source of truth (design §9.3).

Neither an argparse argument nor a GUI form field may introduce a setting that
is not defined here. The documents are hand-written YAML shipped as package
data; ``core/schema.py`` loads, merges, and validates against them. There is
deliberately no schema-builder DSL, no code generation, and no registry class —
a dict, a merge, and a validator.
"""

from __future__ import annotations

import functools
from typing import Any, Dict, Iterator, List, Optional, Tuple

import jsonschema
import yaml

SCHEMA_PACKAGE = "aap_demo.data.schema"

#: Order sections appear in ``config.yaml`` and in generated help.
SECTION_ORDER = (
    "core",
    "crc",
    "deploy",
    "trust",
    "addons",
    "playbooks",
    "gui",
    "secrets",
)


def _read_schema_files() -> Dict[str, Dict[str, Any]]:
    try:  # Python 3.9 has importlib.resources.files
        from importlib.resources import files
    except ImportError:  # pragma: no cover - 3.8 and below are unsupported
        raise

    docs: Dict[str, Dict[str, Any]] = {}
    for entry in files(SCHEMA_PACKAGE).iterdir():
        if not entry.name.endswith(".yaml"):
            continue
        # Pure-Python SafeLoader only: never CSafeLoader, so installing the tool
        # never needs a compiler (§5.1).
        docs[entry.name[: -len(".yaml")]] = yaml.safe_load(entry.read_text(encoding="utf-8"))
    return docs


@functools.lru_cache(maxsize=1)
def _documents() -> Dict[str, Dict[str, Any]]:
    docs = _read_schema_files()
    unknown = set(docs) - set(SECTION_ORDER)
    if unknown:
        raise RuntimeError(f"schema documents not listed in SECTION_ORDER: {sorted(unknown)}")
    return docs


def sections() -> List[str]:
    docs = _documents()
    return [name for name in SECTION_ORDER if name in docs]


def section(name: str) -> Dict[str, Any]:
    docs = _documents()
    if name not in docs:
        raise KeyError(f"unknown schema section: {name!r}")
    return docs[name]


@functools.lru_cache(maxsize=1)
def root() -> Dict[str, Any]:
    """The merged document every consumer validates against."""
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "aap-demo/config",
        "title": "aap-demo configuration",
        "type": "object",
        "additionalProperties": False,
        "properties": {
            **{"schema_version": {"type": "integer", "const": 1, "default": 1}},
            **{name: section(name) for name in sections()},
        },
    }


def iter_properties() -> Iterator[Tuple[str, str, Dict[str, Any]]]:
    """Yield ``(section, key, property)`` for every property in every document."""
    for name in sections():
        for key, prop in section(name)["properties"].items():
            yield name, key, prop


def defaults() -> Dict[str, Any]:
    out: Dict[str, Any] = {"schema_version": 1}
    for name in sections():
        block: Dict[str, Any] = {}
        for key, prop in section(name)["properties"].items():
            if "default" in prop:
                block[key] = prop["default"]
        out[name] = block
    return out


def env_map() -> Dict[str, Tuple[str, str]]:
    """``ENV_VAR -> (section, key)``, including the legacy names (§3.2, §12.2).

    This is the same table that makes the env vars work, so the migration has no
    second mapping to drift against.
    """
    mapping: Dict[str, Tuple[str, str]] = {}
    for name, key, prop in iter_properties():
        for annotation in ("x-env", "x-env-legacy"):
            var = prop.get(annotation)
            if var:
                mapping[var] = (name, key)
    return mapping


def config_paths() -> Dict[str, Tuple[str, str]]:
    """``x-config`` dotted path -> ``(section, key)``."""
    mapping: Dict[str, Tuple[str, str]] = {}
    for name, key, prop in iter_properties():
        path = prop.get("x-config")
        if path:
            mapping[path] = (name, key)
    return mapping


def cli_flag(prop: Dict[str, Any], key: str) -> Optional[List[str]]:
    """Option strings for a property, or None when it carries ``x-cli: false``."""
    spec = prop.get("x-cli", {})
    if spec is False:
        return None
    if isinstance(spec, dict):
        if "flags" in spec:
            return list(spec["flags"])
        if "flag" in spec:
            return [spec["flag"]]
    return ["--" + key.replace("_", "-")]


def validate(instance: Dict[str, Any], section_name: Optional[str] = None) -> None:
    """Validate against the root document or one section.

    Errors are reported by ``json_path`` so a bad value reads the same whether it
    came from a flag, an env var, the config file, or the API (§9.3).
    """
    from aap_demo.core.errors import ConfigError

    doc = root() if section_name is None else section(section_name)
    validator = jsonschema.Draft202012Validator(doc)
    errors = sorted(validator.iter_errors(instance), key=lambda e: list(e.absolute_path))
    if not errors:
        return
    first = errors[0]
    path = first.json_path.lstrip("$.") or "<root>"
    raise ConfigError(f"{path}: {first.message}")


def check_documents() -> None:
    """Assert every shipped document is itself a valid JSON Schema."""
    for name in sections():
        jsonschema.Draft202012Validator.check_schema(section(name))
    jsonschema.Draft202012Validator.check_schema(root())
