"""Install-path regressions that do not need a cluster.

pipx owns the ``aap-demo`` console script. A bash v1 launcher at the same
name collides with it. Config, state, and cache stay on the XDG paths, including
after a v1 ``~/.aap-demo`` home is migrated.
"""

from __future__ import annotations

import os
from pathlib import Path

from aap_demo.core import bash_v1, migration, self_update
from aap_demo.core.paths import resolve_paths
from aap_demo.core.secrets import InMemorySecretStore

ROOT = Path(__file__).resolve().parents[2]


def test_pipx_installs_the_aap_demo_console_script() -> None:
    project = (ROOT / "pyproject.toml").read_text(encoding="utf-8")
    assert 'aap-demo = "aap_demo.cli.main:main"' in project
    assert self_update.PACKAGE == "aap-demo"
    assert "pipx install aap-demo" in (ROOT / "docs/guides/install.md").read_text(encoding="utf-8")


def test_bash_v1_launcher_collides_and_renames_to_aap_demo_v1(tmp_path: Path) -> None:
    script = tmp_path / "aap-demo.sh"
    script.write_text("#!/usr/bin/env bash\n# aap-demo v1\n", encoding="utf-8")
    bindir = tmp_path / ".local" / "bin"
    bindir.mkdir(parents=True)
    launcher = bindir / "aap-demo"
    launcher.symlink_to(script)
    python_entry = tmp_path / "pipx" / "aap-demo"
    python_entry.parent.mkdir()
    python_entry.write_text("#!/usr/bin/env python3\nimport aap_demo\n", encoding="utf-8")

    found = bash_v1.bash_launchers(
        {"PATH": os.pathsep.join((str(bindir), str(python_entry.parent)))}
    )

    assert found == [launcher]
    assert bash_v1.destination_of(launcher).name == "aap-demo-v1"
    renamed = bash_v1.rename_launcher(launcher)
    assert renamed.name == "aap-demo-v1"
    assert renamed.resolve() == script.resolve()
    assert not launcher.exists()


def test_xdg_paths_and_v1_home_migration(tmp_path: Path) -> None:
    home = tmp_path / "home"
    legacy = home / ".aap-demo"
    legacy.mkdir(parents=True)
    (legacy / "config").write_text("NAMESPACE=aap-operator\nCRC_CPUS=8\n", encoding="utf-8")
    (legacy / "kubeconfig.microshift").write_text("apiVersion: v1\n", encoding="utf-8")
    paths = resolve_paths({"HOME": str(home)})

    assert paths.config_dir == home / ".config" / "aap-demo"
    assert paths.state_dir == home / ".local" / "state" / "aap-demo"
    assert paths.cache_dir == home / ".cache" / "aap-demo"
    assert paths.legacy_dir == legacy

    migration.apply(paths, migration.plan(paths), secret_store=InMemorySecretStore())

    assert paths.config_file.is_file()
    assert paths.kubeconfig.read_text(encoding="utf-8") == "apiVersion: v1\n"
    assert not (legacy / "kubeconfig.microshift").exists()
