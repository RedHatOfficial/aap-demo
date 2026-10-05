"""XDG-style filesystem layout (design §5.2).

Four classes rather than three: *config* is what a human writes, *secret* is a
credential and does not live on the filesystem at all (§5.5), *state* is
machine-generated non-secret data whose loss costs the user something, and
*cache* is anything reconstructible.

``AAP_DEMO_DIR`` collapses every root back under one directory. That is not a
legacy wart: it is the documented escape hatch for CI and for the migration
overlap (§12.2), where both the bash and Python tools must see one layout.

DELIBERATE DEVIATION from §5.2 as originally written: the design doc calls for
platformdirs' *native per-OS* directories (macOS ``~/Library/Application
Support``, Windows ``%APPDATA%``). The maintainer overrode that for the CLI/
core: **every OS uses strict XDG-style paths under ``$HOME`` right now**
(``~/.config``, ``~/.cache``, ``~/.local/state``), honoring
``$XDG_CONFIG_HOME``/``$XDG_CACHE_HOME``/``$XDG_STATE_HOME`` when set. This is
intentional, not a bug — do not "fix" it back to platform-native conventions.
Native-per-OS is expected to be revisited specifically when a web GUI/desktop
app is built (§9), not before. Because that revisit is coming, this resolves
the XDG env vars by hand against the ``env``/``home`` this function already
takes, rather than reaching for platformdirs' OS-detecting entry point (or
even its ``platformdirs.unix.Unix`` class, which reads ``os.environ``
directly and can't be pointed at an injected environment) — keeping the
override obvious and the whole thing table-driven for whenever it changes
again.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Mapping, Optional, Tuple

APP_NAME = "aap-demo"
LEGACY_DIR_NAME = ".aap-demo"

#: (env var, default segments under $HOME) per XDG Base Directory root we use.
#: No XDG_DATA_HOME entry: this app has no filesystem "data" class (§5.2) —
#: config/cache/state plus the keyring-backed secret class cover everything.
_XDG_ROOTS: Dict[str, Tuple[str, Tuple[str, ...]]] = {
    "config": ("XDG_CONFIG_HOME", (".config",)),
    "cache": ("XDG_CACHE_HOME", (".cache",)),
    "state": ("XDG_STATE_HOME", (".local", "state")),
}


@dataclass(frozen=True)
class Paths:
    config_dir: Path
    cache_dir: Path
    state_dir: Path
    legacy_dir: Path
    collapsed: bool
    """True when AAP_DEMO_DIR forced every root under a single directory."""

    # -- config -------------------------------------------------------------

    @property
    def config_file(self) -> Path:
        return self.config_dir / "config.yaml"

    # -- state --------------------------------------------------------------

    @property
    def kubeconfig(self) -> Path:
        return self.state_dir / "kubeconfig.microshift"

    @property
    def pull_secret(self) -> Path:
        return self.state_dir / "pull-secret.json"

    @property
    def certs_dir(self) -> Path:
        return self.state_dir / "certs"

    @property
    def ingress_ca(self) -> Path:
        return self.certs_dir / "crc-ingress-ca.crt"

    @property
    def ca_bundle(self) -> Path:
        return self.certs_dir / "ca-bundle.crt"

    def addon_dir(self, name: str) -> Path:
        return self.state_dir / "addons" / name

    # -- cache --------------------------------------------------------------

    def addon_cache(self, name: str) -> Path:
        return self.cache_dir / "addons" / name

    def image_store(self, preset: str) -> Path:
        return self.cache_dir / "image-store" / preset

    @property
    def playbooks_repo(self) -> Path:
        return self.cache_dir / "playbooks-repo"

    @property
    def last_update_check(self) -> Path:
        return self.cache_dir / "last_update_check"

    # -- legacy -------------------------------------------------------------

    @property
    def legacy_config_file(self) -> Path:
        return self.legacy_dir / "config"

    @property
    def migrated_marker(self) -> Path:
        return self.legacy_dir / "MIGRATED.txt"

    def ensure_dirs(self) -> None:
        for path in (self.config_dir, self.cache_dir, self.state_dir):
            path.mkdir(parents=True, exist_ok=True)


def _xdg_root(
    environ: Mapping[str, str],
    resolved_home: Path,
    env_var: str,
    default_segments: Tuple[str, ...],
) -> Path:
    """One XDG base dir: ``$<env_var>`` if set and non-blank, else ``$HOME/<default_segments>``."""
    override = environ.get(env_var, "")
    if override.strip():
        base = Path(override).expanduser()
    else:
        base = resolved_home.joinpath(*default_segments)
    return base / APP_NAME


def display_path(path: Path, home: Path) -> str:
    """``~/...`` when ``path`` is inside ``home``.

    User-facing lines use this so a home-directory path does not include the
    account name.
    """
    try:
        return "~/" + path.resolve().relative_to(home.resolve()).as_posix()
    except ValueError:
        return str(path)


def resolve_paths(
    env: Optional[Mapping[str, str]] = None,
    *,
    home: Optional[Path] = None,
) -> Paths:
    environ = os.environ if env is None else env
    resolved_home = home or Path(environ.get("HOME") or Path.home())
    legacy_dir = resolved_home / LEGACY_DIR_NAME

    override = environ.get("AAP_DEMO_DIR")
    if override:
        root = Path(override).expanduser()
        return Paths(
            config_dir=root,
            cache_dir=root,
            state_dir=root,
            legacy_dir=root,
            collapsed=True,
        )

    return Paths(
        config_dir=_xdg_root(environ, resolved_home, *_XDG_ROOTS["config"]),
        cache_dir=_xdg_root(environ, resolved_home, *_XDG_ROOTS["cache"]),
        state_dir=_xdg_root(environ, resolved_home, *_XDG_ROOTS["state"]),
        legacy_dir=legacy_dir,
        collapsed=False,
    )
