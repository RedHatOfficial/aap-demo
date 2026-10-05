"""Legacy ``~/.aap-demo`` -> YAML + XDG-style layout migration (design §12.2).

Parameterized over ``tests/fixtures/legacy_home/``, which covers exactly the
cases the design names: a full config, an empty config, a config with only
``ADDONS``, a config with ``registry``/``local-cache`` enabled, no config at
all, and a partially-migrated directory.
"""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from aap_demo.core import config as config_mod
from aap_demo.core import migration
from aap_demo.core.paths import Paths
from aap_demo.core.secrets import InMemorySecretStore

CASES = ("full", "empty_config", "addons_only", "retired_addons", "no_config", "partial")


@pytest.fixture
def legacy(request, tmp_path: Path, fixtures_dir: Path):
    """Copy one legacy_home case into a temp tree and return its Paths."""

    def _make(case: str) -> Paths:
        home = tmp_path / "home"
        shutil.copytree(fixtures_dir / "legacy_home" / case, home)
        return Paths(
            config_dir=tmp_path / "config",
            cache_dir=tmp_path / "cache",
            state_dir=tmp_path / "state",
            legacy_dir=home / ".aap-demo",
            collapsed=False,
        )

    return _make


# -- KEY=VALUE parsing ------------------------------------------------------


def test_parse_matches_bash_permissiveness() -> None:
    values = migration.parse_legacy_config(
        "\n".join(
            [
                "# a comment",
                "",
                "   ",
                'NAMESPACE="aap-operator"',
                "CRC_CPUS=8",
                "CRC_CPUS=10",  # last wins
                "QUOTED='single'",
                "NO_EQUALS_HERE",
                "EMPTY=",
            ]
        )
    )
    assert values == {
        "NAMESPACE": "aap-operator",
        "CRC_CPUS": "10",
        "QUOTED": "single",
        "EMPTY": "",
    }


def test_addons_are_alias_normalized_and_deduped() -> None:
    kept, retired = migration._split_addons("mcp-server, ao-eap, ao, registry, local-cache")
    assert kept == ["mcp-server", "ao"]
    assert retired == ["registry", "local-cache"]


# -- per-fixture behavior ---------------------------------------------------


@pytest.mark.parametrize("case", CASES)
def test_migration_produces_a_valid_config(case: str, legacy) -> None:
    paths = legacy(case)
    plan = migration.plan(paths)
    migration.apply(paths, plan, secret_store=InMemorySecretStore())

    assert paths.config_file.is_file()
    reloaded = config_mod.load(paths.config_file, env={})
    reloaded.validate()  # raises on anything the schema rejects


def test_full_config_maps_every_known_key(legacy) -> None:
    paths = legacy("full")
    plan = migration.plan(paths)
    migration.apply(paths, plan, secret_store=InMemorySecretStore())
    config = config_mod.load(paths.config_file, env={})

    assert config.get("crc.preset") == "microshift"
    assert config.get("crc.cpus") == 10  # last-wins duplicate
    assert config.get("crc.memory_mb") == 32768
    assert config.get("core.namespace") == "aap-operator"
    assert config.get("core.infra") == "crc"
    assert config.get("addons.enabled") == ["mcp-server", "ao", "product-demos"]


def test_unmapped_legacy_key_is_reported_not_silently_dropped(legacy) -> None:
    plan = migration.plan(legacy("full"))
    assert any("UNKNOWN_LEGACY_KEY" in w for w in plan.warnings)


def test_empty_config_falls_back_to_schema_defaults(legacy) -> None:
    paths = legacy("empty_config")
    plan = migration.plan(paths)
    migration.apply(paths, plan, secret_store=InMemorySecretStore())
    config = config_mod.load(paths.config_file, env={})
    assert config.get("crc.cpus") == 8
    assert config.get("addons.enabled") == []


def test_addons_only_config(legacy) -> None:
    paths = legacy("addons_only")
    plan = migration.plan(paths)
    migration.apply(paths, plan, secret_store=InMemorySecretStore())
    config = config_mod.load(paths.config_file, env={})
    assert config.get("addons.enabled") == ["mcp-server", "portal"]
    assert config.get("crc.preset") == "microshift"


def test_retired_addons_are_dropped_loudly(legacy) -> None:
    paths = legacy("retired_addons")
    plan = migration.plan(paths)
    migration.apply(paths, plan, secret_store=InMemorySecretStore())
    config = config_mod.load(paths.config_file, env={})

    assert config.get("addons.enabled") == ["mcp-server"]
    warnings = " ".join(plan.warnings)
    assert "registry" in warnings and "registry-mirror" in warnings
    assert "local-cache" in warnings and "image-store" in warnings


def test_no_config_writes_a_fresh_file(legacy) -> None:
    paths = legacy("no_config")
    plan = migration.plan(paths)
    assert plan.reason == "fresh"
    migration.apply(paths, plan, secret_store=InMemorySecretStore())
    assert config_mod.load(paths.config_file, env={}).get("crc.cpus") == 8


# -- state moves ------------------------------------------------------------


def test_state_files_are_moved_not_copied(legacy) -> None:
    paths = legacy("full")
    migration.apply(paths, migration.plan(paths), secret_store=InMemorySecretStore())

    assert paths.kubeconfig.read_text() == "kubeconfig-contents\n"
    assert not (paths.legacy_dir / "kubeconfig.microshift").exists()
    assert paths.ingress_ca.is_file()
    assert not (paths.legacy_dir / "crc-ingress-ca.crt").exists()


def test_image_cache_is_left_in_place_and_reported(legacy) -> None:
    paths = legacy("full")
    plan = migration.plan(paths)
    log = migration.apply(paths, plan, secret_store=InMemorySecretStore())

    cache = paths.legacy_dir / "local-cache"
    assert cache.is_dir()
    assert any(str(cache) in line for line in log)


def test_hand_placed_files_are_never_touched(legacy) -> None:
    paths = legacy("full")
    migration.apply(paths, migration.plan(paths), secret_store=InMemorySecretStore())

    assert (paths.legacy_dir / "pull-secret.txt").is_file()
    assert (paths.legacy_dir / "atf-vault-password").is_file()
    assert paths.legacy_dir.is_dir()
    assert paths.migrated_marker.is_file()


def test_legacy_pull_secret_is_left_in_place_and_not_a_configured_path(legacy) -> None:
    paths = legacy("full")
    migration.apply(paths, migration.plan(paths), secret_store=InMemorySecretStore())
    assert (paths.legacy_dir / "pull-secret.txt").is_file()


# -- credentials ------------------------------------------------------------


def test_credentials_are_imported_and_the_source_deleted(legacy) -> None:
    paths = legacy("full")
    store = InMemorySecretStore()
    migration.apply(paths, migration.plan(paths), secret_store=store)

    assert store.get("galaxy-token") == "glxy-token-value"
    assert store.get("pah-token") == "pah-token-value"
    assert not (paths.legacy_dir / "galaxy-token").exists()
    assert not (paths.legacy_dir / "pah-token").exists()


def test_leftover_atf_vault_password_is_left_on_disk_and_not_imported(legacy) -> None:
    paths = legacy("full")
    store = InMemorySecretStore()
    migration.apply(paths, migration.plan(paths), secret_store=store)

    assert store.get("atf-vault-password") is None
    assert (paths.legacy_dir / "atf-vault-password").is_file()


def test_without_a_keyring_the_rest_of_the_migration_still_runs(legacy) -> None:
    """A migration must never be the thing that hard-fails on a headless box."""
    paths = legacy("full")
    plan = migration.plan(paths, secrets_available=False)
    migration.apply(paths, plan, secret_store=None)

    assert paths.config_file.is_file()
    assert paths.kubeconfig.is_file()
    # The plaintext is left alone and named explicitly rather than silently lost.
    assert (paths.legacy_dir / "galaxy-token").is_file()
    warning = " ".join(plan.warnings)
    assert "galaxy-token" in warning and "pah-token" in warning
    assert not any(a.kind == "import-secret" for a in plan.actions)


# -- guarantees -------------------------------------------------------------


@pytest.mark.parametrize("case", CASES)
def test_migration_is_idempotent(case: str, legacy) -> None:
    paths = legacy(case)
    migration.apply(paths, migration.plan(paths), secret_store=InMemorySecretStore())
    first = paths.config_file.read_text()

    second_plan = migration.plan(paths)
    assert second_plan.reason == "already-migrated"
    assert not second_plan.needed
    migration.apply(paths, second_plan, secret_store=InMemorySecretStore())
    assert paths.config_file.read_text() == first


def test_partially_migrated_directory_resumes(legacy) -> None:
    """The kubeconfig already moved; the second pass must finish the rest."""
    paths = legacy("partial")
    paths.state_dir.mkdir(parents=True)
    (paths.legacy_dir / "kubeconfig.microshift").rename(paths.kubeconfig)

    plan = migration.plan(paths)
    migration.apply(paths, plan, secret_store=InMemorySecretStore())

    assert paths.config_file.is_file()
    assert paths.kubeconfig.read_text() == "kubeconfig-contents\n"
    assert not any(a.kind == "move" for a in plan.actions)


def test_existing_destination_is_never_overwritten(legacy) -> None:
    paths = legacy("partial")
    paths.state_dir.mkdir(parents=True)
    paths.kubeconfig.write_text("newer-kubeconfig\n")

    migration.apply(paths, migration.plan(paths), secret_store=InMemorySecretStore())
    assert paths.kubeconfig.read_text() == "newer-kubeconfig\n"


def test_dry_run_touches_nothing(legacy) -> None:
    paths = legacy("full")
    plan = migration.plan(paths)
    log = migration.apply(paths, plan, secret_store=InMemorySecretStore(), dry_run=True)

    assert log and all(line.startswith("[dry-run]") for line in log)
    assert not paths.config_file.exists()
    assert (paths.legacy_dir / "kubeconfig.microshift").is_file()
    assert (paths.legacy_dir / "galaxy-token").is_file()
    assert not paths.migrated_marker.exists()


def test_config_write_is_atomic(legacy) -> None:
    paths = legacy("full")
    migration.apply(paths, migration.plan(paths), secret_store=InMemorySecretStore())
    assert not list(paths.config_dir.glob("*.tmp"))


def test_written_config_carries_the_regenerated_header(legacy) -> None:
    paths = legacy("full")
    migration.apply(paths, migration.plan(paths), secret_store=InMemorySecretStore())
    text = paths.config_file.read_text()
    assert text.startswith("# aap-demo configuration.")
    assert "NO credentials" in text


def test_skip_migration_env_var_is_honored(legacy) -> None:
    paths = legacy("full")
    plan, log = migration.migrate_if_needed(
        paths, env={"AAP_DEMO_SKIP_MIGRATION": "1"}, secret_store=InMemorySecretStore()
    )
    assert not plan.needed and not log
    assert not paths.config_file.exists()


def test_collapsed_layout_moves_no_state(tmp_path: Path, fixtures_dir: Path) -> None:
    """AAP_DEMO_DIR keeps everything under one root, so nothing relocates (§12.2)."""
    root = tmp_path / "collapsed"
    shutil.copytree(fixtures_dir / "legacy_home" / "full" / ".aap-demo", root)
    paths = Paths(config_dir=root, cache_dir=root, state_dir=root, legacy_dir=root, collapsed=True)

    plan = migration.plan(paths)
    migration.apply(paths, plan, secret_store=InMemorySecretStore())

    assert not any(a.kind == "move" for a in plan.actions)
    assert (root / "kubeconfig.microshift").is_file()
    assert (root / "config.yaml").is_file()
