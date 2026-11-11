#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("rhc_connect", ROOT / "scripts/fleet-rhc-connect.py")
assert SPEC and SPEC.loader
RHC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RHC)
CONNECTED = (
    "Connected to Red Hat Subscription Management\n"
    "Connected to Red Hat Insights\n"
    "The Remote Host Configuration daemon is active\n"
)


class RHCTests(unittest.TestCase):
    def test_status_requires_all_components(self):
        self.assertTrue(RHC.connected(CONNECTED))
        self.assertFalse(RHC.connected(CONNECTED.replace("Connected", "Not connected", 1)))
        self.assertFalse(RHC.connected(CONNECTED.replace("is active", "is inactive")))

    def test_real_pty_prompts_and_secret_non_disclosure(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "rhc"
            executable.write_text(
                "#!/usr/bin/env python3\n"
                "import sys, os\n"
                "assert sys.argv == ['" + str(executable) + "', 'connect']\n"
                "u=input('Username: ')\n"
                "p=input('Password: ')\n"
                "print(p)\n"  # Even a tool that echoes passwords must not leak them.
                "sys.exit(0 if u=='fixture-user' and p=='fixture-password' else 1)\n"
            )
            executable.chmod(0o700)
            with patch.dict(os.environ, {"PATH": directory + os.pathsep + os.environ["PATH"]}):
                RHC.connect("fixture-user", "fixture-password", timeout=5)
                with self.assertRaises(RuntimeError):
                    RHC.connect("fixture-user", "wrong-password", timeout=5)

    def test_timeout_reaps_child(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "rhc"
            executable.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(30)\n")
            executable.chmod(0o700)
            with patch.dict(os.environ, {"PATH": directory + os.pathsep + os.environ["PATH"]}):
                with self.assertRaisesRegex(RuntimeError, "timed out"):
                    RHC.connect("user", "password", timeout=0.1)

    def test_partial_rhc_success_finishes_insights(self):
        partial = CONNECTED.replace("Connected to Red Hat Insights", "Not connected to Red Hat Insights")
        with patch.object(RHC.subprocess, "run") as run:
            run.return_value.returncode = 0
            RHC.ensure_insights(partial)
            self.assertEqual(run.call_args.args[0], ["insights-client", "--register"])
            run.return_value.returncode = 1
            with self.assertRaisesRegex(RuntimeError, "Insights"):
                RHC.ensure_insights(partial)
        with patch.object(RHC.subprocess, "run") as run:
            with self.assertRaises(RuntimeError):
                RHC.ensure_insights(CONNECTED.replace("Connected", "Not connected", 1))
            run.assert_not_called()

    def test_already_connected_never_reenrolls(self):
        import io
        with patch.object(RHC, "read_status", return_value=CONNECTED), \
                patch.object(RHC, "connect") as connect, \
                patch.object(RHC.sys, "stdin", io.StringIO(
                    '{"username":"fixture","password":"fixture"}')), \
                patch.object(RHC.sys, "stdout", io.StringIO()):
            RHC.main()
            connect.assert_not_called()

    def test_partial_connection_does_not_reregister_rhsm(self):
        import io
        partial = CONNECTED.replace("Connected to Red Hat Insights", "Not connected to Red Hat Insights")
        with patch.object(RHC, "read_status", side_effect=[partial, partial, CONNECTED]), \
                patch.object(RHC, "connect") as connect, \
                patch.object(RHC, "ensure_insights") as insights, \
                patch.object(RHC.sys, "stdin", io.StringIO(
                    '{"username":"fixture","password":"fixture"}')), \
                patch.object(RHC.sys, "stdout", io.StringIO()):
            RHC.main()
            connect.assert_not_called()
            insights.assert_called_once_with(partial)

    def test_invalid_credentials_do_not_leak(self):
        result = subprocess.run(
            ["python3", str(ROOT / "scripts/fleet-rhc-connect.py")],
            input=json.dumps({"username": "user", "password": "private\ninvalid"}),
            capture_output=True, text=True, check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("private", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
