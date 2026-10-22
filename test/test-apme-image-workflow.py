"""Execute the real manifest step with offline registry command doubles."""
from contextlib import nullcontext
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
    reference = args[-1]
    for arch in ("amd64", "arm64"):
        if reference.endswith("-" + arch):
            state = json.loads(os.environ["ARCH_STATES"]).get(arch, "exists")
            if state != "exists":
                sys.exit({"missing": "manifest unknown: tag not found",
                          "network": "connection reset by peer",
                          "denied": "unauthorized: access denied"}[state])
            sys.stdout.write(json.loads(os.environ["ARCH_MANIFESTS"])[arch])
            sys.exit(0)
    state = os.environ.get("REMOTE_STATE", "missing")
    if state in ("network", "denied", "notfound"):
        sys.exit({"network": "connection reset by peer", "denied": "unauthorized: access denied",
                  "notfound": "404 page not found"}[state])
    if not (work / "published").exists():
        if state == "missing":
            sys.exit("manifest unknown: tag not found")
    sys.stdout.write(os.environ["RAW_MANIFEST"])
elif tool == "skopeo" and args[0] == "manifest-digest":
    if pathlib.Path(args[1]).name.startswith("image-") and "ARCH_DIGEST_OVERRIDE" in os.environ:
        print(os.environ["ARCH_DIGEST_OVERRIDE"])
        sys.exit(0)
    print("sha256:" + hashlib.sha256(pathlib.Path(args[1]).read_bytes()).hexdigest())
elif tool == "skopeo" and args[0] == "copy":
    if os.environ.get("FAIL_COPY") == "true":
        sys.exit("connection reset during promotion")
    pathlib.Path(args[args.index("--digestfile") + 1]).write_text(os.environ["DIGEST"])
else:
    assert tool == "podman" and args[:2] in (["manifest", "create"], ["manifest", "add"])
'''


class ManifestPublicationTests(unittest.TestCase):
    def run_manifest(self, state="missing", architectures=("amd64", "arm64"), promote=False,
                     event="workflow_dispatch", publish_enabled="true", directory=None,
                     fail_copy=False, immutable_tag=None, child_digests=None, arch_states=None,
                     arch_manifest_override=None, arch_digest_override=None):
        with (tempfile.TemporaryDirectory() if directory is None else nullcontext(directory)) as directory:
            work = Path(directory)
            bindir = work / "bin"
            bindir.mkdir(exist_ok=True)
            for tool in ("podman", "skopeo"):
                (bindir / tool).write_text(STUB)
                (bindir / tool).chmod(0o755)
            (work / "resolved").mkdir(exist_ok=True)
            (work / "resolved/artifact.env").write_text(
                "export APME_SOURCE_REPO=ansible/apme APME_SOURCE_SHA=" + "a" * 40 + "\n"
                "export APME_RUN_ID=1 APME_ARTIFACT_ID=2 APME_ARTIFACT_NAME=plugins\n"
                "export APME_PACK_FORMAT=oci APME_PACK_SHA256=sha256:" + "b" * 64 + "\n")
            image_manifests = {
                arch: json.dumps({
                    "schemaVersion": 2,
                    "mediaType": "application/vnd.oci.image.manifest.v1+json",
                    "config": {"mediaType": "application/vnd.oci.image.config.v1+json",
                               "size": 1, "digest": "sha256:" + config_hex * 64},
                    "layers": []})
                for arch, config_hex in (("amd64", "c"), ("arm64", "d"))}
            image_digests = {arch: "sha256:" + hashlib.sha256(raw.encode()).hexdigest()
                             for arch, raw in image_manifests.items()}
            manifest = json.dumps({"schemaVersion": 2, "manifests": [
                {"platform": {"os": "linux", "architecture": arch},
                 "digest": (child_digests or {}).get(arch, image_digests.get(arch, "sha256:" + "e" * 64))}
                for arch in architectures]})
            if arch_manifest_override is not None:
                image_manifests["arm64"] = arch_manifest_override
            digest = "sha256:" + hashlib.sha256(manifest.encode()).hexdigest()
            env = {**os.environ, "PATH": str(bindir) + os.pathsep + os.environ["PATH"],
                   "RUNNER_TEMP": str(work), "REMOTE_STATE": state, "RAW_MANIFEST": manifest,
                   "ARCH_MANIFESTS": json.dumps(image_manifests),
                   "ARCH_STATES": json.dumps(arch_states or {}),
                   "DIGEST": digest, "IMAGE": "quay.io/aapdemo/apme-eap",
                   "IMMUTABLE_TAG": immutable_tag or "apme-" + "a" * 40 + "-" + "b" * 12,
                   "FAIL_COPY": "true" if fail_copy else "false",
                   "QUAY_USERNAME": "robot", "QUAY_TOKEN": "workflow-test-token",
                   "EVENT_NAME": event, "EVENT_REF": "refs/heads/main",
                   "REQUEST_LATEST": "true" if promote else "false", "PUBLISH_ENABLED": publish_enabled,
                   "GITHUB_STEP_SUMMARY": str(work / "summary")}
            # An unset repository variable resolves to an empty step environment value.
            env.pop("APME_QUAY_PUBLISH_ENABLED", None)
            env.pop("ARCH_DIGEST_OVERRIDE", None)
            if arch_digest_override is not None:
                env["ARCH_DIGEST_OVERRIDE"] = arch_digest_override
            command_log = work / "commands"
            previous = len(command_log.read_text().splitlines()) if command_log.exists() else 0
            result = subprocess.run(["bash", "-c", VALIDATION_GATE], cwd=ROOT, env=env,
                                    text=True, capture_output=True)
            if result.returncode == 0:
                result = subprocess.run(["bash", "-c", MANIFEST], cwd=ROOT, env=env,
                                        text=True, capture_output=True)
            calls = [json.loads(line) for line in command_log.read_text().splitlines()[previous:]] if command_log.exists() else []
            summary = work / "summary"
            self.summary = summary.read_text() if summary.exists() else ""
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

    def test_existing_complete_manifest_is_verified_and_promoted_without_republication(self):
        result, calls = self.run_manifest(state="exists", promote=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(c[:2] == ["podman", "manifest"] for c in calls))
        copies = [c for c in calls if c[:2] == ["skopeo", "copy"]]
        self.assertEqual(len(copies), 1)
        digest = copies[0][-2].split("@", 1)[1]
        self.assertIn("Digest: `quay.io/aapdemo/apme-eap@" + digest + "`", self.summary)

    def test_unknown_registry_status_never_publishes_or_promotes(self):
        for state in ("network", "denied", "notfound"):
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

    def test_incomplete_or_extra_existing_platforms_never_publish_or_promote(self):
        for arches in (("amd64",), ("amd64", "amd64"), ("amd64", "arm64", "ppc64le")):
            with self.subTest(arches=arches):
                result, calls = self.run_manifest(state="exists", architectures=arches, promote=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Expected exactly linux/amd64 and linux/arm64", result.stderr)
                self.assertFalse(any(c[:2] == ["podman", "manifest"] for c in calls))
                self.assertFalse(any(c[:2] == ["skopeo", "copy"] for c in calls))

    def test_new_incomplete_manifest_never_promotes(self):
        result, calls = self.run_manifest(architectures=("amd64",), promote=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[:2] == ["skopeo", "copy"] for c in calls))

    def test_existing_manifest_with_wrong_child_digest_never_publishes_or_promotes(self):
        for arch in ("amd64", "arm64"):
            for digest in ("sha256:" + "f" * 64, None, "unknown"):
                with self.subTest(arch=arch, digest=digest):
                    result, calls = self.run_manifest(
                        state="exists", promote=True, child_digests={arch: digest})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Manifest child digests do not match architecture images", result.stderr)
                    self.assertFalse(any(c[:2] == ["podman", "manifest"] for c in calls))
                    self.assertFalse(any(c[:2] == ["skopeo", "copy"] for c in calls))

    def test_new_manifest_with_wrong_child_digest_never_promotes(self):
        result, calls = self.run_manifest(promote=True, child_digests={"arm64": "sha256:" + "f" * 64})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Manifest child digests do not match architecture images", result.stderr)
        self.assertEqual(sum(c[:3] == ["podman", "manifest", "push"] for c in calls), 1)
        self.assertFalse(any(c[:2] == ["skopeo", "copy"] for c in calls))

    def test_unavailable_architecture_tag_blocks_publication_and_promotion(self):
        for arch in ("amd64", "arm64"):
            for state in ("missing", "network", "denied"):
                with self.subTest(arch=arch, state=state):
                    result, calls = self.run_manifest(promote=True, arch_states={arch: state})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"Cannot inspect immutable {arch} image", result.stderr)
                    self.assertFalse(any(c[:2] == ["podman", "manifest"] for c in calls))
                    self.assertFalse(any(c[:2] == ["skopeo", "copy"] for c in calls))

    def test_invalid_architecture_manifest_blocks_publication_and_promotion(self):
        for raw in ("not-json", "{}", '{"schemaVersion": 2, "manifests": []}'):
            with self.subTest(raw=raw):
                result, calls = self.run_manifest(promote=True, arch_manifest_override=raw)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Invalid immutable arm64 image manifest", result.stderr)
                self.assertFalse(any(c[:2] == ["podman", "manifest"] for c in calls))
                self.assertFalse(any(c[:2] == ["skopeo", "copy"] for c in calls))

    def test_unknown_architecture_digest_blocks_publication_and_promotion(self):
        for digest in ("", "unknown", "sha256:short"):
            with self.subTest(digest=digest):
                result, calls = self.run_manifest(promote=True, arch_digest_override=digest)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Invalid immutable amd64 image digest", result.stderr)
                self.assertFalse(any(c[:2] == ["podman", "manifest"] for c in calls))
                self.assertFalse(any(c[:2] == ["skopeo", "copy"] for c in calls))

    def test_bootstrap_then_promote_reuses_same_release_and_supports_retries(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls = self.run_manifest(directory=directory, publish_enabled="")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(sum(c[:3] == ["podman", "manifest", "push"] for c in calls), 1)
            self.assertFalse(any(c[:2] == ["skopeo", "copy"] for c in calls))
            published_summary = self.summary
            for _ in range(2):
                result, calls = self.run_manifest(directory=directory, promote=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(any(c[:2] == ["podman", "manifest"] for c in calls))
                copies = [c for c in calls if c[:2] == ["skopeo", "copy"]]
                self.assertEqual(len(copies), 1)
                self.assertIn(copies[0][-2].removeprefix("docker://"), published_summary)

    def test_failed_latest_copy_can_retry_without_overwriting_release(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls = self.run_manifest(directory=directory, promote=True, fail_copy=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sum(c[:3] == ["podman", "manifest", "push"] for c in calls), 1)
            result, calls = self.run_manifest(directory=directory, promote=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(any(c[:2] == ["podman", "manifest"] for c in calls))
            self.assertEqual(sum(c[:2] == ["skopeo", "copy"] for c in calls), 1)

    def test_existing_release_tag_must_match_resolved_source_and_pack(self):
        result, calls = self.run_manifest(state="exists", promote=True, immutable_tag="apme-wrong")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Resolved source/pack does not match immutable tag", result.stderr)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
