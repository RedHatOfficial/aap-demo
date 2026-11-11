#!/usr/bin/env python3
"""Local-only aap-demo dashboard server."""

from __future__ import annotations

import argparse
import base64
import errno
import json
import os
import platform
import queue
import re
import secrets
import select
import signal
import subprocess
import sys
import threading
import time
import webbrowser
from dataclasses import dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.error import URLError
from urllib.parse import urlparse
from urllib.request import ProxyHandler, build_opener

HOST = "127.0.0.1"
DEFAULT_PORT = 8765
MAX_BODY_BYTES = 4096
OPERATION_TIMEOUT_SECONDS = 3600
TERMINAL_IDLE_SECONDS = 300
# aap-demo status --json takes ~30s against a settling MicroShift cluster. A
# TTL shorter than that makes every auto-refresh re-run the full collection and
# queue behind the in-flight one, so the UI sits on a stale/empty payload.
INVENTORY_CACHE_TTL_SECONDS = 30


class FleetTerminal:
    """One bounded SSH PTY; the browser never receives the key or login password."""

    def __init__(self, root: Path, port: int) -> None:
        if os.name != "posix":
            raise RuntimeError("Browser SSH requires a Linux or macOS dashboard host")
        import pty

        self.lock = threading.Lock()
        self.last_used = time.monotonic()
        self.master, slave = pty.openpty()
        try:
            self.process = subprocess.Popen(
                [
                    "ssh", "-tt", "-p", str(port), "-i", str(root / "ssh_key"),
                    "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                    "-o", "StrictHostKeyChecking=yes",
                    "-o", f"UserKnownHostsFile={root / 'known_hosts'}",
                    "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=30",
                    "-o", "ServerAliveCountMax=3", "admin@127.0.0.1",
                ],
                stdin=slave, stdout=slave, stderr=slave,
                start_new_session=True,
                env={**os.environ, "TERM": "xterm-256color"},
            )
        except OSError:
            os.close(self.master)
            raise
        finally:
            os.close(slave)
        os.set_blocking(self.master, False)
        self.closed = False

    def exchange(self, data: str, cols: int, rows: int) -> dict[str, Any]:
        import fcntl
        import struct
        import termios

        with self.lock:
            if self.closed:
                raise RuntimeError("Terminal session has closed")
            self.last_used = time.monotonic()
            fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
            incoming = data.encode("utf-8")
            if incoming:
                written = os.write(self.master, incoming)
                if written != len(incoming):
                    raise RuntimeError("Terminal input was not fully delivered; reconnect")
            output = bytearray()
            while len(output) < 65536 and select.select([self.master], [], [], 0)[0]:
                try:
                    chunk = os.read(self.master, 4096)
                except OSError as error:
                    if error.errno == errno.EIO:  # A terminated PTY reports EIO on Linux.
                        break
                    raise
                if not chunk:
                    break
                output.extend(chunk)
            return {
                "output": base64.b64encode(output).decode("ascii"),
                "exited": self.process.poll() is not None and len(output) < 65536,
            }

    def close(self) -> None:
        with self.lock:
            if self.closed:
                return
            self.closed = True
            if self.process.poll() is None:
                try:
                    os.killpg(self.process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass  # SSH can exit between poll() and signalling its process group.
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(self.process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    self.process.wait(timeout=2)
            os.close(self.master)


def load_catalog(repo_root: Path) -> dict[str, Any]:
    path = repo_root / "config" / "addons-dashboard.json"
    with path.open(encoding="utf-8") as stream:
        catalog = json.load(stream)
    addons = catalog.get("addons")
    if catalog.get("schema_version") != 1 or not isinstance(addons, list):
        raise ValueError(f"Invalid dashboard add-on catalog: {path}")
    ids = [addon.get("id") for addon in addons]
    if any(not isinstance(addon_id, str) for addon_id in ids) or len(ids) != len(set(ids)):
        raise ValueError(f"Dashboard add-on IDs must be unique strings: {path}")
    return catalog


def value_at_path(document: dict[str, Any], path: list[str]) -> Any:
    value: Any = document
    for key in path:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def active_dependencies(addon: dict[str, Any], inventory: dict[str, Any]) -> list[str]:
    active: list[str] = []
    for dependency in addon.get("dependencies", []):
        condition = dependency.get("when")
        if condition and value_at_path(inventory, condition["path"]) != condition["equals"]:
            continue
        active.append(dependency["id"])
    return active


def addon_state(addon: dict[str, Any], inventory: dict[str, Any]) -> str:
    if addon["id"] not in inventory.get("addons", []):
        return "disabled"
    health = addon.get("health", {"type": "configured"})
    if health["type"] == "configured":
        return "enabled"
    pods = inventory.get("pods", [])
    if health["type"] == "namespace":
        matches = [pod for pod in pods if pod.get("namespace") == health["namespace"]]
    elif health["type"] == "pod-prefix":
        matches = [
            pod
            for pod in pods
            if pod.get("namespace") == health["namespace"]
            and pod.get("name", "").startswith(health["prefix"])
        ]
    else:
        return "unknown"
    if not matches:
        return "degraded"
    # Completed pods are finished jobs (migrations, setup), not unhealthy
    # workloads — exclude them from the readiness check so a namespace with
    # running services plus completed jobs is not reported as degraded.
    active = [pod for pod in matches if pod.get("phase") != "Completed"]
    if not active:
        return "degraded"
    if all(
        pod.get("phase") == "Running"
        and pod.get("ready_containers") == pod.get("total_containers")
        for pod in active
    ):
        return "running"
    return "degraded"


def redact_output(output: str) -> str:
    patterns = [
        (re.compile(r"(?i)(authorization:\s*bearer\s+)\S+"), r"\1******"),
        (re.compile(r"(?i)(password\s*[:=]\s*)\S+"), r"\1******"),
        (re.compile(r"(?i)(token\s*[:=]\s*)\S+"), r"\1******"),
        (re.compile(r"(?i)(admin\s*/\s*)\S+"), r"\1******"),
    ]
    redacted = output
    for pattern, replacement in patterns:
        redacted = pattern.sub(replacement, redacted)
    return redacted[-12000:]


@dataclass
class OperationState:
    lock: threading.Lock = field(default_factory=threading.Lock)
    operation_id: str | None = None
    addon: str | None = None
    action: str | None = None
    status: str = "idle"
    message: str = ""
    output: str = ""
    started_at: float | None = None
    completed_at: float | None = None

    def snapshot(self) -> dict[str, Any]:
        with self.lock:
            return {
                "id": self.operation_id,
                "addon": self.addon,
                "action": self.action,
                "status": self.status,
                "message": self.message,
                "output": self.output,
                "started_at": self.started_at,
                "completed_at": self.completed_at,
            }


class DashboardApp:
    def __init__(self, repo_root: Path, port: int) -> None:
        self.repo_root = repo_root
        self.port = port
        self.origin = f"http://{HOST}:{port}"
        self.session_token = secrets.token_urlsafe(32)
        self.instance_id = secrets.token_hex(12)
        self.catalog = load_catalog(repo_root)
        self.addons = {addon["id"]: addon for addon in self.catalog["addons"]}
        self.operation = OperationState()
        self.restart_requested = False
        self.cli = repo_root / "aap-demo.sh"
        self.static_dir = repo_root / "dashboard" / "static"
        self.terminals: dict[str, FleetTerminal] = {}
        self.terminal_lock = threading.Lock()
        # Short-TTL cache for the status inventory. `aap-demo status --json`
        # shells out to system-inventory.sh (many kubectl calls, ~5s), and the
        # dashboard calls inventory() several times per page load and poll, so
        # caching for a few seconds avoids redundant cluster round-trips while
        # keeping the data effectively live.
        self._inventory_cache: dict[str, Any] | None = None
        self._inventory_cache_at = 0.0
        self._inventory_lock = threading.Lock()

    def reap_terminals(self, *, all_sessions: bool = False) -> None:
        with self.terminal_lock:
            for session_id, terminal in list(self.terminals.items()):
                if all_sessions or time.monotonic() - terminal.last_used > TERMINAL_IDLE_SECONDS:
                    terminal.close()
                    del self.terminals[session_id]

    def start_terminal(self, index: int) -> str:
        self.reap_terminals()
        root = Path(os.environ.get("AAP_DEMO_DIR", Path.home() / ".aap-demo")) / "fleet"
        nodes = self.inventory().get("fleet", [])
        node = next((node for node in nodes if node.get("index") == index), None)
        if node is None or node.get("state") != "running":
            raise RuntimeError("Fleet node is missing or stopped")
        port = node.get("ssh_port")
        if not isinstance(port, int) or not 1 <= port <= 65535:
            raise RuntimeError("Fleet node has an invalid SSH port")
        if not (root / "ssh_key").is_file() or not (root / "known_hosts").is_file():
            raise RuntimeError("Fleet SSH access is not configured; run 'aap-demo fleet register'")
        if not (self.repo_root / "dashboard/node_modules/@xterm/xterm/lib/xterm.js").is_file():
            raise RuntimeError("Browser terminal assets are missing; run 'npm ci --prefix dashboard'")
        with self.terminal_lock:
            if len(self.terminals) >= 4:
                raise RuntimeError("At most four browser terminals may be open; close a session first")
            session_id = secrets.token_hex(16)
            self.terminals[session_id] = FleetTerminal(root, port)
        return session_id

    def terminal_io(self, session_id: str, body: dict[str, Any]) -> dict[str, Any]:
        self.reap_terminals()
        with self.terminal_lock:
            terminal = self.terminals.get(session_id)
            if terminal is None:
                raise RuntimeError("Terminal session expired; reconnect")
            if body.get("close") is True:
                terminal.close()
                del self.terminals[session_id]
                return {"closed": True}
            data = body.get("data", "")
            cols, rows = body.get("cols", 80), body.get("rows", 24)
            if not isinstance(data, str) or len(data.encode("utf-8")) > 2048:
                raise ValueError("Terminal input must be at most 2048 bytes")
            if type(cols) is not int or type(rows) is not int or not 2 <= cols <= 500 or not 2 <= rows <= 200:
                raise ValueError("Invalid terminal dimensions")
            return terminal.exchange(data, cols, rows)

    def run_cli(self, *arguments: str, timeout: int = 120) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            self.cli_command(*arguments),
            cwd=self.repo_root,
            env=self.command_environment(),
            capture_output=True,
            text=True,
            encoding="utf-8" if sys.platform == "win32" else None,
            timeout=timeout,
            check=False,
        )

    def fleet_power(self, index: int, action: str) -> dict[str, Any]:
        if action not in ("start", "stop", "restart"):
            raise ValueError("Invalid fleet power action")
        nodes = self.inventory().get("fleet", [])
        node = next((node for node in nodes if node.get("index") == index), None)
        if node is None:
            raise RuntimeError(f"Fleet node {index} does not exist")
        # A node start waits for SSH readiness, which can take a while.
        timeout = 180 if action in ("start", "restart") else 60
        result = self.run_cli("fleet", "node", str(index), action, timeout=timeout)
        if result.returncode != 0:
            detail = redact_output(result.stderr or result.stdout).strip()
            raise RuntimeError(detail or f"fleet node {index} {action} failed")
        self.invalidate_inventory()
        return {"index": index, "action": action, "status": "ok"}

    def cli_command(self, *arguments: str) -> list[str]:
        if sys.platform == "win32":
            return [
                "powershell.exe", "-NoProfile", "-NonInteractive",
                "-ExecutionPolicy", "Bypass", "-File",
                str(self.repo_root / "powershell" / "aap-demo.ps1"), *arguments,
            ]
        return [str(self.cli), *arguments]

    @staticmethod
    def command_environment() -> dict[str, str]:
        environment = os.environ.copy()
        environment.update(
            {
                "QUIET": "true",
                "AAP_DEMO_NOTICE_SHOWN": "1",
            }
        )
        if sys.platform == "win32":
            environment["AAP_DEMO_DASHBOARD_COMMAND"] = "1"
        return environment

    def inventory(self) -> dict[str, Any]:
        with self._inventory_lock:
            now = time.monotonic()
            if (
                self._inventory_cache is not None
                and now - self._inventory_cache_at < INVENTORY_CACHE_TTL_SECONDS
            ):
                return self._inventory_cache
            result = self.run_cli("status", "--json")
            if result.returncode != 0:
                detail = redact_output(result.stderr or result.stdout).strip()
                raise RuntimeError(detail or "Unable to collect aap-demo status")
            self._inventory_cache = json.loads(result.stdout)
            self._inventory_cache_at = now
            return self._inventory_cache

    def invalidate_inventory(self) -> None:
        with self._inventory_lock:
            self._inventory_cache = None
            self._inventory_cache_at = 0.0

    def status_payload(self) -> dict[str, Any]:
        inventory = self.inventory()
        host = inventory.setdefault("host", {})
        if not host.get("os") or host["os"] == "unknown":
            host["os"] = f"{platform.system()} {platform.release()}"
        enabled = set(inventory.get("addons", []))
        addons = []
        for definition in self.catalog["addons"]:
            addon = dict(definition)
            supported = inventory.get("supported_addons")
            addon["supported"] = supported is None or definition["id"] in supported
            if not addon["supported"]:
                addon["availability"] = "Not supported by native Windows PowerShell"
            addon["state"] = addon_state(definition, inventory)
            addon["enabled"] = definition["id"] in enabled
            addon["active_dependencies"] = active_dependencies(definition, inventory)
            capacity = inventory.get("storage", {}).get("capacity_planning", {})
            addon["capacity_estimate"] = capacity.get("addon_estimates", {}).get(
                definition["id"], {}
            )
            addon["projected_vm_disk_gib"] = capacity.get(
                "projected_vm_disk_gib", {}
            ).get(definition["id"])
            addons.append(addon)
        return {
            "inventory": inventory,
            "addons": addons,
            "operation": self.operation.snapshot(),
        }

    def dependent_addons(self, addon_id: str, inventory: dict[str, Any]) -> list[str]:
        enabled = set(inventory.get("addons", []))
        return [
            definition["id"]
            for definition in self.catalog["addons"]
            if definition["id"] in enabled
            and addon_id in active_dependencies(definition, inventory)
        ]

    def start_operation(self, addon_id: str, action: str) -> dict[str, Any]:
        if sys.platform == "win32" and addon_id not in self.inventory().get("supported_addons", []):
            raise RuntimeError(f"Add-on '{addon_id}' is not supported by native Windows PowerShell")
        with self.operation.lock:
            if self.restart_requested:
                raise RuntimeError("The dashboard is restarting")
            if self.operation.status == "running":
                raise RuntimeError("Another dashboard operation is already running")
            operation_id = secrets.token_hex(8)
            self.operation.operation_id = operation_id
            self.operation.addon = addon_id
            self.operation.action = action
            self.operation.status = "running"
            self.operation.message = f"{action.title()}ing {addon_id}"
            self.operation.output = ""
            self.operation.started_at = time.time()
            self.operation.completed_at = None
        thread = threading.Thread(
            target=self._execute_operation,
            args=(operation_id, addon_id, action),
            daemon=True,
        )
        thread.start()
        return self.operation.snapshot()

    def request_restart(self) -> None:
        with self.operation.lock:
            if self.operation.status == "running":
                raise RuntimeError("Wait for the current add-on operation before restarting the dashboard")
            if self.restart_requested:
                raise RuntimeError("The dashboard is already restarting")
            self.restart_requested = True

    def _execute_operation(self, operation_id: str, addon_id: str, action: str) -> None:
        process: subprocess.Popen[str] | None = None
        output_lines: list[str] = []
        try:
            process = subprocess.Popen(
                self.cli_command(action, addon_id),
                cwd=self.repo_root,
                env=self.command_environment(),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8" if sys.platform == "win32" else None,
                bufsize=1,
            )
            output_queue: queue.Queue[str | None] = queue.Queue()

            def read_output() -> None:
                assert process and process.stdout
                for line in process.stdout:
                    output_queue.put(line)
                output_queue.put(None)

            reader = threading.Thread(target=read_output, daemon=True)
            reader.start()
            deadline = time.monotonic() + OPERATION_TIMEOUT_SECONDS
            output_complete = False
            timed_out = False
            while process.poll() is None or not output_complete:
                if time.monotonic() >= deadline:
                    timed_out = True
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                    break
                try:
                    item = output_queue.get(timeout=0.25)
                except queue.Empty:
                    continue
                if item is None:
                    output_complete = True
                    continue
                output_lines.append(item)
                current_output = redact_output("".join(output_lines))
                with self.operation.lock:
                    if self.operation.operation_id == operation_id:
                        self.operation.output = current_output

            reader.join(timeout=2)
            while not output_queue.empty():
                item = output_queue.get_nowait()
                if item is not None:
                    output_lines.append(item)
            if process.stdout:
                process.stdout.close()
            return_code = process.wait()
            combined = "".join(output_lines)
            success = return_code == 0 and not timed_out
            message = (
                f"{addon_id} {action} completed"
                if success
                else (
                    f"{addon_id} {action} timed out"
                    if timed_out
                    else f"{addon_id} {action} failed with exit code {return_code}"
                )
            )
            status = "succeeded" if success else "failed"
        except Exception as error:  # surfaced through the operation endpoint
            if process and process.poll() is None:
                process.terminate()
            combined = str(error)
            message = f"{addon_id} {action} failed"
            status = "failed"
        with self.operation.lock:
            if self.operation.operation_id != operation_id:
                return
            self.operation.status = status
            self.operation.message = message
            self.operation.output = redact_output(combined)
            self.operation.completed_at = time.time()
        # An addon enable/disable changes the inventory; drop the cache so the
        # next status poll reflects it.
        self.invalidate_inventory()


def create_handler(app: DashboardApp) -> type[BaseHTTPRequestHandler]:
    class DashboardHandler(BaseHTTPRequestHandler):
        server_version = "aap-demo-dashboard/1"

        def valid_host(self) -> bool:
            if self.headers.get("Host") == f"{HOST}:{app.port}":
                return True
            self.json_response(HTTPStatus.FORBIDDEN, {"error": "Invalid request host"})
            return False

        def log_message(self, format_string: str, *args: object) -> None:
            if re.fullmatch(r"/api/terminals/[a-f0-9]{32}/io", urlparse(self.path).path) and len(args) > 1 and str(args[1]) == "200":
                return
            print(f"[dashboard] {self.address_string()} {format_string % args}")

        def end_headers(self) -> None:
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Referrer-Policy", "no-referrer")
            # xterm computes inline cell geometry; only the terminal page needs this allowance.
            style_policy = "'self' 'unsafe-inline'" if urlparse(self.path).path == "/terminal" else "'self'"
            self.send_header(
                "Content-Security-Policy",
                f"default-src 'self'; style-src {style_policy}; script-src 'self'; "
                "connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'",
            )
            super().end_headers()

        def json_response(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def file_response(self, path: Path, content_type: str) -> None:
            if not path.is_file():
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            body = path.read_bytes()
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            if not self.valid_host():
                return
            path = urlparse(self.path).path
            if path == "/":
                self.file_response(app.static_dir / "index.html", "text/html; charset=utf-8")
            elif path == "/app.css":
                self.file_response(app.static_dir / "app.css", "text/css; charset=utf-8")
            elif path == "/app.js":
                self.file_response(app.static_dir / "app.js", "text/javascript; charset=utf-8")
            elif path == "/terminal":
                self.file_response(app.static_dir / "terminal.html", "text/html; charset=utf-8")
            elif path == "/terminal.js":
                self.file_response(app.static_dir / "terminal.js", "text/javascript; charset=utf-8")
            elif path in ("/vendor/xterm.js", "/vendor/xterm.css", "/vendor/addon-fit.js"):
                assets = {
                    "/vendor/xterm.js": ("@xterm/xterm/lib/xterm.js", "text/javascript"),
                    "/vendor/xterm.css": ("@xterm/xterm/css/xterm.css", "text/css"),
                    "/vendor/addon-fit.js": ("@xterm/addon-fit/lib/addon-fit.js", "text/javascript"),
                }
                asset, content_type = assets[path]
                self.file_response(app.repo_root / "dashboard/node_modules" / asset, content_type)
            elif path == "/api/session":
                self.json_response(HTTPStatus.OK, {"token": app.session_token})
            elif path == "/api/health":
                self.json_response(HTTPStatus.OK, {
                    "service": "aap-demo-dashboard",
                    "repo_root": str(app.repo_root),
                    "pid": os.getpid(),
                    "instance": app.instance_id,
                })
            elif path == "/api/status":
                try:
                    self.json_response(HTTPStatus.OK, app.status_payload())
                except Exception as error:
                    self.json_response(
                        HTTPStatus.SERVICE_UNAVAILABLE,
                        {"error": str(error)},
                    )
            elif path == "/api/operation":
                self.json_response(HTTPStatus.OK, app.operation.snapshot())
            else:
                self.send_error(HTTPStatus.NOT_FOUND)

        def do_POST(self) -> None:  # noqa: N802
            if not self.valid_host():
                return
            if self.headers.get("Origin") != app.origin:
                self.json_response(HTTPStatus.FORBIDDEN, {"error": "Invalid request origin"})
                return
            if not secrets.compare_digest(
                self.headers.get("X-AAP-Demo-Token", ""),
                app.session_token,
            ):
                self.json_response(HTTPStatus.FORBIDDEN, {"error": "Invalid session token"})
                return
            try:
                content_length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                self.json_response(HTTPStatus.BAD_REQUEST, {"error": "Invalid content length"})
                return
            if content_length < 0 or content_length > MAX_BODY_BYTES:
                self.json_response(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "Request is too large"})
                return
            try:
                body = json.loads(self.rfile.read(content_length) or b"{}")
            except json.JSONDecodeError:
                self.json_response(HTTPStatus.BAD_REQUEST, {"error": "Invalid JSON"})
                return
            if not isinstance(body, dict):
                self.json_response(HTTPStatus.BAD_REQUEST, {"error": "Expected a JSON object"})
                return

            fleet_power = re.fullmatch(r"/api/fleet/([1-9][0-9]*)/power", urlparse(self.path).path)
            if fleet_power:
                action = body.get("action", "")
                try:
                    result = app.fleet_power(int(fleet_power[1]), action)
                except ValueError as error:
                    self.json_response(HTTPStatus.BAD_REQUEST, {"error": str(error)})
                    return
                except (RuntimeError, OSError) as error:
                    self.json_response(HTTPStatus.CONFLICT, {"error": str(error)})
                    return
                self.json_response(HTTPStatus.OK, result)
                return

            terminal_start = re.fullmatch(r"/api/fleet/([1-9][0-9]*)/terminal", urlparse(self.path).path)
            terminal_io = re.fullmatch(r"/api/terminals/([a-f0-9]{32})/io", urlparse(self.path).path)
            if terminal_start or terminal_io:
                try:
                    if terminal_start:
                        result = {"id": app.start_terminal(int(terminal_start[1]))}
                    else:
                        assert terminal_io is not None
                        result = app.terminal_io(terminal_io[1], body)
                except ValueError as error:
                    self.json_response(HTTPStatus.BAD_REQUEST, {"error": str(error)})
                    return
                except (RuntimeError, OSError) as error:
                    self.json_response(HTTPStatus.CONFLICT, {"error": str(error)})
                    return
                self.json_response(HTTPStatus.OK, result)
                return

            if urlparse(self.path).path == "/api/restart":
                try:
                    app.request_restart()
                except RuntimeError as error:
                    self.json_response(HTTPStatus.CONFLICT, {"error": str(error)})
                    return
                self.json_response(HTTPStatus.ACCEPTED, {"status": "restarting"})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return

            match = re.fullmatch(r"/api/addons/([a-z0-9-]+)/(enable|disable)", urlparse(self.path).path)
            if not match:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            addon_id, action = match.groups()
            if addon_id not in app.addons:
                self.json_response(HTTPStatus.NOT_FOUND, {"error": "Unknown add-on"})
                return
            if action == "disable" and body.get("confirm") is not True:
                self.json_response(
                    HTTPStatus.BAD_REQUEST,
                    {"error": "Disable confirmation is required"},
                )
                return
            try:
                inventory = app.inventory()
                if action == "disable":
                    dependents = app.dependent_addons(addon_id, inventory)
                    if dependents:
                        self.json_response(
                            HTTPStatus.CONFLICT,
                            {
                                "error": (
                                    f"Cannot disable {addon_id}; enabled add-ons depend on it: "
                                    + ", ".join(dependents)
                                )
                            },
                        )
                        return
                operation = app.start_operation(addon_id, action)
            except RuntimeError as error:
                self.json_response(HTTPStatus.CONFLICT, {"error": str(error)})
                return
            self.json_response(HTTPStatus.ACCEPTED, operation)

    return DashboardHandler


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the local aap-demo dashboard")
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("AAP_DEMO_DASHBOARD_PORT", DEFAULT_PORT)),
    )
    parser.add_argument("--no-open", action="store_true")
    parser.add_argument("--background", action="store_true", help="Start detached and return once ready")
    return parser.parse_args()


def dashboard_health(port: int) -> dict[str, Any] | None:
    opener = build_opener(ProxyHandler({}))
    try:
        with opener.open(f"http://{HOST}:{port}/api/health", timeout=1) as response:
            payload = json.load(response)
    except (URLError, ConnectionError, TimeoutError):
        return None
    except (ValueError, OSError) as error:
        raise RuntimeError(f"Cannot identify the service on port {port}: {error}") from error
    if not isinstance(payload, dict) or payload.get("service") != "aap-demo-dashboard":
        raise RuntimeError(f"Port {port} is occupied by another service")
    return payload


def launch_background(repo_root: Path, port: int, open_browser: bool) -> int:
    url = f"http://{HOST}:{port}"
    health = dashboard_health(port)
    log_path = Path(os.environ.get("AAP_DEMO_DIR", Path.home() / ".aap-demo")) / "dashboard.log"
    if health is not None:
        if health.get("repo_root") != str(repo_root):
            raise RuntimeError(f"Another checkout's dashboard is already using {url}")
        print(f"aap-demo dashboard already running: {url} (PID {health['pid']})")
    else:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        flags = (
            {"creationflags": subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP}
            if os.name == "nt" else {"start_new_session": True}
        )
        command = [
            sys.executable, "-u", str(Path(__file__).resolve()),
            "--repo-root", str(repo_root), "--port", str(port), "--no-open",
        ]
        with log_path.open("ab") as log:
            os.chmod(log_path, 0o600)
            process = subprocess.Popen(
                command, cwd=repo_root, stdin=subprocess.DEVNULL,
                stdout=log, stderr=subprocess.STDOUT, **flags,
            )
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f"Dashboard exited with code {process.returncode}; see {log_path}")
                health = dashboard_health(port)
                if health and health.get("pid") == process.pid and health.get("repo_root") == str(repo_root):
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError(f"Dashboard did not become ready on {url}; see {log_path}")
        except (RuntimeError, OSError):
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            raise
        print(f"aap-demo dashboard running in background: {url} (PID {process.pid})")
    print(f"Dashboard log: {log_path}")
    if open_browser:
        webbrowser.open(url)
    return 0


def main() -> int:
    args = parse_args()
    if not 1 <= args.port <= 65535:
        print("ERROR: Dashboard port must be between 1 and 65535", file=sys.stderr)
        return 1
    repo_root = args.repo_root.resolve()
    open_browser = not args.no_open and os.environ.get("AAP_DEMO_DASHBOARD_NO_OPEN") != "true"
    if args.background:
        try:
            return launch_background(repo_root, args.port, open_browser)
        except (RuntimeError, OSError) as error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 1
    app = DashboardApp(repo_root, args.port)
    try:
        server = ThreadingHTTPServer((HOST, args.port), create_handler(app))
    except OSError as error:
        print(f"ERROR: Cannot start dashboard on {app.origin}: {error}", file=os.sys.stderr)
        return 1
    url = app.origin
    print(f"aap-demo dashboard: {url}")
    print("Localhost only. Press Ctrl+C to stop.")
    if open_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        def reap_idle_terminals() -> None:
            while not app.restart_requested:
                time.sleep(30)
                app.reap_terminals()

        threading.Thread(target=reap_idle_terminals, daemon=True).start()
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping dashboard...")
    finally:
        app.reap_terminals(all_sessions=True)
        server.server_close()
    if app.restart_requested:
        print("Restarting dashboard...", flush=True)
        os.execv(sys.executable, [
            sys.executable, "-u", str(Path(__file__).resolve()),
            "--repo-root", str(repo_root), "--port", str(args.port), "--no-open",
        ])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
