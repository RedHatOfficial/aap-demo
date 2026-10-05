"""Root command group, global options, and dispatch (design §3).

``--help`` is framework-generated, but its *content* is a faithful port of the
bash ``show_help`` (aap-demo.sh:424): the same commands, the same grouping, and
the same ENVIRONMENT / EXAMPLES / REQUIREMENTS trailer.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

from aap_demo import __version__
from aap_demo.cli import addons as addons_cli
from aap_demo.cli import completion as completion_cli
from aap_demo.cli import day2, lifecycle, observe, ops
from aap_demo.cli import gui as gui_cli
from aap_demo.cli._schema_args import add_schema_arguments, collect_overrides
from aap_demo.cluster import preflight
from aap_demo.cluster import pull_secret as pull_secret_mod
from aap_demo.core import config as config_mod
from aap_demo.core import migration, schema
from aap_demo.core import output as output_mod
from aap_demo.core.console import Console
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError, UsageError
from aap_demo.core.events import ConsoleSink, EventEmitter
from aap_demo.core.paths import Paths, resolve_paths
from aap_demo.core.secrets import SecretStore
from aap_demo.exec.runner import SubprocessRunner

PROG = "aap-demo"

DESCRIPTION = "aap-demo - Deploy AAP 2.7 to OpenShift Local"

EPILOG = """\
ENVIRONMENT:
    AAP_DEMO_DIR            Collapse config/state/cache back under one directory
    AAP_DEMO_CONFIG         Explicit config file (same as --config)
    AAP_DEMO_KUBECONFIG     Kubeconfig path override
    AAP_DEMO_SKIP_MIGRATION Skip the one-time legacy-config migration
    NAMESPACE, QUIET, FORCE Legacy equivalents of --namespace, --quiet, --force

EXAMPLES:
    aap-demo create                  # Create OpenShift Local cluster
    aap-demo deploy                  # Deploy AAP 2.7
    aap-demo status                  # Show cluster and AAP status
    aap-demo stop                    # Stop cluster
    aap-demo start                   # Start stopped cluster
    aap-demo ssh                     # SSH into cluster node
    aap-demo oc cluster-info         # oc against the aap-demo kubeconfig

REQUIREMENTS:
    - OpenShift Local - https://console.redhat.com/openshift/create/local
    - On Linux: libvirt-daemon, libvirt-daemon-driver-storage, qemu-kvm

    For all deployments:
    - kubectl
    - Pull secret from https://console.redhat.com/openshift/install/pull-secret
      Save it as ~/.local/state/aap-demo/pull-secret.txt and it is used automatically.
      pull-secret.json in that directory is also accepted.
      Or: aap-demo config set pull-secret ~/path/to/pull-secret.txt
      One command can override that with AAP_DEMO_PULL_SECRET.
      XDG_STATE_HOME or AAP_DEMO_DIR moves that directory.
"""

WELCOME = """\
aap-demo - Deploy AAP 2.7 to OpenShift Local

Run 'aap-demo help' for the full command reference, or start with:
    aap-demo create      Create the OpenShift Local cluster
    aap-demo deploy      Deploy AAP 2.7
    aap-demo status      Show cluster and AAP status
"""

DISCLAIMER = (
    "aap-demo is a community demo tool. It is not supported by Red Hat and is "
    "not intended for production use."
)


class _Formatter(argparse.RawDescriptionHelpFormatter):
    def __init__(self, prog: str) -> None:
        super().__init__(prog, max_help_position=28, width=100)


def _add_global_options(
    parser: argparse.ArgumentParser, resolved: Mapping[str, Any], suppress: bool
) -> None:
    """Global options: the schema-derived ones plus §3.1's CLI-only allowlist."""
    add_schema_arguments(parser, "core", resolved=resolved.get("core", {}), suppress=suppress)
    default = argparse.SUPPRESS if suppress else None
    parser.add_argument(
        "--kubeconfig", metavar="PATH", default=default, help="Path to a kubeconfig file"
    )
    parser.add_argument("--context", metavar="NAME", default=default, help="kubectl context to use")
    parser.add_argument("--config", metavar="PATH", default=default, help="Explicit config file")
    parser.add_argument(
        "--output",
        choices=("rich", "basic", "json", "yaml"),
        default=argparse.SUPPRESS if suppress else resolved.get("core", {}).get("output", "rich"),
        help="Presentation: rich (live, default), basic (plain log), json, or yaml",
    )
    parser.add_argument(
        "-q", "--quiet", action="store_true", default=default, help="Silence all output"
    )
    parser.add_argument(
        "--force",
        action="store_true",
        default=default,
        help="Force the action even if it already exists",
    )
    parser.add_argument(
        "-y", "--yes", action="store_true", default=default, help="Assume yes for confirmations"
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", default=default, help="Show command output"
    )
    parser.add_argument(
        "--set",
        metavar="KEY=VALUE",
        action="append",
        default=argparse.SUPPRESS if suppress else [],
        help="Set an environment variable for this run (repeatable)",
    )


def build_parser(
    resolved: Optional[Mapping[str, Any]] = None, *, suppress: bool = False
) -> argparse.ArgumentParser:
    values: Mapping[str, Any] = resolved or schema.defaults()

    globals_parser = argparse.ArgumentParser(add_help=False)
    _add_global_options(globals_parser, values, suppress)

    parser = argparse.ArgumentParser(
        prog=PROG,
        description=DESCRIPTION,
        epilog=EPILOG,
        formatter_class=_Formatter,
        parents=[globals_parser],
    )
    parser.add_argument(
        "-V",
        "--version",
        action="version",
        version=f"aap-demo {__version__}",
        help="Show aap-demo version and exit",
    )

    sub = parser.add_subparsers(dest="command", metavar="<COMMAND>")

    def add(name: str, help_text: str, **kwargs: Any) -> argparse.ArgumentParser:
        return sub.add_parser(
            name,
            help=help_text,
            description=help_text,
            parents=[globals_parser],
            formatter_class=_Formatter,
            **kwargs,
        )

    # -- cluster lifecycle --------------------------------------------------
    p = add("create", "Create OpenShift Local cluster")
    add_schema_arguments(p, "crc", resolved=values.get("crc", {}), suppress=suppress)
    add_schema_arguments(p, "deploy", resolved=values.get("deploy", {}), suppress=suppress)
    add_schema_arguments(p, "trust", resolved=values.get("trust", {}), suppress=suppress)
    p.set_defaults(func=lifecycle.create)

    p = add("destroy", "Delete local cluster (--reset also clears config)")
    p.add_argument("--reset", action="store_true", help="Also clear aap-demo configuration")
    p.set_defaults(func=lifecycle.destroy)

    add("stop", "Stop local cluster gracefully").set_defaults(func=lifecycle.stop)
    add("start", "Start stopped cluster (re-applies CoreDNS config)").set_defaults(
        func=lifecycle.start
    )
    add("repair", "Repair cluster after crash").set_defaults(func=lifecycle.repair)
    add("setup", "Run setup only (storage, coredns, mkcert)").set_defaults(func=lifecycle.setup)
    add("redeploy-all", "Destroy cluster and redeploy fresh").set_defaults(
        func=lifecycle.redeploy_all
    )

    # -- AAP lifecycle ------------------------------------------------------
    p = add("deploy", "Deploy AAP 2.7 (operator + CR)", aliases=["deploy-all"])
    add_schema_arguments(p, "deploy", resolved=values.get("deploy", {}), suppress=suppress)
    p.set_defaults(func=lifecycle.deploy)

    add("clean", "Remove AAP deployment").set_defaults(func=lifecycle.clean)
    add("redeploy", "Clean AAP and redeploy").set_defaults(func=lifecycle.redeploy)

    # -- observation --------------------------------------------------------
    add("status", "Show cluster and AAP status").set_defaults(func=observe.status)
    add("watch", "Watch AAP deployment status").set_defaults(func=observe.watch)

    p = add("diagnose", "Check environment health and identify common issues")
    p.add_argument(
        "--ai", action="store_true", help="Analyze issues with Claude AI (requires the claude CLI)"
    )
    p.set_defaults(func=observe.diagnose)

    p = add("must-gather", "Collect AAP and cluster diagnostics")
    p.add_argument("dest", nargs="?", metavar="DIR", help="Output directory")
    p.set_defaults(func=observe.must_gather)

    # -- operations ---------------------------------------------------------
    p = add("idle", "Scale down/up AAP to save resources")
    p.add_argument(
        "state", nargs="?", choices=("true", "false"), help="No arg shows the current state"
    )
    p.set_defaults(func=ops.idle)

    add("ssh", "SSH into cluster node").set_defaults(func=ops.ssh)
    add("kubeconfig", "Extract and merge kubeconfig").set_defaults(func=ops.kubeconfig)
    # No shared global options: every argument after ``oc``, including ones
    # that look like aap-demo flags, is passed through to the OpenShift CLI.
    oc_parser = sub.add_parser(
        "oc",
        help="Run oc with the aap-demo kubeconfig",
        description=(
            "Run oc with KUBECONFIG set to the aap-demo kubeconfig "
            "(~/.local/state/aap-demo/kubeconfig.microshift by default)."
        ),
        add_help=False,
        formatter_class=_Formatter,
    )
    oc_parser.add_argument("oc_args", nargs=argparse.REMAINDER, help=argparse.SUPPRESS)
    oc_parser.set_defaults(func=ops.oc)
    add("update", "Update aap-demo to the latest release").set_defaults(func=ops.update)
    add("version", "Show aap-demo version and build metadata").set_defaults(func=ops.version)
    add("redhat-status", "Check Red Hat registry status", aliases=["rh-status"]).set_defaults(
        func=ops.redhat_status
    )

    _add_config_command(add, sub)

    # -- addons -------------------------------------------------------------
    p = add("enable", "Enable an addon")
    p.add_argument("addon", nargs="?", help="Addon name; omit to list available addons")
    p.add_argument("addon_args", nargs="*", metavar="ARGS", help="Addon-specific arguments")
    p.add_argument(
        "--refresh-catalog", action="store_true", help="Refresh the operator catalog first"
    )
    p.set_defaults(func=addons_cli.enable)

    p = add("disable", "Disable an addon")
    p.add_argument("addon", nargs="?", help="Addon name")
    p.add_argument(
        "--purge-creds", action="store_true", help="Also remove stored addon credentials"
    )
    p.set_defaults(func=addons_cli.disable)

    p = add("addon", "List, inspect, and scaffold addons")
    addon_sub = p.add_subparsers(dest="addon_action", metavar="<ACTION>")
    addon_sub.add_parser("list", help="List discovered addons", parents=[globals_parser])
    info = addon_sub.add_parser("info", help="Show an addon's manifest", parents=[globals_parser])
    info.add_argument("name")
    create_addon = addon_sub.add_parser(
        "create", help="Scaffold a new addon package", parents=[globals_parser]
    )
    create_addon.add_argument("name")
    p.set_defaults(func=addons_cli.addon)

    # -- day-2 playbooks ----------------------------------------------------
    p = add("playbooks", "Run day-2 operations from the aap-demo-playbooks repo")
    pb_sub = p.add_subparsers(dest="playbooks_action", metavar="<ACTION>")
    pb_sub.add_parser("list", help="List available playbooks", parents=[globals_parser])
    pb_info = pb_sub.add_parser("info", help="Show a playbook's manifest", parents=[globals_parser])
    pb_info.add_argument("name")
    pb_run = pb_sub.add_parser("run", help="Run a playbook", parents=[globals_parser])
    pb_run.add_argument("name")
    pb_run.add_argument("-e", "--extra-vars", action="append", metavar="KEY=VALUE", default=[])
    pb_run.add_argument("--check", action="store_true", help="Run in check mode")
    pb_create = pb_sub.add_parser(
        "create", help="Scaffold a new playbook", parents=[globals_parser]
    )
    pb_create.add_argument("name")
    pb_update = pb_sub.add_parser(
        "update", help="Fetch and pin the playbooks repo", parents=[globals_parser]
    )
    add_schema_arguments(
        pb_update, "playbooks", resolved=values.get("playbooks", {}), suppress=suppress
    )
    p.set_defaults(func=day2.playbooks)

    # -- gui ----------------------------------------------------------------
    p = add("gui", "Start the web GUI (requires the [gui] extra)")
    add_schema_arguments(p, "gui", resolved=values.get("gui", {}), suppress=suppress)
    p.set_defaults(func=gui_cli.gui)

    # -- completion / help --------------------------------------------------
    p = add("completion", "Emit a shell completion script")
    p.add_argument("shell", nargs="?", choices=("bash", "zsh", "fish", "powershell"))
    p.set_defaults(func=completion_cli.completion)

    add("help", "Show this help").set_defaults(func=None, command="help")

    return parser


def _add_config_command(add: Any, sub: Any) -> None:
    p = add("config", "Configure aap-demo settings")
    config_sub = p.add_subparsers(dest="config_action", metavar="<ACTION>")

    config_sub.add_parser("list", help="Print the resolved configuration")
    config_sub.add_parser("path", help="Print the config file path")

    get = config_sub.add_parser("get", help="Read one config key")
    get.add_argument("key", metavar="KEY")

    set_cmd = config_sub.add_parser("set", help="Write one config key")
    set_cmd.add_argument("key", metavar="KEY")
    set_cmd.add_argument("value", metavar="VALUE")

    config_sub.add_parser("edit", help="Open the config file in $EDITOR")

    migrate = config_sub.add_parser("migrate", help="Migrate the legacy ~/.aap-demo layout")
    migrate.add_argument(
        "--dry-run", action="store_true", help="Print the plan without touching anything"
    )
    migrate.add_argument("--force", action="store_true", help="Re-run the migration")

    secrets = config_sub.add_parser("secrets", help="Inspect the OS credential store")
    secrets_sub = secrets.add_subparsers(dest="secrets_action", metavar="<ACTION>")
    secrets_sub.add_parser("list", help="List credential names and the backend (never values)")
    secrets_set = secrets_sub.add_parser(
        "set", help="Store a credential (reads from a prompt or stdin)"
    )
    secrets_set.add_argument("name")
    secrets_delete = secrets_sub.add_parser("delete", help="Delete a credential")
    secrets_delete.add_argument("name")
    secrets_sub.add_parser("migrate", help="Import legacy credential files into the keyring")

    p.set_defaults(func=ops.config)


# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------


def _config_path(args_config: Optional[str], env: Mapping[str, str], paths: Paths) -> Path:
    explicit = args_config or env.get("AAP_DEMO_CONFIG")
    return Path(explicit).expanduser() if explicit else paths.config_file


def _peek_global(argv: Sequence[str], name: str) -> Optional[str]:
    """Read a global option before the real parser exists (config path, quiet)."""
    for i, token in enumerate(argv):
        if token == name and i + 1 < len(argv):
            return argv[i + 1]
        if token.startswith(name + "="):
            return token.split("=", 1)[1]
    return None


def _apply_set_overrides(pairs: Sequence[str], env: Dict[str, str]) -> None:
    """``--set KEY=VALUE`` replaces bash's blanket ``export "$arg"`` (§3.2)."""
    for pair in pairs:
        if "=" not in pair:
            raise UsageError(f"--set expects KEY=VALUE, got: {pair}")
        key, _, value = pair.partition("=")
        env[key] = value


def build_context(
    args: argparse.Namespace,
    *,
    env: Mapping[str, str],
    paths: Paths,
    config: config_mod.Config,
    console: Console,
    runner: Any,
    secrets: SecretStore,
) -> AppContext:
    ctx = AppContext(
        config=config,
        paths=paths,
        console=console,
        runner=runner,
        secrets=secrets,
        env=dict(env),
        output=output_mod.normalize(getattr(args, "output", "rich") or "rich"),
        force=bool(getattr(args, "force", False)),
        assume_yes=bool(getattr(args, "yes", False)),
        verbose=bool(getattr(args, "verbose", False)),
        kubeconfig_override=(
            Path(args.kubeconfig).expanduser() if getattr(args, "kubeconfig", None) else None
        ),
        kube_context=getattr(args, "context", None),
        namespace_explicit=bool(getattr(args, "_namespace_explicit", False)),
    )
    ctx.events = EventEmitter(sink=ConsoleSink(console, verbose=ctx.verbose))
    return ctx


def _parse(
    argv: Sequence[str], resolved: Mapping[str, Any]
) -> Tuple[argparse.Namespace, argparse.Namespace, argparse.ArgumentParser]:
    parser = build_parser(resolved)
    args = parser.parse_args(list(argv))
    supplied = build_parser(resolved, suppress=True).parse_args(list(argv))
    # Global options live on both the root parser and (via `parents=`) every
    # subparser, so a value typed *before* the subcommand is otherwise clobbered
    # by the subparser's default. The SUPPRESS-default parse holds only what the
    # user actually typed, so overlaying it restores "explicit beats default"
    # regardless of where on the command line the option appeared.
    for key, value in vars(supplied).items():
        setattr(args, key, value)
    return args, supplied, parser


#: Commands that get bash's ``setup_kubeconfig`` + ``verify_cluster_type``
#: preflight (the ``*`` branch of the dispatch case, aap-demo.sh:2861-2874).
#: Only *ported* commands are listed: an unported command raises
#: ``NotImplementedYetError`` before touching a cluster, so running the
#: preflight for it would turn a clear "not yet implemented" into a spurious
#: kubectl/kubeconfig failure. Later phases add their names here as they land.
#: ``create``/``deploy``/``redeploy``… take ``setup_kubeconfig`` *without* the
#: warning — see :data:`SELF_MANAGED_COMMANDS`.
CLUSTER_COMMANDS = frozenset(
    {
        "status",
        "diagnose",
        "ssh",
        "kubeconfig",
        "redhat-status",
        "rh-status",
        "clean",
        "setup",
        "start",
        "stop",
        "idle",
        "repair",
        "watch",
        "must-gather",
    }
)

#: Bash's *other* preflight branch (aap-demo.sh:2942-2945): these get
#: ``setup_kubeconfig`` but not ``verify_cluster_type``, because they handle
#: cluster state themselves — ``deploy`` starts or creates the cluster rather
#: than warning about it, and printing "No cluster exists" immediately before
#: creating one would contradict the action being taken.
#: ``create`` belongs here too: it builds the cluster, so the "no cluster"
#: warning would contradict the command. ``destroy`` stays out of both sets
#: because bash runs it with no kubeconfig preflight.
SELF_MANAGED_COMMANDS = frozenset({"deploy", "deploy-all", "redeploy", "create"})


def _preflight(ctx: AppContext, command: str) -> None:
    """Bash's pre-dispatch ``setup_kubeconfig`` + ``verify_cluster_type``."""
    if command in SELF_MANAGED_COMMANDS:
        preflight.setup_kubeconfig(ctx)
        return
    if command not in CLUSTER_COMMANDS:
        return
    preflight.setup_kubeconfig(ctx)
    preflight.warn_cluster_state(ctx)


def run(
    argv: Optional[Sequence[str]] = None,
    *,
    env: Optional[Mapping[str, str]] = None,
    runner: Optional[Any] = None,
) -> int:
    raw_argv: List[str] = list(sys.argv[1:] if argv is None else argv)
    environ: Dict[str, str] = dict(os.environ if env is None else env)

    paths = resolve_paths(environ)
    console = Console(quiet=bool(environ.get("QUIET")), env=environ)
    secrets = SecretStore()

    # The one-time legacy migration runs before config is read, and is cheap on
    # every subsequent invocation because it checks for config.yaml first (§12.2).
    if not any(token in raw_argv for token in ("-h", "--help")):
        try:
            plan, log = migration.migrate_if_needed(paths, env=environ, secret_store=secrets)
            if plan.reason == "migrate":
                console.info(f"Migrated configuration to {paths.config_file}")
                for line in log:
                    console.detail(line)
                for warning in plan.warnings:
                    console.warn(warning)
        except AapDemoError as exc:
            console.warn(f"configuration migration skipped: {exc.message}")

    config_path = _config_path(_peek_global(raw_argv, "--config"), environ, paths)
    file_data = config_mod.read_yaml(config_path)
    resolved = config_mod.resolve(file_data=file_data, env=environ, path=config_path)

    if not raw_argv:
        console.notice(DISCLAIMER)
        console.out(WELCOME)
        home = Path(environ.get("HOME") or Path.home())
        configured = str(resolved.get("deploy.pull_secret_path", "") or "")
        note = pull_secret_mod.welcome_note(paths, configured, home)
        if note:
            console.out(note)
        return 0

    args, supplied, parser = _parse(raw_argv, resolved.as_dict())

    if getattr(args, "command", None) in (None, "help"):
        parser.print_help()
        return 0

    _apply_set_overrides(getattr(args, "set", None) or [], environ)

    overrides = collect_overrides(supplied)
    config = config_mod.resolve(
        file_data=file_data, env=environ, overrides=overrides, path=config_path
    )

    quiet = bool(getattr(args, "quiet", False)) or bool(config.get("core.quiet"))
    presented = output_mod.normalize(getattr(args, "output", "rich") or "rich")
    style = "basic" if output_mod.is_structured(presented) else presented
    console = Console(quiet=quiet, style=style, env=environ)
    secrets = SecretStore(backend=str(config.get("secrets.backend", "auto")))
    args._namespace_explicit = "core" in overrides and "namespace" in overrides["core"]

    ctx = build_context(
        args,
        env=environ,
        paths=paths,
        config=config,
        console=console,
        runner=runner if runner is not None else SubprocessRunner(),
        secrets=secrets,
    )

    func = getattr(args, "func", None)
    if func is None:
        parser.print_help()
        return 0

    # KUBECONFIG/context preflight, before the command runs a single
    # subprocess — bash does the same from its dispatch block.
    try:
        _preflight(ctx, str(getattr(args, "command", "") or ""))
        return int(func(ctx, args) or 0)
    finally:
        ctx.console.finish()


def main(argv: Optional[Sequence[str]] = None, *, runner: Optional[Any] = None) -> int:
    console = Console()
    try:
        return run(argv, runner=runner)
    except AapDemoError as exc:
        console.error(exc.message, hint=exc.hint)
        return exc.exit_code
    except KeyboardInterrupt:  # pragma: no cover - interactive only
        console.err("Interrupted.")
        return 130


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
