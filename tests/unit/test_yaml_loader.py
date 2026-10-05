"""PyYAML must stay in pure-Python mode (design §5.1).

The libyaml C extension is a speed optimization for large documents and nothing
else. A config file, an addon manifest, and a playbook manifest are a few
kilobytes each, so there is no scenario here where the C path's throughput is
observable — and requiring it means a `pip install` can fail with a compiler
stack trace on a fresh macOS machine. This test exists so nobody "optimizes" it
back in.
"""

from __future__ import annotations

import ast
import inspect
from typing import List

import pytest

from aap_demo.core import config as config_mod
from aap_demo.core import migration, output, schema

MODULES = [config_mod, schema, output, migration]


C_LOADERS = {"CSafeLoader", "CSafeDumper", "CLoader", "CDumper"}


@pytest.mark.parametrize("module", MODULES, ids=lambda m: m.__name__)
def test_no_c_extension_loader_is_referenced(module) -> None:
    # AST rather than a text scan: the modules mention these names in comments
    # explaining why they are banned, and that explanation should stay.
    tree = ast.parse(inspect.getsource(module))
    for node in ast.walk(tree):
        name = None
        if isinstance(node, ast.Name):
            name = node.id
        elif isinstance(node, ast.Attribute):
            name = node.attr
        elif isinstance(node, ast.alias):
            name = node.asname or node.name
        assert name not in C_LOADERS, f"{module.__name__} references {name}"


@pytest.mark.parametrize("module", MODULES, ids=lambda m: m.__name__)
def test_only_safe_yaml_entry_points_are_called(module) -> None:
    tree = ast.parse(inspect.getsource(module))
    calls: List[str] = []
    for node in ast.walk(tree):
        if (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and isinstance(node.func.value, ast.Name)
            and node.func.value.id == "yaml"
        ):
            calls.append(node.func.attr)
    assert all(call in {"safe_load", "safe_dump"} for call in calls), calls


def test_safe_dump_default_dumper_is_pure_python() -> None:
    import yaml

    assert yaml.SafeDumper.__module__.startswith("yaml.")
    assert "C" not in yaml.SafeDumper.__name__


def test_config_round_trips_through_the_pure_python_path(tmp_path) -> None:
    target = tmp_path / "config.yaml"
    config_mod.resolve(env={}).save(target)
    assert config_mod.load(target, env={}).get("crc.preset") == "microshift"
