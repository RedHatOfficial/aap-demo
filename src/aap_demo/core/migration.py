"""Legacy ``~/.aap-demo`` → YAML + XDG-style layout migration (design §12.2).

Two guarantees drive the shape of this module:

* **Idempotent and crash-safe.** The config is written through a temp file and
  ``os.replace``; state files are moved one at a time and re-checked for
  existence, so an interrupted migration resumes correctly rather than
  half-applying.
* **Never the thing that hard-fails.** If no keyring backend resolves, the
  credential import is skipped with a loud message naming the files it did not
  touch, and the rest of the migration proceeds — a headless box must still be
  able to run ``status``.

Deliberate non-actions, each because it would destroy something: the ~30 GB
image cache is left where it is and its path is reported; the pull secret is
left in place because a human put it there; and ``~/.aap-demo/`` itself is
never deleted. Anything else in that directory, including a leftover
``atf-vault-password`` from the removed ``aap-demo test`` command, stays on
disk and is not imported.
"""

from __future__ import annotations

import os
import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Tuple

from aap_demo.core import config as config_mod
from aap_demo.core import schema
from aap_demo.core.paths import Paths

#: Legacy addon names that no longer exist as addons — they became day-2
#: playbooks (§4.8.5). Dropping them silently would look like data loss.
RETIRED_ADDONS = {
    "registry": "playbooks run registry-mirror",
    "local-cache": "playbooks run image-store",
}

#: Legacy addon aliases collapsed by the registry (§4.7).
ADDON_ALIASES = {"ao-eap": "ao"}

#: Legacy state files moved into <state>/ (§5.2 table). ``(source, destination)``
#: is resolved against the legacy dir and the new state dir respectively.
STATE_MOVES: Tuple[Tuple[str, str], ...] = (
    ("kubeconfig.microshift", "kubeconfig.microshift"),
    ("kubeconfig", "kubeconfig"),
    ("crc-ingress-ca.crt", "certs/crc-ingress-ca.crt"),
    ("ca-bundle.crt", "certs/ca-bundle.crt"),
)

#: Credential files imported into the keyring and then deleted. Deleting is the
#: point: a migration that leaves the plaintext behind has made a second copy.
CREDENTIAL_IMPORTS: Tuple[Tuple[str, str], ...] = (
    ("galaxy-token", "galaxy-token"),
    ("pah-token", "pah-token"),
)

CACHE_LEFT_IN_PLACE = "local-cache"

MIGRATED_MARKER_TEMPLATE = """\
This directory was migrated by aap-demo {version} on {date}.

Configuration is now at:
  {config_file}
State (kubeconfig, certificates, addon state):
  {state_dir}
Cache (image store, playbooks checkout):
  {cache_dir}

Files left here on purpose: hand-placed pull secrets and the local image
cache. Nothing in this directory was deleted.
"""


# ---------------------------------------------------------------------------
# Legacy KEY=VALUE parsing
# ---------------------------------------------------------------------------


def parse_legacy_config(text: str) -> Dict[str, str]:
    """Parse with the same permissiveness bash had: blanks and ``#`` ignored,
    surrounding quotes stripped, last value wins on duplicates."""
    values: Dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if not key:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value
    return values


def _split_addons(raw: str) -> Tuple[List[str], List[str]]:
    """Return ``(kept, retired)`` addon names, alias-normalized and deduped."""
    kept: List[str] = []
    retired: List[str] = []
    for item in raw.replace(",", " ").split():
        name = ADDON_ALIASES.get(item, item)
        if name in RETIRED_ADDONS:
            if name not in retired:
                retired.append(name)
            continue
        if name not in kept:
            kept.append(name)
    return kept, retired


def legacy_to_config(values: Mapping[str, str]) -> Tuple[Dict[str, Any], List[str], List[str]]:
    """Map legacy keys onto schema fields.

    Returns ``(config_data, retired_addons, unmapped_keys)``.
    """
    env_map = schema.env_map()
    data: Dict[str, Any] = {}
    unmapped: List[str] = []
    retired: List[str] = []

    for key, raw in values.items():
        if key == "ADDONS":
            kept, retired = _split_addons(raw)
            data.setdefault("addons", {})["enabled"] = kept
            continue
        target = env_map.get(key)
        if target is None:
            unmapped.append(key)
            continue
        section_name, field_name = target
        prop = schema.section(section_name)["properties"][field_name]
        data.setdefault(section_name, {})[field_name] = config_mod._coerce(raw, prop)

    return data, retired, unmapped


# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Action:
    kind: str  # write-config | move | import-secret | note | marker
    detail: str
    source: Optional[Path] = None
    dest: Optional[Path] = None

    def describe(self) -> str:
        return self.detail


@dataclass
class Plan:
    reason: str  # fresh | migrate | already-migrated
    actions: List[Action] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)
    config_data: Dict[str, Any] = field(default_factory=dict)

    @property
    def needed(self) -> bool:
        return self.reason != "already-migrated"


def plan(paths: Paths, *, secrets_available: bool = True) -> Plan:
    if paths.config_file.is_file():
        return Plan(reason="already-migrated")

    legacy_config = paths.legacy_config_file
    if not paths.legacy_dir.is_dir() or not legacy_config.is_file():
        # Case 3: no legacy config at all — write a fresh file from schema defaults.
        data = config_mod.resolve().as_dict()
        return Plan(
            reason="fresh",
            actions=[
                Action(
                    "write-config",
                    f"write fresh config {paths.config_file}",
                    dest=paths.config_file,
                )
            ],
            config_data=data,
        )

    values = parse_legacy_config(legacy_config.read_text(encoding="utf-8"))
    mapped, retired, unmapped = legacy_to_config(values)
    resolved = config_mod.resolve(file_data=mapped)

    result = Plan(reason="migrate", config_data=resolved.as_dict())
    result.actions.append(
        Action(
            "write-config",
            f"write {paths.config_file} from {legacy_config}",
            source=legacy_config,
            dest=paths.config_file,
        )
    )

    for retired_name in retired:
        result.warnings.append(
            f"addon '{retired_name}' is retired; its replacement is "
            f"`aap-demo {RETIRED_ADDONS[retired_name]}`"
        )
    for key in unmapped:
        result.warnings.append(f"legacy key {key} has no schema field and was not migrated")

    if not paths.collapsed:
        for source_name, dest_rel in STATE_MOVES:
            source = paths.legacy_dir / source_name
            if source.is_file():
                result.actions.append(
                    Action(
                        "move",
                        f"move {source} -> {paths.state_dir / dest_rel}",
                        source=source,
                        dest=paths.state_dir / dest_rel,
                    )
                )
        legacy_addons = paths.legacy_dir / "portal"
        if legacy_addons.is_dir():
            result.actions.append(
                Action(
                    "move",
                    f"move {legacy_addons} -> {paths.addon_dir('portal')}",
                    source=legacy_addons,
                    dest=paths.addon_dir("portal"),
                )
            )

    credential_sources = [
        paths.legacy_dir / name
        for name, _ in CREDENTIAL_IMPORTS
        if (paths.legacy_dir / name).is_file()
    ]
    if credential_sources:
        if secrets_available:
            for source in credential_sources:
                result.actions.append(
                    Action("import-secret", f"import and delete {source}", source=source)
                )
        else:
            result.warnings.append(
                "no OS credential store is available, so these files were NOT migrated and "
                "still contain plaintext credentials: "
                + ", ".join(str(p) for p in credential_sources)
            )

    cache = paths.legacy_dir / CACHE_LEFT_IN_PLACE
    if cache.is_dir():
        result.actions.append(
            Action(
                "note",
                f"left in place: {cache} (reclaim with `rm -rf {cache}`)",
                source=cache,
            )
        )

    result.actions.append(
        Action("marker", f"write {paths.migrated_marker}", dest=paths.migrated_marker)
    )
    return result


# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------


def apply(
    paths: Paths,
    migration_plan: Plan,
    *,
    secret_store: Any = None,
    dry_run: bool = False,
) -> List[str]:
    """Execute a plan. Returns the human-readable log of what was done."""
    log: List[str] = []
    if not migration_plan.needed:
        return log

    for action in migration_plan.actions:
        if dry_run:
            log.append(f"[dry-run] {action.describe()}")
            continue

        if action.kind == "write-config":
            config_mod.write(paths.config_file, migration_plan.config_data)
        elif action.kind == "move":
            _move(action.source, action.dest)
        elif action.kind == "import-secret":
            import_secret(action.source, secret_store, log)
            continue
        elif action.kind == "marker":
            _write_marker(paths)
        log.append(action.describe())

    return log


def _move(source: Optional[Path], dest: Optional[Path]) -> None:
    if source is None or dest is None:
        return
    if not source.exists():  # re-check: an interrupted run may have moved it already
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        return
    shutil.move(str(source), str(dest))


def _secret_name_for(source: Path) -> str:
    for name, secret in CREDENTIAL_IMPORTS:
        if source.name == name:
            return secret
    return source.name


def import_secret(source: Optional[Path], secret_store: Any, log: List[str]) -> None:
    if source is None or secret_store is None or not source.is_file():
        return
    value = source.read_text(encoding="utf-8").strip()
    if not value:
        return
    name = _secret_name_for(source)
    secret_store.set(name, value)
    source.unlink()
    log.append(f"imported {source} into the credential store and deleted the file")


def _write_marker(paths: Paths) -> None:
    from datetime import datetime

    from aap_demo import __version__

    paths.legacy_dir.mkdir(parents=True, exist_ok=True)
    paths.migrated_marker.write_text(
        MIGRATED_MARKER_TEMPLATE.format(
            version=__version__,
            date=datetime.now().strftime("%Y-%m-%d"),
            config_file=paths.config_file,
            state_dir=paths.state_dir,
            cache_dir=paths.cache_dir,
        ),
        encoding="utf-8",
    )


def migrate_if_needed(
    paths: Paths,
    *,
    env: Optional[Mapping[str, str]] = None,
    secret_store: Any = None,
) -> Tuple[Plan, List[str]]:
    """The automatic first-run path. Skippable via ``AAP_DEMO_SKIP_MIGRATION=1``."""
    environ = os.environ if env is None else env
    if environ.get("AAP_DEMO_SKIP_MIGRATION"):
        return Plan(reason="already-migrated"), []

    secrets_available = bool(secret_store) and secret_store.available()
    migration_plan = plan(paths, secrets_available=secrets_available)
    if not migration_plan.needed:
        return migration_plan, []
    log = apply(paths, migration_plan, secret_store=secret_store)
    return migration_plan, log
