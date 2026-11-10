"""Run a bash addon installer from the new command.

Fleet stays in Python. Product demos still live in ``addons/*/deploy.sh``.
This module runs those scripts with the new command's kubeconfig and records
the result in ``addons.enabled``.
"""

from __future__ import annotations

import os
import shutil
import tempfile
from pathlib import Path
from typing import Dict, List, Optional, Sequence

import aap_demo
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
)

#: Names ``aap-demo enable`` prints when no addon is given.
PUBLIC_SHELL_ADDONS: tuple = ("product-demos", "product-demo-satellite")

SHELL_ADDONS = frozenset(BUNDLED_ADDON_DIRS)

_INSTALLER_TOOLS = ("bash", "curl", "jq")


def scripts_root() -> Path:
    """Directory that contains ``product-demos/deploy.sh``.

    A checkout wins so ``pip install -e`` uses the tree you are editing.
    A wheel falls back to the copy under ``aap_demo/bundled_addons``.
    """
    package = Path(aap_demo.__file__).resolve().parent
    checkout = package.parents[1]
    checkout_addons = checkout / "addons"
    if (checkout / "pyproject.toml").is_file() and (
        checkout_addons / "product-demos" / "deploy.sh"
    ).is_file():
        return checkout_addons
    packaged = package / "bundled_addons"
    if (packaged / "product-demos" / "deploy.sh").is_file():
        return packaged
    raise AddonError(
        "product demos installer is not included in this aap-demo install",
        hint="Reinstall aap-demo, or run ./aap-demo.sh enable product-demos from a git checkout.",
    )


def wire_script() -> Path:
    return Path(__file__).resolve().with_name("product_demos_wire.sh")


def require_tools() -> None:
    missing = [name for name in _INSTALLER_TOOLS if shutil.which(name) is None]
    if not missing:
        return
    hint = "Install " + ", ".join(missing) + " and run the command again."
    if "jq" in missing:
        hint += " On macOS: brew install jq"
    raise PrerequisiteError(
        "product demos need " + " and ".join(missing),
        hint=hint,
    )


class ShellAddon:
    def __init__(self, name: str) -> None:
        self.name = name

    def enable(self, ctx: AppContext, args: object) -> int:
        extra = getattr(args, "addon_args", None) or []
        return _run(ctx, self.name, delete=False, extra=list(extra))

    def disable(self, ctx: AppContext, args: object) -> int:
        del args
        return _run(ctx, self.name, delete=True, extra=[])


def _run(ctx: AppContext, name: str, *, delete: bool, extra: Sequence[str]) -> int:
    require_tools()
    deploy = scripts_root() / name / "deploy.sh"
    if not deploy.is_file():
        raise AddonError(f"addon {name!r} has no deploy.sh")

    env = ctx.kube_env()
    env["NAMESPACE"] = ctx.namespace
    # Bash wires once after enable. Leave the installer's own wiring off so a
    # wheel, which has no includes/addon-wire.sh, still exits 0 after a good install.
    env["AAP_DEMO_WIRE_AFTER_DEPLOY"] = "0"
    env["AAP_DEMO_ENABLED_ADDONS"] = " ".join(_enabled(ctx))

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
        _remember(ctx, name)
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

    _remember(ctx, name)
    _wire(ctx, env)
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


def _remember(ctx: AppContext, name: str) -> None:
    """Record the addon and the base installer it depends on."""
    current = _enabled(ctx)
    for item in (name, "product-demos-base"):
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
    raw = ctx.config.get("addons.enabled") or []
    if not isinstance(raw, list):
        return []
    return [str(name) for name in raw]


def _save_enabled(ctx: AppContext, names: List[str]) -> None:
    ctx.config.set("addons.enabled", names)
    ctx.config.save()


def _enabled_message(name: str) -> str:
    if name == "product-demos":
        return "Product demos installed"
    return f"{name} enabled"


def _say(ctx: AppContext, message: str, **fields: object) -> None:
    if is_structured(ctx.output):
        render(ctx.console, {"message": message, **fields}, output=ctx.output)
        return
    ctx.console.out(message)
