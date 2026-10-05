"""Path classification, not literal strings (design §5.2, §6.1).

Runs on the macOS, Linux, and Windows CI runners. It asserts the *classification*
— which class a file belongs to and which accessor returns it — as well as the
literal XDG roots, since §5.2 now mandates the same strict XDG-style layout
under ``$HOME`` on every OS (a deliberate deviation from platformdirs' native
per-OS conventions — see the module docstring in ``core/paths.py``), so unlike
native per-OS directories, the literal roots are *not* expected to differ
between the CI runners.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from aap_demo.core.paths import Paths, display_path, resolve_paths


def test_display_path_hides_the_home_directory(tmp_path: Path) -> None:
    secret = tmp_path / "pull-secret.txt"
    secret.write_text("x")
    assert display_path(secret, tmp_path) == "~/pull-secret.txt"
    assert display_path(Path("/etc/hosts"), tmp_path) == "/etc/hosts"


def test_native_roots_are_absolute() -> None:
    paths = resolve_paths(env={"HOME": str(Path.home())})
    for root in (paths.config_dir, paths.cache_dir, paths.state_dir):
        assert root.is_absolute()
    assert "aap-demo" in str(paths.config_dir)


def test_roots_are_strict_xdg_under_home(tmp_path: Path) -> None:
    """§5.2: config/cache/state land under ``~/.config``, ``~/.cache``,
    ``~/.local/state`` on every OS, not a platform-native directory."""
    paths = resolve_paths(env={"HOME": str(tmp_path)})
    assert paths.config_dir == tmp_path / ".config" / "aap-demo"
    assert paths.cache_dir == tmp_path / ".cache" / "aap-demo"
    assert paths.state_dir == tmp_path / ".local" / "state" / "aap-demo"


def test_xdg_env_vars_override_the_defaults(tmp_path: Path) -> None:
    paths = resolve_paths(
        env={
            "HOME": str(tmp_path),
            "XDG_CONFIG_HOME": str(tmp_path / "custom-config"),
            "XDG_CACHE_HOME": str(tmp_path / "custom-cache"),
            "XDG_STATE_HOME": str(tmp_path / "custom-state"),
        }
    )
    assert paths.config_dir == tmp_path / "custom-config" / "aap-demo"
    assert paths.cache_dir == tmp_path / "custom-cache" / "aap-demo"
    assert paths.state_dir == tmp_path / "custom-state" / "aap-demo"


def test_blank_xdg_env_var_falls_back_to_the_default() -> None:
    """An XDG var set to empty/whitespace is treated as unset, per spec."""
    paths = resolve_paths(env={"HOME": "/home/demo", "XDG_CONFIG_HOME": "   "})
    assert paths.config_dir == Path("/home/demo/.config/aap-demo")


def test_aap_demo_dir_collapses_every_root(tmp_path: Path) -> None:
    paths = resolve_paths(env={"AAP_DEMO_DIR": str(tmp_path), "HOME": str(tmp_path)})
    assert paths.collapsed
    assert paths.config_dir == paths.cache_dir == paths.state_dir == tmp_path
    assert paths.config_file == tmp_path / "config.yaml"


def test_legacy_dir_is_derived_from_home(tmp_path: Path) -> None:
    paths = resolve_paths(env={"HOME": str(tmp_path)})
    assert paths.legacy_dir == tmp_path / ".aap-demo"


@pytest.mark.parametrize(
    ("accessor", "expected_class"),
    [
        ("config_file", "config"),
        ("kubeconfig", "state"),
        ("pull_secret", "state"),
        ("ingress_ca", "state"),
        ("ca_bundle", "state"),
        ("playbooks_repo", "cache"),
        ("last_update_check", "cache"),
    ],
)
def test_accessor_lands_in_its_class_root(
    tmp_paths: Paths, accessor: str, expected_class: str
) -> None:
    root = {
        "config": tmp_paths.config_dir,
        "state": tmp_paths.state_dir,
        "cache": tmp_paths.cache_dir,
    }[expected_class]
    assert root in getattr(tmp_paths, accessor).parents


def test_addon_state_and_cache_are_split(tmp_paths: Paths) -> None:
    assert tmp_paths.state_dir in tmp_paths.addon_dir("portal").parents
    assert tmp_paths.cache_dir in tmp_paths.addon_cache("portal").parents


def test_image_store_keeps_its_preset_segment(tmp_paths: Paths) -> None:
    assert tmp_paths.image_store("microshift").name == "microshift"
    assert tmp_paths.cache_dir in tmp_paths.image_store("microshift").parents


def test_paths_are_built_with_pathlib_not_string_concatenation() -> None:
    import ast
    import inspect

    from aap_demo.core import paths as paths_mod

    tree = ast.parse(inspect.getsource(paths_mod))
    for node in ast.walk(tree):
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            assert not (
                isinstance(node.right, ast.Constant) and str(node.right.value).startswith("/")
            ), "build paths with pathlib, never string concatenation"


# -- pull secret discovery --------------------------------------------------


def test_pull_secret_property_lives_under_state(tmp_paths: Paths) -> None:
    assert tmp_paths.pull_secret.parent == tmp_paths.state_dir


def test_ensure_dirs_creates_every_root(tmp_paths: Paths) -> None:
    tmp_paths.ensure_dirs()
    for root in (tmp_paths.config_dir, tmp_paths.cache_dir, tmp_paths.state_dir):
        assert root.is_dir()
