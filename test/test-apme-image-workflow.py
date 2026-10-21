"""Execute the real manifest step with offline registry command doubles."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/apme-eap-image.yaml").read_text())
VALIDATION_GATE = next(step["run"] for step in WORKFLOW["jobs"]["resolve"]["steps"]
                       if step.get("name") == "Require validation before latest")
MANIFEST = next(step["run"] for step in WORKFLOW["jobs"]["manifest"]["steps"]
                if step.get("name", "").startswith("Assemble"))

STUB = '''#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
args = sys.argv[1:]
work = pathlib.Path(os.environ["RUNNER_TEMP"])
tool = pathlib.Path(sys.argv[0]).name
with (work / "commands").open("a") as log:
    log.write(json.dumps([tool, *args]) + "\\n")
if tool == "podman" and args[0] == "login":
    assert sys.stdin.read().strip() == os.environ["QUAY_TOKEN"]
elif tool == "podman" and args[:2] == ["manifest", "push"]:
    pathlib.Path(args[args.index("--digestfile") + 1]).write_text(os.environ["DIGEST"])
    (work / "published").touch()
elif tool == "skopeo" and args[0] == "inspect":
    state = os.environ.get("REMOTE_STATE", "missing")
    if not (work / "published").exists():
        if state == "missing":
            sys.exit("manifest unknown: tag not found")
        if state == "network":
            sys.exit("connection reset by peer")
    sys.stdout.write(os.environ["RAW_MANIFEST"])
elif tool == "skopeo" and args[0] == "manifest-digest":
    print("sha256:" + hashlib.sha256(pathlib.Path(args[1]).read_bytes()).hexdigest())
elif tool == "skopeo" and args[0] == "copy":
    pathlib.Path(args[args.index("--digestfile") + 1]).write_text(os.environ["DIGEST"])
else:
    assert tool == "podman" and args[:2] in (["manifest", "create"], ["manifest", "add"])
'''


class ManifestPublicationTests(unittest.TestCase):
    def run_manifest(self, state="missing", architectures=("amd64", "arm64"), promote=False,
                     event="workflow_dispatch", publish_enabled="true"):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            bindir = work / "bin"
            bindir.mkdir()
            for tool in ("podman", "skopeo"):
                (bindir / tool).write_text(STUB)
                (bindir / tool).chmod(0o755)
            (work / "resolved").mkdir()
            (work / "resolved/artifact.env").write_text(
                "export APME_SOURCE_REPO=ansible/apme APME_SOURCE_SHA=" + "a" * 40 + "\n"
                "export APME_RUN_ID=1 APME_ARTIFACT_ID=2 APME_ARTIFACT_NAME=plugins\n"
                "export APME_PACK_FORMAT=oci APME_PACK_SHA256=sha256:" + "b" * 64 + "\n")
            manifest = json.dumps({"schemaVersion": 2, "manifests": [
                {"platform": {"os": "linux", "architecture": arch}} for arch in architectures]})
            digest = "sha256:" + hashlib.sha256(manifest.encode()).hexdigest()
            env = {**os.environ, "PATH": str(bindir) + os.pathsep + os.environ["PATH"],
                   "RUNNER_TEMP": str(work), "REMOTE_STATE": state, "RAW_MANIFEST": manifest,
                   "DIGEST": digest, "IMAGE": "quay.io/aapdemo/apme-eap", "IMMUTABLE_TAG": "apme-test",
                   "QUAY_USERNAME": "robot", "QUAY_TOKEN": "workflow-test-token",
                   "EVENT_NAME": event, "EVENT_REF": "refs/heads/main",
                   "REQUEST_LATEST": "true" if promote else "false", "PUBLISH_ENABLED": publish_enabled,
                   "GITHUB_STEP_SUMMARY": str(work / "summary")}
            # An unset repository variable resolves to an empty step environment value.
            env.pop("APME_QUAY_PUBLISH_ENABLED", None)
            result = subprocess.run(["bash", "-c", VALIDATION_GATE], cwd=ROOT, env=env,
                                    text=True, capture_output=True)
            if result.returncode == 0:
                result = subprocess.run(["bash", "-c", MANIFEST], cwd=ROOT, env=env,
                                        text=True, capture_output=True)
            command_log = work / "commands"
            calls = [json.loads(line) for line in command_log.read_text().splitlines()] if command_log.exists() else []
            self.assertNotIn(env["QUAY_TOKEN"], result.stdout + result.stderr)
            self.assertFalse(list(work.glob("apme-manifest.*")))
            return result, calls

    def test_first_manifest_publication_and_gated_promotion_succeed(self):
        for promote in (False, True):
            with self.subTest(promote=promote):
                result, calls = self.run_manifest(promote=promote)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(sum(c[:3] == ["podman", "manifest", "push"] for c in calls), 1)
                self.assertEqual(sum(c[:2] == ["skopeo", "copy"] for c in calls), int(promote))

    def test_existing_manifest_or_unknown_registry_status_never_pushes(self):
        for state in ("exists", "network"):
            with self.subTest(state=state):
                result, calls = self.run_manifest(state=state, promote=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(c[:3] == ["podman", "manifest", "push"] for c in calls))
                self.assertFalse(any(c[:2] == ["skopeo", "copy"] for c in calls))

    def test_dispatch_latest_with_unset_gate_fails_before_publication(self):
        result, calls = self.run_manifest(promote=True, publish_enabled="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("APME_QUAY_PUBLISH_ENABLED=true", result.stdout + result.stderr)
        self.assertEqual(calls, [])

    def test_main_push_with_enabled_gate_promotes_latest_without_dispatch_request(self):
        result, calls = self.run_manifest(event="push")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sum(c[:3] == ["podman", "manifest", "push"] for c in calls), 1)
        copies = [c for c in calls if c[:2] == ["skopeo", "copy"]]
        self.assertEqual(len(copies), 1)
        self.assertEqual(copies[0][-1], "docker://quay.io/aapdemo/apme-eap:latest")

    def test_incomplete_manifest_never_promotes(self):
        result, calls = self.run_manifest(architectures=("amd64",), promote=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[:2] == ["skopeo", "copy"] for c in calls))


if __name__ == "__main__":
    unittest.main()
