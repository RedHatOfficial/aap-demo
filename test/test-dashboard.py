#!/usr/bin/env python3
"""Tests for the local aap-demo dashboard."""

from __future__ import annotations

import importlib.util
import json
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import base64
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parents[1]
SERVER_PATH = REPO_ROOT / "dashboard" / "server.py"
SPEC = importlib.util.spec_from_file_location("aap_demo_dashboard", SERVER_PATH)
assert SPEC and SPEC.loader
dashboard = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = dashboard
SPEC.loader.exec_module(dashboard)


def fixture_inventory() -> dict[str, Any]:
    return {
        "addons": ["mcp-server", "ao", "ollama"],
        "api_keys": {"ao_llm": {"provider": "ollama"}},
        "pods": [
            {
                "namespace": "aap-operator",
                "name": "aap-mcp-server-abc",
                "phase": "Running",
                "ready_containers": 1,
                "total_containers": 1,
            },
            {
                "namespace": "automation-orchestrator",
                "name": "automation-orchestrator-ui-abc",
                "phase": "Running",
                "ready_containers": 1,
                "total_containers": 1,
            },
            {
                "namespace": "aap-demo-ollama",
                "name": "ollama-abc",
                "phase": "Running",
                "ready_containers": 1,
                "total_containers": 1,
            },
        ],
        "host": {"os": "Fedora Linux 44", "architecture": "x86_64"},
        "tool": {"version": "1.0.48", "v2_available": True},
        "cluster": {"state": "running", "vm": {"guest_os": "Red Hat Enterprise Linux 9.6"}},
        "storage": {
            "capacity_planning": {
                "actual_vm_disk_gib": 140,
                "actual_vm_used_gib": 110,
                "actual_vm_free_gib": 30,
                "configured_crc_disk_gib": 160,
                "recommended_vm_disk_gib": 160,
                "host_only_gib": 0,
                "needs_rebuild": True,
                "configured_not_applied": True,
                "addon_estimates": {
                    "mcp-server": {"vm_gib": 3, "host_gib": 0},
                    "portal": {"vm_gib": 8, "host_gib": 0},
                },
                "projected_vm_disk_gib": {
                    "mcp-server": 160,
                    "portal": 170,
                },
            }
        },
        "routes": [],
        "fleet": [
            {"index": 1, "hostname": "aap-fleet-node-1", "state": "running",
             "ssh_host": "127.0.0.1", "ssh_port": 2201, "username": "admin", "password": None}
        ],
        "fleet_v2": [
            {"namespace": "aap-fleet", "name": "fleet-node-0", "state": "running",
             "ready": True, "pod_ip": "10.42.0.12"}
        ],
        "namespaces": [],
    }


class DashboardUnitTests(unittest.TestCase):
    def setUp(self) -> None:
        self.catalog = dashboard.load_catalog(REPO_ROOT)
        self.addons = {addon["id"]: addon for addon in self.catalog["addons"]}

    def test_windows_cli_uses_native_powershell_with_separate_arguments(self) -> None:
        app = dashboard.DashboardApp(REPO_ROOT, 0)
        app.repo_root = REPO_ROOT / "checkout with spaces"
        with patch.object(dashboard.sys, "platform", "win32"), \
                patch.object(dashboard.subprocess, "run") as run:
            app.run_cli("status", "--json")
            command = run.call_args.args[0]
            self.assertEqual(command, [
                "powershell.exe", "-NoProfile", "-NonInteractive",
                "-ExecutionPolicy", "Bypass", "-File",
                str(app.repo_root / "powershell/aap-demo.ps1"), "status", "--json",
            ])
            self.assertEqual(run.call_args.kwargs["encoding"], "utf-8")
            self.assertEqual(run.call_args.kwargs["env"]["AAP_DEMO_DASHBOARD_COMMAND"], "1")
            self.assertNotIn("aap-demo.sh", " ".join(command))

    def test_windows_inventory_marks_unsupported_addons_and_rejects_operations(self) -> None:
        app = dashboard.DashboardApp(REPO_ROOT, 0)
        inventory = fixture_inventory()
        inventory["supported_addons"] = ["mcp-server", "portal"]
        app.inventory = lambda: inventory
        payload = app.status_payload()
        addons = {addon["id"]: addon for addon in payload["addons"]}
        self.assertTrue(addons["mcp-server"]["supported"])
        self.assertFalse(addons["ollama"]["supported"])
        with patch.object(dashboard.sys, "platform", "win32"), \
                patch.object(dashboard.threading.Thread, "start") as start:
            with self.assertRaisesRegex(RuntimeError, "not supported"):
                app.start_operation("ollama", "enable")
            start.assert_not_called()

    def test_windows_addon_operations_use_native_powershell(self) -> None:
        app = dashboard.DashboardApp(REPO_ROOT, 0)
        process = subprocess.CompletedProcess([], 0)
        with patch.object(dashboard.sys, "platform", "win32"), \
                patch.object(dashboard.subprocess, "Popen") as popen:
            popen.return_value.poll.return_value = 0
            popen.return_value.stdout = iter([])
            popen.return_value.wait.return_value = process.returncode
            app._execute_operation("test", "mcp-server", "enable")
            self.assertEqual(popen.call_args.args[0], [
                "powershell.exe", "-NoProfile", "-NonInteractive",
                "-ExecutionPolicy", "Bypass", "-File",
                str(REPO_ROOT / "powershell/aap-demo.ps1"), "enable", "mcp-server",
            ])
            self.assertEqual(popen.call_args.kwargs["encoding"], "utf-8")

    def test_fleet_terminal_runs_fixed_ssh_command_and_cleans_up(self) -> None:
        popen = subprocess.Popen
        commands: list[list[str]] = []

        def spawn(command: list[str], **kwargs: Any) -> subprocess.Popen[bytes]:
            commands.append(command)
            return popen(
                [sys.executable, "-u", "-c",
                 "import sys; print('shell-ready'); print('received:' + sys.stdin.readline().strip())"],
                **kwargs,
            )

        with patch.object(dashboard.subprocess, "Popen", side_effect=spawn):
            terminal = dashboard.FleetTerminal(Path("/tmp/fleet fixture"), 2201)
        try:
            self.assertEqual(commands[0][-1], "admin@127.0.0.1")
            self.assertIn("StrictHostKeyChecking=yes", commands[0])
            self.assertNotIn("password", " ".join(commands[0]).lower())
            output = bytearray()
            deadline = time.monotonic() + 3
            data = "hello-fleet\n"
            while time.monotonic() < deadline:
                result = terminal.exchange(data, 100, 30)
                data = ""
                output.extend(base64.b64decode(result["output"]))
                if b"received:hello-fleet" in output:
                    break
                time.sleep(0.02)
            self.assertIn(b"received:hello-fleet", output)
        finally:
            terminal.close()
        self.assertIsNotNone(terminal.process.poll())
        terminal.close()

    def test_fleet_sessions_restrict_nodes_and_input(self) -> None:
        app = dashboard.DashboardApp(REPO_ROOT, 0)
        app.inventory = fixture_inventory
        with self.assertRaisesRegex(RuntimeError, "missing or stopped"):
            app.start_terminal(99)
        with patch.object(Path, "is_file", return_value=True), \
                patch.object(dashboard, "FleetTerminal") as factory:
            factory.return_value.last_used = time.monotonic()
            session_id = app.start_terminal(1)
            self.assertEqual(factory.call_args.args[1], 2201)
            with self.assertRaisesRegex(ValueError, "dimensions"):
                app.terminal_io(session_id, {"cols": "100"})
            with self.assertRaisesRegex(ValueError, "2048"):
                app.terminal_io(session_id, {"data": "a" * 2049})
            app.terminal_io(session_id, {"close": True})
            factory.return_value.close.assert_called_once()
            with self.assertRaisesRegex(RuntimeError, "expired"):
                app.terminal_io(session_id, {})

    def test_fleet_sessions_expire_and_are_bounded(self) -> None:
        app = dashboard.DashboardApp(REPO_ROOT, 0)
        app.inventory = fixture_inventory
        with patch.object(Path, "is_file", return_value=True), \
                patch.object(dashboard, "FleetTerminal") as factory:
            factory.return_value.last_used = time.monotonic()
            for _ in range(4):
                app.start_terminal(1)
            with self.assertRaisesRegex(RuntimeError, "four"):
                app.start_terminal(1)
            factory.return_value.last_used -= dashboard.TERMINAL_IDLE_SECONDS + 1
            app.reap_terminals()
            self.assertEqual(len(app.terminals), 0)

    def test_catalog_matches_public_cli_addons(self) -> None:
        cli = (REPO_ROOT / "aap-demo.sh").read_text(encoding="utf-8")
        match = re.search(r'^AVAILABLE_ADDONS="([^"]+)"', cli, re.MULTILINE)
        self.assertIsNotNone(match)
        cli_addons = set(match.group(1).split())
        catalog_addons = {addon["id"] for addon in self.catalog["addons"]}
        self.assertEqual(cli_addons, catalog_addons)

    def test_status_payload_passes_through_fleet_v2_and_v2_availability(self) -> None:
        app = dashboard.DashboardApp(REPO_ROOT, 0)
        app.inventory = lambda: fixture_inventory()
        payload = app.status_payload()
        self.assertEqual(
            payload["inventory"]["fleet_v2"],
            [{"namespace": "aap-fleet", "name": "fleet-node-0", "state": "running",
              "ready": True, "pod_ip": "10.42.0.12"}],
        )
        self.assertTrue(payload["inventory"]["tool"]["v2_available"])

    def test_completed_job_pods_do_not_mark_namespace_degraded(self) -> None:
        # A namespace with running services plus Completed migration/job pods is
        # healthy — Completed pods are finished work, not failed workloads.
        inventory = fixture_inventory()
        inventory["pods"].append({
            "namespace": "automation-orchestrator",
            "name": "automation-orchestrator-migration-abc",
            "phase": "Completed",
            "ready_containers": 0,
            "total_containers": 1,
        })
        self.assertEqual(dashboard.addon_state(self.addons["ao"], inventory), "running")

    def test_health_and_conditional_dependencies(self) -> None:
        inventory = fixture_inventory()
        self.assertEqual(dashboard.addon_state(self.addons["mcp-server"], inventory), "running")
        self.assertEqual(dashboard.addon_state(self.addons["portal"], inventory), "disabled")
        self.assertEqual(
            dashboard.active_dependencies(self.addons["ao"], inventory),
            ["mcp-server", "ollama"],
        )
        inventory["api_keys"]["ao_llm"]["provider"] = "external"
        self.assertEqual(
            dashboard.active_dependencies(self.addons["ao"], inventory),
            ["mcp-server"],
        )

    def test_operation_output_redacts_credentials(self) -> None:
        output = (
            "Authorization: Bearer secret-token\n"
            "Password: secret-password\n"
            "token=another-token\n"
            "aap-operator: admin / final-secret"
        )
        redacted = dashboard.redact_output(output)
        for secret in ("secret-token", "secret-password", "another-token", "final-secret"):
            self.assertNotIn(secret, redacted)
        self.assertGreaterEqual(redacted.count("******"), 4)

    def test_operation_output_streams_before_completion(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            cli = Path(temp_dir) / "aap-demo.sh"
            cli.write_text(
                "#!/usr/bin/env bash\n"
                "echo 'phase one'\n"
                "sleep 1\n"
                "echo 'phase two'\n",
                encoding="utf-8",
            )
            cli.chmod(0o700)
            app = dashboard.DashboardApp(REPO_ROOT, 0)
            app.cli = cli
            app.start_operation("portal", "enable")
            deadline = time.monotonic() + 1
            snapshot = app.operation.snapshot()
            while "phase one" not in snapshot["output"] and time.monotonic() < deadline:
                time.sleep(0.05)
                snapshot = app.operation.snapshot()
            self.assertEqual(snapshot["status"], "running")
            self.assertIn("phase one", snapshot["output"])

            deadline = time.monotonic() + 2
            while snapshot["status"] == "running" and time.monotonic() < deadline:
                time.sleep(0.05)
                snapshot = app.operation.snapshot()
            self.assertEqual(snapshot["status"], "succeeded")
            self.assertIn("phase two", snapshot["output"])

    def test_dashboard_capacity_markup_and_rendering(self) -> None:
        markup = (REPO_ROOT / "dashboard/static/index.html").read_text(encoding="utf-8")
        script = (REPO_ROOT / "dashboard/static/app.js").read_text(encoding="utf-8")
        self.assertIn("<h1>Ansible Automation Platform - MicroShift Demo</h1>", markup)
        self.assertIn("<h2>Environment Overview</h2>", markup)
        self.assertIn('id="capacity-panel"', markup)
        self.assertIn('role="status"', markup)
        self.assertIn("Configured CRC disk", script)
        self.assertIn("At 90% disk usage, aap-demo start adds 20% capacity", script)
        self.assertIn("This planning estimate is not a resize trigger.", script)
        self.assertNotIn("requires a destructive rebuild", script)
        self.assertNotIn("setting applies only to a newly created VM", script)
        self.assertIn("Projected recommendation", script)
        self.assertIn('id="environment-os"', markup)
        self.assertIn('id="restart-button"', markup)
        self.assertIn("Host OS:", script)
        self.assertIn("CRC guest OS:", script)
        self.assertIn("AAP subscription:", script)
        self.assertIn('api("/api/restart"', script)

    def test_host_os_falls_back_for_non_linux_inventory(self) -> None:
        app = dashboard.DashboardApp(REPO_ROOT, 0)
        inventory = fixture_inventory()
        inventory["host"]["os"] = "unknown"
        with patch.object(app, "inventory", return_value=inventory), \
                patch.object(dashboard.platform, "system", return_value="Darwin"), \
                patch.object(dashboard.platform, "release", return_value="25.0"):
            self.assertEqual(app.status_payload()["inventory"]["host"]["os"], "Darwin 25.0")

    def test_restart_and_addon_operations_cannot_overlap(self) -> None:
        app = dashboard.DashboardApp(REPO_ROOT, 0)
        app.operation.status = "running"
        with self.assertRaisesRegex(RuntimeError, "current add-on operation"):
            app.request_restart()
        app.operation.status = "idle"
        app.request_restart()
        with self.assertRaisesRegex(RuntimeError, "already restarting"):
            app.request_restart()
        with self.assertRaisesRegex(RuntimeError, "restarting"):
            app.start_operation("portal", "enable")


class DashboardHttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.app = dashboard.DashboardApp(REPO_ROOT, 0)
        cls.app.inventory = fixture_inventory
        cls.server = dashboard.ThreadingHTTPServer(
            (dashboard.HOST, 0),
            dashboard.create_handler(cls.app),
        )
        cls.port = cls.server.server_address[1]
        cls.app.port = cls.port
        cls.app.origin = f"http://{dashboard.HOST}:{cls.port}"
        cls.base_url = cls.app.origin
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def request(
        self,
        path: str,
        *,
        method: str = "GET",
        body: dict[str, Any] | None = None,
        token: str | None = None,
        origin: str | None = None,
    ) -> tuple[int, dict[str, Any]]:
        data = json.dumps(body or {}).encode() if method == "POST" else None
        headers = {"Content-Type": "application/json"}
        if token is not None:
            headers["X-AAP-Demo-Token"] = token
        if origin is not None:
            headers["Origin"] = origin
        request = urllib.request.Request(
            self.base_url + path,
            data=data,
            headers=headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=3) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            with error:
                return error.code, json.load(error)

    def test_status_is_secret_free_and_reports_addons(self) -> None:
        status, payload = self.request("/api/status")
        self.assertEqual(status, 200)
        self.assertEqual(payload["inventory"]["cluster"]["state"], "running")
        self.assertEqual(
            next(addon for addon in payload["addons"] if addon["id"] == "mcp-server")["state"],
            "running",
        )
        self.assertNotIn("credentials", payload["inventory"])
        portal = next(addon for addon in payload["addons"] if addon["id"] == "portal")
        self.assertEqual(portal["projected_vm_disk_gib"], 170)
        self.assertEqual(portal["capacity_estimate"]["vm_gib"], 8)

    def test_browser_terminal_requires_session_and_origin(self) -> None:
        status, _ = self.request("/api/fleet/1/terminal", method="POST")
        self.assertEqual(status, 403)
        with patch.object(self.app, "start_terminal", return_value="a" * 32) as start:
            status, payload = self.request(
                "/api/fleet/1/terminal", method="POST",
                token=self.app.session_token, origin=self.app.origin,
            )
            self.assertEqual(status, 200)
            self.assertEqual(payload["id"], "a" * 32)
            start.assert_called_once_with(1)
        status, _ = self.request("/api/terminals/" + "a" * 32 + "/io", method="POST")
        self.assertEqual(status, 403)
        status, _ = self.request(
            "/api/terminals/" + "a" * 32 + "/io", method="POST",
            token=self.app.session_token, origin=self.app.origin,
        )
        self.assertEqual(status, 409)

    def test_mutation_requires_origin_and_session_token(self) -> None:
        status, _ = self.request(
            "/api/addons/portal/enable",
            method="POST",
            origin=self.app.origin,
        )
        self.assertEqual(status, 403)
        status, _ = self.request(
            "/api/addons/portal/enable",
            method="POST",
            token=self.app.session_token,
            origin="http://attacker.invalid",
        )
        self.assertEqual(status, 403)

    def test_disable_requires_confirmation_and_protects_dependencies(self) -> None:
        status, _ = self.request(
            "/api/addons/mcp-server/disable",
            method="POST",
            token=self.app.session_token,
            origin=self.app.origin,
        )
        self.assertEqual(status, 400)
        status, payload = self.request(
            "/api/addons/mcp-server/disable",
            method="POST",
            body={"confirm": True},
            token=self.app.session_token,
            origin=self.app.origin,
        )
        self.assertEqual(status, 409)
        self.assertIn("ao", payload["error"])

    def test_allowlisted_enable_operation_is_accepted(self) -> None:
        original = self.app.start_operation
        self.app.start_operation = lambda addon, action: {
            "id": "fixture",
            "addon": addon,
            "action": action,
            "status": "running",
        }
        try:
            status, payload = self.request(
                "/api/addons/portal/enable",
                method="POST",
                body={},
                token=self.app.session_token,
                origin=self.app.origin,
            )
        finally:
            self.app.start_operation = original
        self.assertEqual(status, 202)
        self.assertEqual(payload["addon"], "portal")

    def test_invalid_host_is_rejected(self) -> None:
        request = urllib.request.Request(
            self.base_url + "/api/status",
            headers={"Host": "attacker.invalid"},
        )
        with self.assertRaises(urllib.error.HTTPError) as context:
            urllib.request.urlopen(request, timeout=3)
        self.assertEqual(context.exception.code, 403)
        context.exception.close()

    def test_security_headers_are_present(self) -> None:
        request = urllib.request.Request(self.base_url + "/")
        with urllib.request.urlopen(request, timeout=3) as response:
            self.assertEqual(response.headers["X-Frame-Options"], "DENY")
            self.assertIn("frame-ancestors 'none'", response.headers["Content-Security-Policy"])

    def test_restart_requires_origin_and_session(self) -> None:
        for token, origin in ((None, None), ("invalid", self.app.origin),
                              (self.app.session_token, "http://attacker.invalid")):
            status, _ = self.request("/api/restart", method="POST", token=token, origin=origin)
            self.assertEqual(status, 403)

    def test_restart_is_accepted_without_touching_cluster(self) -> None:
        with patch.object(self.app, "request_restart") as restart, \
                patch.object(self.server, "shutdown") as shutdown, \
                patch.object(self.app, "run_cli") as run_cli:
            status, payload = self.request(
                "/api/restart", method="POST",
                token=self.app.session_token, origin=self.app.origin,
            )
            self.assertEqual(status, 202)
            self.assertEqual(payload["status"], "restarting")
            restart.assert_called_once()
            deadline = time.monotonic() + 1
            while not shutdown.called and time.monotonic() < deadline:
                time.sleep(0.01)
            shutdown.assert_called_once()
            run_cli.assert_not_called()

    def test_busy_restart_is_rejected(self) -> None:
        with patch.object(self.app, "request_restart", side_effect=RuntimeError("Operation running")):
            status, _ = self.request(
                "/api/restart", method="POST",
                token=self.app.session_token, origin=self.app.origin,
            )
        self.assertEqual(status, 409)

    def test_health_is_independent_of_cluster(self) -> None:
        with patch.object(self.app, "inventory", side_effect=RuntimeError("CRC stopped")):
            status, payload = self.request("/api/health")
        self.assertEqual(status, 200)
        self.assertEqual(payload["service"], "aap-demo-dashboard")
        self.assertEqual(payload["repo_root"], str(REPO_ROOT))
        self.assertNotIn(self.app.session_token, json.dumps(payload))


class DashboardBackgroundTests(unittest.TestCase):
    def test_background_return_reuse_and_real_restart(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            with socket.socket() as listener:
                listener.bind((dashboard.HOST, 0))
                port = listener.getsockname()[1]
            command = [
                sys.executable, str(SERVER_PATH), "--background", "--no-open",
                "--repo-root", str(REPO_ROOT), "--port", str(port),
            ]
            environment = os.environ.copy()
            environment["AAP_DEMO_DIR"] = temp_dir
            pid = None
            try:
                started = time.monotonic()
                result = subprocess.run(command, env=environment, capture_output=True,
                                        text=True, timeout=15, check=False)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertLess(time.monotonic() - started, 12)
                self.assertIn("running in background", result.stdout)
                health = dashboard.dashboard_health(port)
                self.assertIsNotNone(health)
                pid = health["pid"]
                self.assertNotEqual(pid, os.getpid())
                if os.name != "nt":
                    self.assertEqual(os.getsid(pid), pid)
                self.assertTrue((Path(temp_dir) / "dashboard.log").is_file())
                reused = subprocess.run(command, env=environment, capture_output=True,
                                        text=True, timeout=15, check=False)
                self.assertEqual(reused.returncode, 0, reused.stderr)
                self.assertIn("already running", reused.stdout)
                self.assertEqual(dashboard.dashboard_health(port)["pid"], pid)
                base_url = f"http://{dashboard.HOST}:{port}"
                with urllib.request.urlopen(base_url + "/api/session", timeout=3) as response:
                    token = json.load(response)["token"]
                request = urllib.request.Request(
                    base_url + "/api/restart", data=b"{}", method="POST",
                    headers={"Content-Type": "application/json", "Origin": base_url,
                             "X-AAP-Demo-Token": token},
                )
                with urllib.request.urlopen(request, timeout=3) as response:
                    self.assertEqual(response.status, 202)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    new_health = dashboard.dashboard_health(port)
                    if new_health and new_health["instance"] != health["instance"]:
                        break
                    time.sleep(0.1)
                else:
                    self.fail("Background dashboard did not restart")
                self.assertEqual(new_health["pid"], pid)
                with urllib.request.urlopen(base_url + "/api/session", timeout=3) as response:
                    self.assertNotEqual(json.load(response)["token"], token)
            finally:
                if pid is None:
                    health = dashboard.dashboard_health(port)
                    pid = health["pid"] if health else None
                if pid is not None:
                    os.kill(pid, signal.SIGTERM)
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline and dashboard.dashboard_health(port):
                        time.sleep(0.1)

    def test_background_refuses_other_checkout(self) -> None:
        with patch.object(dashboard, "dashboard_health", return_value={
            "service": "aap-demo-dashboard", "repo_root": "/different/checkout", "pid": 1,
        }), patch.object(dashboard.subprocess, "Popen") as spawn:
            with self.assertRaisesRegex(RuntimeError, "Another checkout"):
                dashboard.launch_background(REPO_ROOT, 8765, False)
            spawn.assert_not_called()

    def test_background_child_failure_is_not_reported_as_success(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir, \
                patch.dict(os.environ, {"AAP_DEMO_DIR": temp_dir}), \
                patch.object(dashboard, "dashboard_health", return_value=None), \
                patch.object(dashboard.subprocess, "Popen") as spawn:
            spawn.return_value.poll.return_value = 1
            spawn.return_value.returncode = 1
            with self.assertRaisesRegex(RuntimeError, "Dashboard exited with code 1"):
                dashboard.launch_background(REPO_ROOT, 8765, False)
            spawn.return_value.terminate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
