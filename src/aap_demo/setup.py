"""Install and remove the Windows Python CLI from a source checkout.

This module uses only the standard library so the PowerShell bootstrap can run
it before the PyPI package and pipx environment exist.
"""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import shutil
import subprocess
import sys
import sysconfig
from pathlib import Path
from typing import Any, Callable, List, Optional, Sequence, cast

PACKAGE = "aap-demo"
OC_PACKAGE_ID = "RedHat.OpenShift-Client"
PULL_SECRET_URL = "https://console.redhat.com/openshift/install/pull-secret"
MINIMUM_PYTHON = (3, 11)


class SetupError(RuntimeError):
    """An install, rollback, or uninstall operation could not finish safely."""


class SetupManager:
    """Own the Windows pipx install, compatibility shim, and user PATH entry."""

    def __init__(
        self,
        *,
        repo_root: Path,
        home: Path,
        python: str = sys.executable,
        run: Optional[Callable[..., subprocess.CompletedProcess]] = None,
        which: Optional[Callable[[str], Optional[str]]] = None,
        get_user_path: Optional[Callable[[], str]] = None,
        set_user_path: Optional[Callable[[str], None]] = None,
        pipx_scripts_dir: Optional[Path] = None,
        quiet: bool = False,
    ) -> None:
        self.repo_root = repo_root.resolve()
        self.home = home
        self.python = python
        self.run = run or subprocess.run
        self.which = which or shutil.which
        self.get_user_path = get_user_path or _get_user_path
        self.set_user_path = set_user_path or _set_user_path
        self.quiet = quiet
        self.config_dir = home / ".aap-demo"
        configured_bin = os.environ.get("PIPX_BIN_DIR")
        self.bin_dir = (
            Path(configured_bin).expanduser() if configured_bin else home / ".local" / "bin"
        )
        self.pipx_scripts_dir = pipx_scripts_dir
        if self.pipx_scripts_dir is None and os.name == "nt":
            scripts = sysconfig.get_path("scripts", "nt_user")
            self.pipx_scripts_dir = Path(scripts) if scripts else None
        self.repo_marker = self.config_dir / "repo-path"
        self.path_entry_marker = self.config_dir / "local-bin-path-added"
        self._pipx_command: Optional[List[str]] = None
        self._pipx_installed_for_user = False

    @property
    def python_shim(self) -> Path:
        return self.bin_dir / "aap-demo.exe"

    def install(self) -> None:
        """Install ``aap-demo`` through pipx and preserve the Bash v1 fallback."""
        script = self.repo_root / "aap-demo.sh"
        if not script.is_file():
            raise SetupError(f"Run setup from the aap-demo repository (missing {script})")

        self._install_oc_if_available()
        missing = [name for name in ("crc", "oc") if not self.which(name)]
        if missing:
            joined = ", ".join(missing)
            raise SetupError(
                f"Missing required tools: {joined}. "
                "Install OpenShift Local (crc) and oc, then retry."
            )

        self._ensure_pipx()
        self._refresh_pipx_bin_dir()
        if self._pipx_has_aap_demo():
            self._run([*self._pipx(), "upgrade", PACKAGE])
        else:
            self._run([*self._pipx(), "install", "--python", self.python, PACKAGE])

        self.config_dir.mkdir(parents=True, exist_ok=True)
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self._write_repo_marker()
        self._remove_python_wrappers()
        self._write_v1_shim()
        self._ensure_launcher_path()
        self._report_optional_tools()
        self._report_pull_secret()
        self._info("Python aap-demo installed from PyPI with pipx")

    def uninstall(self) -> None:
        """Remove launchers and the pipx package while preserving user data."""
        self._uninstall_python_cli()
        self._remove_python_wrappers()
        for directory in self._launcher_dirs():
            (directory / "aap-demo-v1.cmd").unlink(missing_ok=True)
        self.repo_marker.unlink(missing_ok=True)
        if self.path_entry_marker.is_file():
            self._remove_launcher_path()
            self.path_entry_marker.unlink(missing_ok=True)
        self._info("Removed the Python CLI and launchers; cluster and config data were preserved")

    def rollback_to_v1(self) -> None:
        """Restore the Bash v1 launcher before uninstalling the Python package."""
        if not self.repo_marker.is_file():
            raise SetupError("Cannot roll back: the registered Bash repository path is missing")
        registered = Path(self.repo_marker.read_text(encoding="utf-8").strip())
        script = registered / "aap-demo.sh"
        if not script.is_file():
            raise SetupError(f"Cannot roll back: aap-demo.sh was not found under {registered}")

        try:
            self._refresh_pipx_bin_dir()
        except SetupError:
            if not self.python_shim.exists():
                raise
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self._write_v1_shim()
        self._remove_python_wrappers()
        default = self.bin_dir / "aap-demo.cmd"
        default.write_text(
            '@echo off\r\ncall "%~dp0aap-demo-v1.cmd" %*\r\nexit /b %ERRORLEVEL%\r\n',
            encoding="ascii",
        )
        self._uninstall_python_cli(bin_dir_resolved=True)
        self._ensure_launcher_path()
        self._info("Rolled back the default command to the registered Bash checkout")

    def _install_oc_if_available(self) -> None:
        if self.which("oc"):
            self._info("oc already on PATH")
            return
        winget = self.which("winget")
        if not winget:
            return
        self._info("Installing oc with winget")
        self._run(
            [
                winget,
                "install",
                "--id",
                OC_PACKAGE_ID,
                "-e",
                "--source",
                "winget",
                "--accept-package-agreements",
                "--accept-source-agreements",
                "--disable-interactivity",
            ]
        )
        self._refresh_path()

    def _refresh_path(self) -> None:
        """Expose PATH entries added by winget to this Python process."""
        if os.name != "nt":
            return
        import winreg

        registry: Any = winreg
        registered_paths = []
        for hive, key_name in (
            (
                registry.HKEY_LOCAL_MACHINE,
                r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment",
            ),
            (registry.HKEY_CURRENT_USER, "Environment"),
        ):
            try:
                with registry.OpenKey(hive, key_name) as key:
                    value, _kind = registry.QueryValueEx(key, "Path")
            except OSError:
                continue
            if isinstance(value, str):
                registered_paths.append(value)

        # Keep transient entries as well (for example the selected Python's
        # Scripts directory), but put newly registered locations first.
        entries = _split_path(";".join((*registered_paths, os.environ.get("PATH", ""))))
        refreshed = []
        seen = set()
        for entry in entries:
            normalized = _normalize_path(entry)
            if normalized not in seen:
                refreshed.append(os.path.expandvars(entry))
                seen.add(normalized)
        os.environ["PATH"] = ";".join(refreshed)

    def _ensure_pipx(self) -> None:
        pipx = self.which("pipx")
        if pipx:
            self._pipx_command = [pipx]
            return
        self._info("Installing pipx with the selected Python runtime")
        self._pipx_installed_for_user = True
        self._run(
            [
                self.python,
                "-m",
                "pip",
                "install",
                "--user",
                "pipx",
                "--disable-pip-version-check",
            ]
        )
        self._pipx_command = [self.python, "-m", "pipx"]

    def _refresh_pipx_bin_dir(self) -> None:
        result = self._run(
            [*self._pipx(), "environment", "--value", "PIPX_BIN_DIR"],
            show_output=False,
        )
        value = (result.stdout or "").strip()
        if value:
            self.bin_dir = Path(os.path.expandvars(value)).expanduser().resolve()

    def _pipx_has_aap_demo(self) -> bool:
        result = self._run([*self._pipx(), "list", "--json"], show_output=False)
        try:
            payload = json.loads(result.stdout or "{}")
        except json.JSONDecodeError as exc:
            raise SetupError("pipx did not return a valid package list") from exc
        venvs = payload.get("venvs", {}) if isinstance(payload, dict) else {}
        if not isinstance(venvs, dict):
            return False
        return PACKAGE in venvs

    def _write_repo_marker(self) -> None:
        """Atomically register the checkout path using a Unicode-safe encoding."""
        self.config_dir.mkdir(parents=True, exist_ok=True)
        temporary = self.repo_marker.with_suffix(".tmp")
        temporary.write_text(str(self.repo_root), encoding="utf-8")
        temporary.replace(self.repo_marker)

    def _pipx(self) -> List[str]:
        if self._pipx_command is None:
            pipx = self.which("pipx")
            if pipx:
                self._pipx_command = [pipx]
            else:
                self._pipx_command = [self.python, "-m", "pipx"]
        return self._pipx_command

    def _uninstall_python_cli(self, *, bin_dir_resolved: bool = False) -> None:
        pipx = self.which("pipx")
        command = [pipx] if pipx else [self.python, "-m", "pipx"]
        self._pipx_command = command
        if not bin_dir_resolved:
            try:
                self._refresh_pipx_bin_dir()
            except SetupError:
                if not self.python_shim.exists():
                    return
                raise
        if not self._pipx_has_aap_demo():
            return
        self._run([*self._pipx(), "uninstall", PACKAGE])
        if self.python_shim.exists():
            raise SetupError("pipx did not remove the aap-demo launcher")

    def _run(self, argv: Sequence[str], *, show_output: bool = True) -> subprocess.CompletedProcess:
        try:
            result = self.run(list(argv), capture_output=True, text=True, check=False)
        except OSError as exc:
            raise SetupError(f"Could not run {argv[0]}: {exc}") from exc
        if result.returncode:
            detail = (result.stderr or result.stdout or "").strip()
            suffix = f": {detail}" if detail else ""
            raise SetupError(f"Command failed ({result.returncode}): {' '.join(argv)}{suffix}")
        if result.stdout and not self.quiet and show_output:
            print(result.stdout.rstrip())
        return result

    def _ensure_launcher_path(self) -> None:
        entries = _split_path(self.get_user_path())
        normalized = {_normalize_path(entry) for entry in entries}
        added = []
        bin_dir = self.bin_dir.expanduser().resolve()
        if _normalize_path(str(bin_dir)) not in normalized:
            entries.append(str(bin_dir))
            added.append(bin_dir)
            normalized.add(_normalize_path(str(bin_dir)))

        scripts_dir = None
        if self._pipx_installed_for_user and self.pipx_scripts_dir is not None:
            scripts_dir = self.pipx_scripts_dir.expanduser().resolve()
            if _normalize_path(str(scripts_dir)) not in normalized:
                entries.append(str(scripts_dir))
                added.append(scripts_dir)

        if not added:
            self._info("User PATH already contains the pipx app directory")
            return

        self.set_user_path(";".join(entries))
        os.environ["PATH"] = ";".join(entries)
        self.config_dir.mkdir(parents=True, exist_ok=True)
        if bin_dir in added:
            owned = self._owned_launcher_paths()
            if _normalize_path(str(bin_dir)) not in {_normalize_path(path) for path in owned}:
                owned.append(str(bin_dir))
            self.path_entry_marker.write_text("\n".join(owned) + "\n", encoding="utf-8")
            self._info(f"Added {bin_dir} to user PATH")
        if scripts_dir is not None and scripts_dir in added:
            self._info("Added the Python user Scripts directory so pipx can be run directly")
        self._refresh_path()

    def _remove_launcher_path(self) -> None:
        normalized = {_normalize_path(path) for path in self._owned_launcher_paths()}
        entries = [
            entry
            for entry in _split_path(self.get_user_path())
            if _normalize_path(entry) not in normalized
        ]
        self.set_user_path(";".join(entries))
        self._refresh_path()

    def _owned_launcher_paths(self) -> List[str]:
        """Read PATH entries this installer added, including the old marker format."""
        if not self.path_entry_marker.is_file():
            return []
        value = self.path_entry_marker.read_text(encoding="utf-8").strip()
        if value in {"added-by-aap-demo-installer", "added"}:
            return [str((self.home / ".local" / "bin").expanduser().resolve())]
        return [line.strip() for line in value.splitlines() if line.strip()]

    def _write_v1_shim(self) -> None:
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        shim = self.bin_dir / "aap-demo-v1.cmd"
        bash = self._find_git_bash()
        bash_line = f'set "AAP_DEMO_BASH={bash or ""}"'
        lines = [
            "@echo off",
            "setlocal",
            "chcp 65001 >nul",
            bash_line,
            'set "AAP_DEMO_REPO="',
            'for /f "usebackq delims=" %%R in ("%USERPROFILE%\\.aap-demo\\repo-path") '
            'do set "AAP_DEMO_REPO=%%R"',
            "if not defined AAP_DEMO_REPO (",
            "  echo aap-demo-v1 is not installed: missing %USERPROFILE%\\.aap-demo\\repo-path 1>&2",
            "  exit /b 1",
            ")",
            "if not defined AAP_DEMO_BASH (",
            "  echo Git Bash is required for v1; install Git for Windows. 1>&2",
            "  exit /b 1",
            ")",
            '"%AAP_DEMO_BASH%" "%AAP_DEMO_REPO%\\aap-demo.sh" %*',
            "exit /b %ERRORLEVEL%",
            "",
        ]
        shim.write_text("\r\n".join(lines), encoding="utf-8")

    def _find_git_bash(self, *, windows: Optional[bool] = None) -> Optional[str]:
        is_windows = os.name == "nt" if windows is None else windows
        if not is_windows:
            return self.which("bash")
        candidates: List[Path] = []
        for root in (
            os.environ.get("ProgramFiles"),
            os.environ.get("ProgramFiles(x86)"),
            os.environ.get("LOCALAPPDATA"),
        ):
            if root:
                base = Path(root)
                candidates.extend(
                    (
                        base / "Git" / "bin" / "bash.exe",
                        base / "Programs" / "Git" / "bin" / "bash.exe",
                    )
                )
        git = self.which("git")
        if git:
            git_path = Path(git)
            candidates.extend(
                (git_path.parent / "bash.exe", git_path.parent.parent / "bin" / "bash.exe")
            )
        for name in ("bash.exe", "bash"):
            candidate = self.which(name)
            if candidate:
                candidates.append(Path(candidate))
        for candidate in candidates:
            if not candidate:
                continue
            path = Path(candidate)
            normalized = str(path).replace("/", "\\").lower()
            if is_windows and normalized.endswith("\\windows\\system32\\bash.exe"):
                continue
            if path.is_file():
                return str(path.resolve())
        return None

    def _remove_python_wrappers(self) -> None:
        for directory in self._launcher_dirs():
            for name in ("aap-demo.ps1", "aap-demo.cmd"):
                (directory / name).unlink(missing_ok=True)

    def _launcher_dirs(self) -> List[Path]:
        """Include the old default launcher directory during custom pipx moves."""
        directories = (self.bin_dir, self.home / ".local" / "bin")
        return list(dict.fromkeys(path.expanduser().resolve() for path in directories))

    def _report_optional_tools(self) -> None:
        missing = []
        if not self._find_git_bash():
            missing.append("Git Bash")
        if not self.which("jq"):
            missing.append("jq")
        if missing and not self.quiet:
            print("Optional tools not found (shell-backed legacy commands may need them):")
            for name in missing:
                print(f"  - {name}")

    def _report_pull_secret(self) -> None:
        for name in ("pull-secret.txt", "pull-secret.json", "pull-secret"):
            path = self.config_dir / name
            if path.is_file():
                self._info(f"Pull secret found: {path}")
                return
        if not self.quiet:
            print("No pull secret found. Download one from:")  # pragma: allowlist secret
            print(f"  {PULL_SECRET_URL}")
            print(f"Save it under {self.config_dir}\\pull-secret.txt")

    def _info(self, message: str) -> None:
        if not self.quiet:
            print(message)


def _split_path(value: str) -> List[str]:
    return [entry for entry in value.split(";") if entry.strip()]


def _normalize_path(value: str) -> str:
    expanded = os.path.expandvars(value.strip().strip('"'))
    return os.path.normcase(os.path.normpath(os.path.abspath(expanded)))


def _get_user_path() -> str:
    if os.name != "nt":
        return os.environ.get("PATH", "")
    import winreg

    registry: Any = winreg
    try:
        with registry.OpenKey(registry.HKEY_CURRENT_USER, "Environment") as key:
            value, _kind = registry.QueryValueEx(key, "Path")
            return str(value)
    except FileNotFoundError:
        return ""


def _set_user_path(value: str) -> None:
    if os.name != "nt":
        raise SetupError("Changing the user PATH is supported only on Windows")
    import winreg

    registry: Any = winreg
    with registry.CreateKey(registry.HKEY_CURRENT_USER, "Environment") as key:
        try:
            _existing, kind = registry.QueryValueEx(key, "Path")
        except FileNotFoundError:
            kind = registry.REG_EXPAND_SZ
        registry.SetValueEx(key, "Path", 0, kind, value)
    try:
        # Refresh Explorer and other applications that cache the user PATH.
        HWND_BROADCAST = 0xFFFF
        WM_SETTINGCHANGE = 0x001A
        SMTO_ABORTIFHUNG = 0x0002
        user32: Any = cast(Any, ctypes).windll.user32
        send_message = user32.SendMessageTimeoutW
        send_message.argtypes = (
            ctypes.c_void_p,
            ctypes.c_uint,
            ctypes.c_size_t,
            ctypes.c_wchar_p,
            ctypes.c_uint,
            ctypes.c_uint,
            ctypes.POINTER(ctypes.c_size_t),
        )
        send_message.restype = ctypes.c_ssize_t
        message_result = ctypes.c_size_t()
        send_message(
            HWND_BROADCAST,
            WM_SETTINGCHANGE,
            0,
            "Environment",
            SMTO_ABORTIFHUNG,
            5000,
            ctypes.byref(message_result),
        )
    except (AttributeError, OSError, ctypes.ArgumentError):
        # PATH is still persisted; a new shell will read it even if the
        # broadcast cannot be delivered from this session.
        pass


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Install the Windows aap-demo Python CLI")
    parser.add_argument("action", choices=("install", "uninstall", "rollback-to-v1"))
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)
    if sys.version_info < MINIMUM_PYTHON:
        print("Windows setup requires Python 3.11+ to install and manage pipx", file=sys.stderr)
        return 1
    manager = SetupManager(
        repo_root=args.repo_root,
        home=Path.home(),
        quiet=args.quiet,
    )
    try:
        if args.action == "install":
            manager.install()
        elif args.action == "uninstall":
            manager.uninstall()
        else:
            manager.rollback_to_v1()
    except SetupError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
