"""config.yaml round-trip, header regeneration, and layered resolution (§5.1, §5.3)."""

from __future__ import annotations

from pathlib import Path

import pytest

from aap_demo.core import config as config_mod
from aap_demo.core.errors import ConfigError


def test_resolution_order_cli_beats_env_beats_file_beats_default() -> None:
    assert config_mod.resolve(env={}).get("crc.cpus") == 8
    assert config_mod.resolve(file_data={"crc": {"cpus": 10}}, env={}).get("crc.cpus") == 10
    assert (
        config_mod.resolve(file_data={"crc": {"cpus": 10}}, env={"CRC_CPUS": "12"}).get("crc.cpus")
        == 12
    )
    assert (
        config_mod.resolve(
            file_data={"crc": {"cpus": 10}},
            env={"CRC_CPUS": "12"},
            overrides={"crc": {"cpus": 16}},
        ).get("crc.cpus")
        == 16
    )


def test_empty_env_var_does_not_override() -> None:
    assert (
        config_mod.resolve(file_data={"crc": {"cpus": 10}}, env={"CRC_CPUS": ""}).get("crc.cpus")
        == 10
    )


def test_legacy_env_name_still_works() -> None:
    assert config_mod.resolve(env={"NAMESPACE": "other"}).get("core.namespace") == "other"
    assert config_mod.resolve(env={"AAP_DEMO_NAMESPACE": "other"}).get("core.namespace") == "other"


@pytest.mark.parametrize(
    ("raw", "expected"),
    [("true", True), ("1", True), ("yes", True), ("false", False), ("0", False)],
)
def test_boolean_env_coercion(raw: str, expected: bool) -> None:
    assert config_mod.resolve(env={"AAP_DEMO_TRUST_CA": raw}).get("trust.install_ca") is expected


def test_array_env_coercion() -> None:
    assert config_mod.resolve(env={"ADDONS": "a, b ,c"}).get("addons.enabled") == ["a", "b", "c"]


def test_out_of_range_value_reports_the_json_path() -> None:
    with pytest.raises(ConfigError) as excinfo:
        config_mod.resolve(env={"CRC_CPUS": "96"})
    assert "crc.cpus" in str(excinfo.value)
    assert "maximum" in str(excinfo.value)


def test_unknown_top_level_key_is_rejected() -> None:
    with pytest.raises(ConfigError):
        config_mod.resolve(file_data={"nonsense": {}}, env={})


def test_unknown_key_inside_a_section_is_rejected() -> None:
    with pytest.raises(ConfigError):
        config_mod.resolve(file_data={"crc": {"nonsense": 1}}, env={})


# -- persistence ------------------------------------------------------------


def test_save_regenerates_the_header_and_preserves_values(tmp_path: Path) -> None:
    target = tmp_path / "config.yaml"
    config = config_mod.resolve(env={})
    config.set("crc.cpus", 12)
    config.save(target)

    text = target.read_text()
    assert text.startswith("# aap-demo configuration.")
    assert "config edit" in text
    assert "NO credentials" in text

    reloaded = config_mod.load(target, env={})
    assert reloaded.get("crc.cpus") == 12


def test_save_uses_schema_key_order(tmp_path: Path) -> None:
    target = tmp_path / "config.yaml"
    config_mod.resolve(env={}).save(target)
    body = [line for line in target.read_text().splitlines() if line and not line.startswith("#")]
    sections = [
        line.rstrip(":") for line in body if not line.startswith(" ") and line.endswith(":")
    ]
    assert sections == ["core", "crc", "deploy", "trust", "addons", "playbooks", "gui", "secrets"]


def test_write_is_atomic_and_leaves_no_temp_file(tmp_path: Path) -> None:
    target = tmp_path / "config.yaml"
    config_mod.write(target, config_mod.resolve(env={}).as_dict())
    assert not list(tmp_path.glob("*.tmp"))


def test_set_validates_immediately() -> None:
    config = config_mod.resolve(env={})
    with pytest.raises(ConfigError):
        config.set("crc.cpus", 999)


def test_set_coerces_string_values_by_schema_type() -> None:
    config = config_mod.resolve(env={})
    config.set("crc.cpus", "12")
    assert config.get("crc.cpus") == 12
    config.set("trust.mkcert", "false")
    assert config.get("trust.mkcert") is False


def test_missing_file_resolves_to_defaults(tmp_path: Path) -> None:
    assert config_mod.load(tmp_path / "absent.yaml", env={}).get("crc.cpus") == 8


def test_non_mapping_file_is_a_config_error(tmp_path: Path) -> None:
    target = tmp_path / "config.yaml"
    target.write_text("- a\n- b\n")
    with pytest.raises(ConfigError):
        config_mod.read_yaml(target)
