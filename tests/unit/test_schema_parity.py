"""The enforcement without which §9.3 is just a convention (design §14 R17).

Two directions matter. Forward: every schema property reaches a CLI flag, a
config path, and (where declared) an env var. Inverse — the important one: no
argparse argument exists that is not schema-derived and not on the CLI-only
allowlist, so adding a hand-written ``add_argument()`` breaks CI.
"""

from __future__ import annotations

import argparse
from typing import Dict, Iterator, List, Tuple

import jsonschema
import pytest

from aap_demo.cli._schema_args import CLI_ONLY_OPTIONS
from aap_demo.cli.main import build_parser
from aap_demo.core import config as config_mod
from aap_demo.core import schema

PROPERTIES = list(schema.iter_properties())
FLAGGED = [(s, k, p) for s, k, p in PROPERTIES if schema.cli_flag(p, k) is not None]


def _walk_parsers(parser: argparse.ArgumentParser) -> Iterator[Tuple[str, argparse.ArgumentParser]]:
    yield parser.prog, parser
    for action in parser._actions:
        if isinstance(action, argparse._SubParsersAction):
            for _name, sub in action.choices.items():
                yield from _walk_parsers(sub)


@pytest.fixture(scope="module")
def parser() -> argparse.ArgumentParser:
    return build_parser()


@pytest.fixture(scope="module")
def all_options(parser: argparse.ArgumentParser) -> Dict[str, List[argparse.Action]]:
    """Every optional action in every parser, keyed by ``dest``."""
    out: Dict[str, List[argparse.Action]] = {}
    for _, sub in _walk_parsers(parser):
        for action in sub._actions:
            if not action.option_strings:
                continue
            out.setdefault(action.dest, []).append(action)
    return out


# -- the schema documents themselves ---------------------------------------


def test_every_document_is_a_valid_json_schema() -> None:
    schema.check_documents()


def test_root_document_merges_every_section() -> None:
    root = schema.root()
    for name in schema.sections():
        assert name in root["properties"], f"{name} missing from the merged root document"
    jsonschema.Draft202012Validator.check_schema(root)


def test_defaults_validate_against_the_root_document() -> None:
    schema.validate(config_mod.resolve(env={}).as_dict())


# -- forward: schema -> CLI, config, env -----------------------------------


@pytest.mark.parametrize(
    ("section_name", "key", "prop"),
    [pytest.param(s, k, p, id=f"{s}.{k}") for s, k, p in FLAGGED],
)
def test_property_has_a_reachable_cli_flag(
    section_name: str, key: str, prop: dict, all_options: Dict[str, List[argparse.Action]]
) -> None:
    dest = f"{section_name}__{key}"
    assert dest in all_options, f"{section_name}.{key} has no argparse argument on any subparser"
    expected = set(schema.cli_flag(prop, key) or [])
    for action in all_options[dest]:
        assert expected.issubset(set(action.option_strings))


@pytest.mark.parametrize(
    ("section_name", "key", "prop"),
    [pytest.param(s, k, p, id=f"{s}.{k}") for s, k, p in FLAGGED],
)
def test_flag_appears_in_help(section_name: str, key: str, prop: dict) -> None:
    flag = (schema.cli_flag(prop, key) or [""])[-1]
    parser = build_parser()
    for _, sub in _walk_parsers(parser):
        if any(flag in a.option_strings for a in sub._actions):
            assert flag in sub.format_help()
            return
    pytest.fail(f"{flag} is not reachable from any --help")


@pytest.mark.parametrize(
    ("section_name", "key", "prop"),
    [pytest.param(s, k, p, id=f"{s}.{k}") for s, k, p in PROPERTIES],
)
def test_property_declares_a_unique_config_path(section_name: str, key: str, prop: dict) -> None:
    assert prop.get("x-config") == f"{section_name}.{key}", (
        f"{section_name}.{key} must declare x-config: {section_name}.{key}"
    )


def test_config_paths_are_unique() -> None:
    paths = [p.get("x-config") for _, _, p in PROPERTIES]
    assert len(paths) == len(set(paths))


@pytest.mark.parametrize(
    ("section_name", "key", "prop"),
    [pytest.param(s, k, p, id=f"{s}.{k}") for s, k, p in PROPERTIES],
)
def test_config_path_round_trips(section_name: str, key: str, prop: dict, tmp_path) -> None:
    config = config_mod.resolve(env={})
    dotted = prop["x-config"]
    assert config.get(dotted) == prop.get("default")

    target = tmp_path / "config.yaml"
    config.save(target)
    reloaded = config_mod.load(target, env={})
    assert reloaded.get(dotted) == prop.get("default")


@pytest.mark.parametrize(
    ("var", "target"),
    [pytest.param(v, t, id=v) for v, t in sorted(schema.env_map().items())],
)
def test_declared_env_var_is_honored_by_resolution(var: str, target) -> None:
    section_name, key = target
    prop = schema.section(section_name)["properties"][key]
    if prop["type"] == "integer":
        # Stay inside the declared bounds: this test is about resolution, not validation.
        sample = str(max(int(prop.get("minimum", 0)), int(prop.get("default", 0))))
    else:
        sample = {
            "string": (prop.get("enum") or [prop.get("const", "sample")])[-1],
            "number": "1.5",
            "boolean": "true",
            "array": "a,b",
        }[prop["type"]]

    config = config_mod.resolve(env={var: sample})
    expected = config_mod._coerce(sample, prop)
    assert config.get(prop["x-config"]) == expected


# -- inverse: no hand-written settings -------------------------------------


def test_no_hand_written_arguments_outside_the_allowlist(
    all_options: Dict[str, List[argparse.Action]],
) -> None:
    schema_dests = {f"{s}__{k}" for s, k, _ in FLAGGED}
    offenders = []
    for dest, actions in all_options.items():
        if dest in schema_dests:
            continue
        for action in actions:
            if set(action.option_strings) & CLI_ONLY_OPTIONS:
                continue
            offenders.append((dest, tuple(action.option_strings)))
    assert not offenders, (
        "these argparse options are neither schema-derived nor on the CLI-only "
        f"allowlist: {offenders}"
    )


def test_schema_only_properties_have_no_flag(all_options: Dict[str, List[argparse.Action]]) -> None:
    for section_name, key, prop in PROPERTIES:
        if schema.cli_flag(prop, key) is not None:
            continue
        assert f"{section_name}__{key}" not in all_options, (
            f"{section_name}.{key} carries x-cli: false but has an argparse argument"
        )
