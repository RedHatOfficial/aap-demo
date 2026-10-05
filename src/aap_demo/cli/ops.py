"""Operational commands: version, config, secrets, ssh/kubeconfig, and stubs."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Any, Dict, List

from aap_demo.cluster import kubeconfig as kubeconfig_mod
from aap_demo.cluster import runtime as runtime_mod
from aap_demo.core import config as config_mod
from aap_demo.core import migration, output, schema
from aap_demo.core import version as version_mod
from aap_demo.core.context import AppContext
from aap_demo.core.errors import (
    AapDemoError,
    ClusterUnreachableError,
    NotImplementedYetError,
    UsageError,
)
from aap_demo.core.output import is_structured
from aap_demo.core.paths import display_path
from aap_demo.exec import oc as oc_mod
from aap_demo.exec import ssh as ssh_mod
from aap_demo.infra import crc as infra_crc

# ---------------------------------------------------------------------------
# Implemented in phase 0
# ---------------------------------------------------------------------------


# Short names for config get/set. The value is stored under the schema path.
CONFIG_KEY_ALIASES = {
    "pull-secret": "deploy.pull_secret_path",
    "pull_secret": "deploy.pull_secret_path",
}


def _config_key(key: str) -> str:
    return CONFIG_KEY_ALIASES.get(key, key)


def version(ctx: AppContext, args: argparse.Namespace) -> int:
    info = version_mod.version_info(ctx.runner)
    output.render(
        ctx.console,
        info.as_dict(),
        output=ctx.output,
        text=lambda: version_mod.render_text(info),
    )
    return 0


def config(ctx: AppContext, args: argparse.Namespace) -> int:
    action = getattr(args, "config_action", None)
    if action is None:
        raise UsageError(
            "config requires a subcommand: get, set, list, edit, path, migrate, secrets"
        )

    if action == "path":
        ctx.console.out(str(ctx.paths.config_file))
        return 0

    if action == "list":
        output.render(
            ctx.console,
            ctx.config.as_dict(),
            output=ctx.output if is_structured(ctx.output) else "yaml",
        )
        return 0

    if action == "get":
        key = _config_key(args.key)
        known = schema.config_paths()
        if key not in known and ctx.config.get(key) is None:
            raise UsageError(f"unknown config key: {args.key}")
        output.render(
            ctx.console,
            ctx.config.get(key),
            output=ctx.output,
            text=lambda: "" if ctx.config.get(key) is None else str(ctx.config.get(key)),
        )
        return 0

    if action == "set":
        key = _config_key(args.key)
        if key not in schema.config_paths():
            raise UsageError(
                f"unknown config key: {args.key}",
            )
        file_config = config_mod.Config(
            config_mod.read_yaml(ctx.paths.config_file), path=ctx.paths.config_file
        )
        merged = config_mod.resolve(file_data=file_config.data, env={})
        merged.set(key, args.value)
        merged.save(ctx.paths.config_file)
        shown = args.key if args.key in CONFIG_KEY_ALIASES else key
        ctx.console.success(f"{shown} = {merged.get(key)}")
        return 0

    if action == "edit":
        editor = ctx.env.get("VISUAL") or ctx.env.get("EDITOR")
        if not editor:
            raise UsageError(
                "no editor configured",
                hint=f"Set $EDITOR or $VISUAL, or edit {ctx.paths.config_file} directly.",
            )
        if not ctx.paths.config_file.is_file():
            config_mod.write(ctx.paths.config_file, ctx.config.as_dict())
        # Through the runner seam like every other subprocess (§2.2), with
        # capture off so the editor inherits the terminal.
        return ctx.runner.run([editor, str(ctx.paths.config_file)], capture=False).returncode

    if action == "migrate":
        return _config_migrate(ctx, args)

    if action == "secrets":
        return _config_secrets(ctx, args)

    raise UsageError(f"unknown config subcommand: {action}")


def _config_migrate(ctx: AppContext, args: argparse.Namespace) -> int:
    if getattr(args, "force", False) and ctx.paths.config_file.is_file():
        ctx.paths.config_file.unlink()

    plan = migration.plan(ctx.paths, secrets_available=ctx.secrets.available())
    if not plan.needed:
        ctx.console.info(f"Already migrated: {ctx.paths.config_file}")
        return 0

    log = migration.apply(
        ctx.paths, plan, secret_store=ctx.secrets, dry_run=bool(getattr(args, "dry_run", False))
    )
    for line in log:
        ctx.console.out(line)
    for warning in plan.warnings:
        ctx.console.warn(warning)
    if not getattr(args, "dry_run", False):
        ctx.console.success(f"Configuration is now at {ctx.paths.config_file}")
    return 0


def _config_secrets(ctx: AppContext, args: argparse.Namespace) -> int:
    action = getattr(args, "secrets_action", None)
    if action == "list":
        refs = [{"name": ref.name, "backend": ref.backend} for ref in ctx.secrets.list()]
        output.render(
            ctx.console,
            refs,
            output=ctx.output,
            text=lambda: (
                "\n".join(f"{r['name']}  ({r['backend']})" for r in refs)
                or "No credentials stored."
            ),
        )
        return 0

    if action == "set":
        # Never an argv value: it would land in shell history (§5.5.2).
        if not sys.stdin.isatty():
            value = sys.stdin.read().strip()
        else:
            import getpass

            value = getpass.getpass(f"Value for {args.name}: ")
        if not value:
            raise UsageError("refusing to store an empty credential")
        ctx.secrets.set(args.name, value)
        ctx.console.success(f"Stored {args.name} in {ctx.secrets.backend_name}")
        return 0

    if action == "delete":
        ctx.secrets.delete(args.name)
        ctx.console.success(f"Deleted {args.name}")
        return 0

    if action == "migrate":
        plan = migration.plan(ctx.paths, secrets_available=ctx.secrets.available())
        actions = [a for a in plan.actions if a.kind == "import-secret"]
        if not actions:
            ctx.console.info("No legacy credential files to import.")
            return 0
        for action_item in actions:
            log: list = []
            migration.import_secret(action_item.source, ctx.secrets, log)
            for line in log:
                ctx.console.out(line)
        return 0

    raise UsageError("config secrets requires: list, set, delete, or migrate")


# ---------------------------------------------------------------------------
# Implemented in phase 1
# ---------------------------------------------------------------------------


def ssh(ctx: AppContext, args: argparse.Namespace) -> int:
    """Ports ``cmd_ssh`` (aap-demo.sh:1596-1604).

    See ``exec/ssh.py::interactive_shell`` for why this bypasses the
    ``CommandRunner`` capture path entirely (design §14 R10).
    """
    key = ssh_mod.detect_ssh_key(ssh_mod.crc_machines_dir(ctx.env))
    if key is None:
        raise ClusterUnreachableError("No CRC SSH key found. Is OpenShift Local running?")
    ssh_mod.interactive_shell(key)
    return 0  # pragma: no cover - interactive_shell replaces the process or exits first


def kubeconfig(ctx: AppContext, args: argparse.Namespace) -> int:
    """Ports ``cmd_kubeconfig`` (aap-demo.sh:1606-1683)."""
    ctx.console.out("")
    ctx.console.step("aap-demo kubeconfig - Syncing local aap-demo kubeconfig...")
    ctx.console.out("")

    if infra_crc.get_state(ctx.runner) != infra_crc.STATE_RUNNING:
        raise ClusterUnreachableError("Cluster not running", hint="Run 'aap-demo create' first")

    key = ssh_mod.detect_ssh_key(ssh_mod.crc_machines_dir(ctx.env))
    if key is None:
        raise ClusterUnreachableError("No CRC SSH key found. Is OpenShift Local running?")

    preset = ctx.config.get("crc.preset", "microshift")
    ctx.console.out(f"  Extracting kubeconfig from {infra_crc.get_name(preset)}...")
    destination = kubeconfig_mod.sync(ctx.runner, key=key, destination=ctx.kubeconfig)
    home = Path(ctx.env.get("HOME") or Path.home())
    activated = kubeconfig_mod.activate_context(
        destination, kubeconfig_mod.default_kubeconfig_file(home)
    )

    shown = display_path(destination, home)
    ctx.console.checkpoint(f"Saved to {shown}")
    ctx.console.checkpoint(f"Current context is {kubeconfig_mod.CONTEXT_NAME}")
    ctx.console.out(f"  {display_path(activated, home)}")
    ctx.console.out(f"  KUBECONFIG={shown} oc cluster-info")
    return 0


def _oc_kubeconfig(ctx: AppContext) -> Path:
    """The kubeconfig ``aap-demo oc`` should use.

    An explicit ``--kubeconfig`` or ``AAP_DEMO_KUBECONFIG`` wins. An ambient
    ``KUBECONFIG`` does not, so the wrapper stays pointed at this cluster.
    """
    if ctx.kubeconfig_override is not None:
        return ctx.kubeconfig_override
    explicit = str(ctx.env.get("AAP_DEMO_KUBECONFIG") or "").strip()
    if explicit:
        return Path(explicit).expanduser()
    return ctx.paths.kubeconfig


def oc(ctx: AppContext, args: argparse.Namespace) -> int:
    """Run ``oc`` with ``KUBECONFIG`` set to the aap-demo kubeconfig.

    ``exec_oc`` replaces this process, so a successful call does not return.
    """
    oc_mod.exec_oc(
        _oc_kubeconfig(ctx),
        list(getattr(args, "oc_args", None) or []),
        env=ctx.env,
    )
    return 0  # pragma: no cover - exec_oc replaces the process or exits first


# -- redhat-status ------------------------------------------------------

RSS_URL = "https://status.redhat.com/history.rss"

_ITEM_RE = re.compile(r"<item>(.*?)</item>", re.IGNORECASE)
_TITLE_RE = re.compile(r"<title>([^<]*)</title>")
_LINK_RE = re.compile(r"<link>([^<]*)</link>")
_STATUS_WORD_RE = re.compile(r"Investigating|Identified|Monitoring|In progress|Update")
_RESOLVED_RE = re.compile(r"resolved|completed", re.IGNORECASE)
_KEYWORD_RE = re.compile(r"registry|quay|rhsso|login|403|authentication", re.IGNORECASE)


def _unescape_xml_entities(text: str) -> str:
    return text.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")


def _fetch_rss(runner: Any) -> str:
    """Ports the ``curl -s --connect-timeout 5`` fetch (aap-demo.sh:841).

    Goes through ``CommandRunner`` (curl, as bash already shells out to)
    rather than a Python HTTP client, so it stays inside the single
    "everything is a subprocess call the runner mediates" seam (§7.2) and is
    FakeRunner-testable without adding an HTTP-client dependency the design
    doc's mapping table suggested (``httpx``/``urllib``) but nothing else in
    phase 1 needs.
    """
    result = runner.run(["curl", "-s", "--connect-timeout", "5", RSS_URL])
    return result.stdout if result.ok else ""


def _parse_incidents(rss_content: str) -> List[Dict[str, str]]:
    """Ports the active-incident RSS parse (aap-demo.sh:849-874)."""
    collapsed = rss_content.replace("\n", " ")
    incidents: List[Dict[str, str]] = []
    for match in _ITEM_RE.finditer(collapsed):
        item_text = match.group(0)
        if _RESOLVED_RE.search(item_text):
            continue
        if not _KEYWORD_RE.search(item_text):
            continue
        title_match = _TITLE_RE.search(item_text)
        title = _unescape_xml_entities(title_match.group(1)).strip() if title_match else ""
        if not title:
            continue
        status_match = _STATUS_WORD_RE.search(item_text)
        link_match = _LINK_RE.search(item_text)
        incidents.append(
            {
                "title": title,
                "status": status_match.group(0) if status_match else "",
                "link": _unescape_xml_entities(link_match.group(1)).strip() if link_match else "",
            }
        )
    return incidents


def redhat_status(ctx: AppContext, args: argparse.Namespace) -> int:
    """Ports ``cmd_redhat_status`` (aap-demo.sh:834-883).

    Bash prints the header *before* fetching, so a failed fetch still shows
    it; the same order is kept here.
    """
    if not is_structured(ctx.output):
        ctx.console.out("")
        ctx.console.step("aap-demo redhat-status - Checking Red Hat service status...")
        ctx.console.out("")

    rss_content = _fetch_rss(ctx.runner)
    if not rss_content.strip():
        raise AapDemoError(f"Unable to fetch status from {RSS_URL}")

    incidents = _parse_incidents(rss_content)

    if is_structured(ctx.output):
        output.render(ctx.console, {"incidents": incidents}, output=ctx.output)
        return 0

    ctx.console.out("Active Incidents:")
    ctx.console.out("=================")
    if not incidents:
        # Report content, not an error condition: bash printed all of this to
        # stdout, glyph included (aap-demo.sh:869-880).
        ctx.console.report("No active registry-related incidents", status="ok", indent=2)
    else:
        for incident in incidents:
            ctx.console.out("")
            ctx.console.report(incident["title"], status="warn", indent=2)
            if incident["status"]:
                ctx.console.out(f"    Status: {incident['status']}")
            if incident["link"]:
                ctx.console.out(f"    Details: {incident['link']}")
    ctx.console.out("")
    ctx.console.out("Full status: https://status.redhat.com")
    return 0


# ---------------------------------------------------------------------------
# Phase 2 stubs
# ---------------------------------------------------------------------------


def idle(ctx: AppContext, args: argparse.Namespace) -> int:
    """Ports ``cmd_idle``."""
    return runtime_mod.idle(ctx, getattr(args, "state", None))


def update(ctx: AppContext, args: argparse.Namespace) -> int:
    raise NotImplementedYetError("update")
