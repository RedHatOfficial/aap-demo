"""Run a bundled bash addon installer from the new command.

Fleet stays in Python. Legacy addons still live in ``addons/*/deploy.sh``.
This module runs those scripts with the new command's kubeconfig and records
the result in ``addons.enabled``. A wheel carries them under
``aap_demo/bundled/`` in the repository's layout (ADR-040).
"""

from __future__ import annotations

import os
import shutil
import tempfile
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence

import aap_demo
from aap_demo.addons.base import AddonKind
from aap_demo.addons.common.state import enabled_names, set_enabled_names
from aap_demo.addons.product_demos_fleet import NoFleetHostError, discover_fleet_host
from aap_demo.core import prompts
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError, PrerequisiteError
from aap_demo.core.output import is_structured, render

#: ``addons/product-demos/deploy.sh`` writes ``partial <domains>`` to the file
#: named by ``AAP_DEMO_RESULT_FILE`` when the base installed and some domains
#: failed. Its exit code is 1 either way, so only this line marks a partial install.
PARTIAL_MARKER = "partial"

#: Name prefix of the short-lived Galaxy token file in the state directory.
GALAXY_TOKEN_PREFIX = ".galaxy-token."

#: Installers shipped beside this package, and present in a git checkout.
BUNDLED_ADDON_DIRS: tuple = (
    "product-demos",
    "product-demos-base",
    "product-demo-linux",
    "product-demo-windows",
    "product-demo-network",
    "product-demo-cloud",
    "product-demo-openshift",
    "product-demo-satellite",
    "eda-playground",
    "ao",
    "mcp-server",
    "ollama",
)

#: Names ``aap-demo enable`` prints when no addon is given.
PUBLIC_SHELL_ADDONS: tuple = (
    "product-demos",
    "product-demo-satellite",
    "eda-playground",
    "ao",
    "mcp-server",
    "ollama",
)

#: Extra environment for one installer run, worked out before it starts.
Prepare = Callable[[AppContext], Dict[str, str]]


_INSTALLER_TOOLS = ("bash", "curl", "jq")
#: Product-demo delete handlers only need Bash; addons can override this.
_DELETE_TOOLS = ("bash",)


def scripts_root() -> Path:
    """Directory that contains the bundled addon deploy scripts.

    A checkout wins so ``pip install -e`` uses the tree you are editing.
    A wheel falls back to the copy under ``aap_demo/bundled/addons``.
    """
    package = Path(aap_demo.__file__).resolve().parent
    checkout = package.parents[1]
    checkout_addons = checkout / "addons"
    if (checkout / "pyproject.toml").is_file() and (
        checkout_addons / "product-demos" / "deploy.sh"
    ).is_file():
        return checkout_addons
    packaged = package / "bundled" / "addons"
    if (packaged / "product-demos" / "deploy.sh").is_file():
        return packaged
    raise AddonError(
        "addon installers are not included in this aap-demo install",
        hint="Reinstall aap-demo, or run the command from a git checkout.",
    )


def wire_script() -> Path:
    return Path(__file__).resolve().with_name("product_demos_wire.sh")


def ao_script() -> Path:
    """Find AO's installer in a checkout or in the bundled shell runtime."""
    return scripts_root() / "ao" / "deploy.sh"


def _enable_ao(ctx: AppContext, env: Dict[str, str]) -> None:
    from aap_demo.core.migration import parse_legacy_config

    script = ao_script()
    if not script.is_file():
        raise AddonError("Automation Orchestrator installer is not included in this installation")
    ao_env = dict(env)
    legacy = ctx.paths.legacy_config_file
    try:
        saved = parse_legacy_config(legacy.read_text(encoding="utf-8")) if legacy.is_file() else {}
    except OSError as exc:
        raise AddonError("could not read existing AO configuration", hint=str(exc)) from exc
    for key in ("AO_LLM_PROVIDER", "AO_LLM_BASE_URL", "AO_LLM_MODEL"):
        if not ao_env.get(key) and saved.get(key):
            ao_env[key] = saved[key]
    ao_env.setdefault("AO_LLM_PROVIDER", "none")
    ao_env["AAP_DEMO_NAMESPACE"] = ctx.namespace
    ao_env["AAP_DEMO_WIRE_AFTER_DEPLOY"] = "1"
    result = ctx.runner.run(["bash", str(script)], env=ao_env, sink=ctx.console.log_sink())
    if not result.ok:
        raise AddonError(
            "Automation Orchestrator setup failed", hint="Review the installer log and retry."
        )


def require_tools(
    *, delete: bool = False, tools: Optional[Sequence[str]] = None, name: str = ""
) -> None:
    tools = tuple(tools or (_DELETE_TOOLS if delete else _INSTALLER_TOOLS))
    missing = [name for name in tools if shutil.which(name) is None]
    if not missing:
        return
    hint = "Install " + ", ".join(missing) + " and run the command again."
    if "jq" in missing:
        hint += " On macOS: brew install jq"
    label = "product demos" if name == "product-demos" else (name or "the addon")
    raise PrerequisiteError(
        label + " need " + " and ".join(missing),
        hint=hint,
    )


class ShellAddon:
    """A bash installer under ``addons/<name>/deploy.sh``, run by the new command."""

    kind: AddonKind = "legacy"
    needs_cluster = True

    def __init__(
        self,
        name: str,
        *,
        required_tools: Sequence[str] = _INSTALLER_TOOLS,
        delete_tools: Sequence[str] = _DELETE_TOOLS,
        wire_after_enable: bool = True,
        dependencies: Sequence[str] = ("product-demos-base",),
        state_dir_env: Optional[str] = None,
        self_wire: bool = False,
        prepare: Optional[Prepare] = None,
    ) -> None:
        self.name = name
        self.public = name in PUBLIC_SHELL_ADDONS
        self.required_tools = tuple(required_tools)
        self.delete_tools = tuple(delete_tools)
        self.wire_after_enable = wire_after_enable
        self.dependencies = tuple(dependencies)
        self.state_dir_env = state_dir_env
        #: The installer wires itself after a good install (``AAP_DEMO_WIRE_AFTER_DEPLOY=1``).
        self.self_wire = self_wire
        #: Runs before the installer on enable: dependencies first, then extra environment.
        self.prepare = prepare

    def enable(self, ctx: AppContext, args: object) -> int:
        extra = getattr(args, "addon_args", None) or []
        return _run(ctx, self, delete=False, extra=list(extra))

    def disable(self, ctx: AppContext, args: object) -> int:
        del args
        return _run(ctx, self, delete=True, extra=[])


def _run(ctx: AppContext, addon: ShellAddon, *, delete: bool, extra: Sequence[str]) -> int:
    name = addon.name
    require_tools(
        delete=delete,
        tools=addon.delete_tools if delete else addon.required_tools,
        name=name,
    )
    deploy = scripts_root() / addon.name / "deploy.sh"
    if not deploy.is_file():
        raise AddonError(f"addon {name!r} has no deploy.sh")

    extra_env = addon.prepare(ctx) if addon.prepare is not None and not delete else {}
    env = ctx.kube_env()
    env.update(extra_env)
    if name == "product-demos" and not delete:
        try:
            env["AAP_DEMO_FLEET_HOST"] = discover_fleet_host(ctx)
        except NoFleetHostError:
            env.pop("AAP_DEMO_FLEET_HOST", None)
            ctx.console.warn(
                "No ready Fleet host found. To run end-to-end workflows using Fleet, "
                "first run aap-demo enable fleet, then enable product-demos again."
            )
            if not ctx.assume_yes and not ctx.quiet and prompts.can_ask(ctx.env):
                if not prompts.confirm("Continue installing Product Demos without Fleet? [y/N] "):
                    ctx.console.out("Product Demos installation cancelled.")
                    return 0
    env["NAMESPACE"] = ctx.namespace
    # Product demos wire once, after enable, from this module. Addons such as AO
    # wire inside their installer, before steps that need the wiring.
    env["AAP_DEMO_WIRE_AFTER_DEPLOY"] = "1" if addon.self_wire and not delete else "0"
    env["AAP_DEMO_ENABLED_ADDONS"] = " ".join(_enabled(ctx))
    # The global --force reaches installers the way the bash command passed it.
    if ctx.force:
        env["FORCE"] = "1"
    if addon.state_dir_env:
        env[addon.state_dir_env] = str(ctx.paths.state_dir / name)

    argv = ["bash", str(deploy)]
    if delete:
        argv.append("--delete")
    argv.extend(extra)

    result_file = None if delete else _result_file(ctx)
    if result_file is not None:
        env["AAP_DEMO_RESULT_FILE"] = str(result_file)
    try:
        result = ctx.runner.run(argv, env=env, sink=ctx.console.log_sink())
        failed_domains = _partial_domains(result_file) if not result.ok else None
    finally:
        if result_file is not None:
            result_file.unlink(missing_ok=True)
    if failed_domains is not None:
        # The base and some domains are in AAP. Record them so disable and a
        # retry see them, wire the credentials, then report the failure.
        _remember(ctx, name, addon.dependencies)
        if addon.wire_after_enable:
            _wire(ctx, env)
        failed = ", ".join(failed_domains) or "some domains"
        raise AddonError(
            f"{name} installed, and these demo domains failed: {failed}",
            hint=f"Run aap-demo enable {name} again to retry them.",
        )
    if not result.ok:
        action = "disable" if delete else "enable"
        raise AddonError(
            f"aap-demo {action} {name} failed",
            hint="The installer log is above. Fix the reported error and run the command again.",
        )

    if delete:
        _save_enabled(ctx, [item for item in _enabled(ctx) if item != name])
        _say(ctx, f"{name} disabled", addon=name, enabled=False)
        return 0

    previously_enabled = _enabled(ctx)
    _remember(ctx, name, addon.dependencies)
    if addon.wire_after_enable:
        _wire(ctx, env)
    if name == "product-demos" and env.get("AAP_DEMO_FLEET_HOST"):
        try:
            _enable_ao(ctx, env)
        except AddonError:
            if name not in previously_enabled:
                _save_enabled(ctx, [item for item in _enabled(ctx) if item != name])
            raise
    _say(ctx, _enabled_message(name), addon=name, enabled=True)
    return 0


def _result_file(ctx: AppContext) -> Optional[Path]:
    """An empty file the installer can mark. None when the state dir is unusable."""
    try:
        ctx.paths.state_dir.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(dir=str(ctx.paths.state_dir), prefix=".addon-result.")
    except OSError:
        return None
    os.close(fd)
    return Path(name)


def _partial_domains(path: Optional[Path]) -> Optional[List[str]]:
    """Failed domain names when the installer marked a partial install, else None."""
    if path is None:
        return None
    try:
        words = path.read_text(encoding="utf-8").split()
    except OSError:
        return None
    if not words or words[0] != PARTIAL_MARKER:
        return None
    return words[1:]


def _remember(ctx: AppContext, name: str, dependencies: Sequence[str]) -> None:
    """Record the addon and any legacy installers it depends on."""
    current = _enabled(ctx)
    for item in (name, *dependencies):
        if item not in current:
            current.append(item)
    _save_enabled(ctx, current)


def _wire(ctx: AppContext, env: Dict[str, str]) -> None:
    """Point APD credentials at this cluster. A miss here does not undo the install."""
    script = wire_script()
    library = scripts_root() / "product-demos-base" / "lib.sh"
    token_path = _write_galaxy_token(ctx)
    wire_env = dict(env)
    wire_env["AAP_DEMO_ENABLED_ADDONS"] = " ".join(_enabled(ctx))
    if token_path is not None:
        wire_env["GALAXY_TOKEN_FILE"] = str(token_path)
    try:
        result = ctx.runner.run(
            ["bash", str(script), str(library)],
            env=wire_env,
            sink=ctx.console.log_sink(),
        )
    finally:
        if token_path is not None:
            token_path.unlink(missing_ok=True)
    if not result.ok:
        ctx.console.warn(
            "Product demos are installed, and credential wiring did not finish. "
            "Run aap-demo enable again to retry wiring."
        )


def _write_galaxy_token(ctx: AppContext) -> Optional[Path]:
    """A temp file for the installer. The keyring value is not passed on the command line."""
    if ctx.env.get("GALAXY_TOKEN_FILE"):
        return None
    if not ctx.secrets.available():
        return None
    # Imported here, like aap_demo.core.secrets, so startup never loads keyring.
    import keyring.errors

    try:
        token = ctx.secrets.get("galaxy-token")
    except (keyring.errors.KeyringError, PrerequisiteError) as exc:
        # The token is optional. The install has already succeeded.
        ctx.console.warn(
            "Could not read galaxy-token from the credential store "
            f"({type(exc).__name__}). Product demos are installed. "
            "Galaxy credentials were not updated."
        )
        return None
    if not token:
        return None
    data = (token if token.endswith("\n") else token + "\n").encode("utf-8")
    try:
        ctx.paths.state_dir.mkdir(parents=True, exist_ok=True)
        # mkstemp creates the file 0600 with O_EXCL and a random name, so the
        # token is never readable by anyone else, not even for a moment.
        fd, name = tempfile.mkstemp(dir=str(ctx.paths.state_dir), prefix=GALAXY_TOKEN_PREFIX)
    except OSError as exc:
        _token_not_written(ctx, exc)
        return None
    path = Path(name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
    except OSError as exc:
        path.unlink(missing_ok=True)
        _token_not_written(ctx, exc)
        return None
    return path


def _token_not_written(ctx: AppContext, exc: OSError) -> None:
    # The token is optional. The install has already succeeded.
    ctx.console.warn(
        f"Could not write the Galaxy token file ({exc.strerror or type(exc).__name__}). "
        "Product demos are installed. Galaxy credentials were not updated."
    )


def _enabled(ctx: AppContext) -> List[str]:
    return enabled_names(ctx)


def _save_enabled(ctx: AppContext, names: List[str]) -> None:
    set_enabled_names(ctx, names, save=True)


def _enabled_message(name: str) -> str:
    if name == "product-demos":
        return "Product demos installed"
    return f"{name} enabled"


def _say(ctx: AppContext, message: str, **fields: object) -> None:
    if is_structured(ctx.output):
        render(ctx.console, {"message": message, **fields}, output=ctx.output)
        return
    ctx.console.out(message)
