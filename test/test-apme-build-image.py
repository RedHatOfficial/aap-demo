#!/usr/bin/env python3
"""Offline build/publish contracts; real resolver, archives and metadata."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "addons/apme-eap/ci/build-image.sh"
SHA = "a" * 40
DIGEST = "sha256:" + "b" * 64
PLUGINS = (
    "ansible-plugin-scaffolder-backend-module-backstage-rhaap",
    "ansible-backstage-plugin-catalog-backend-module-rhaap",
    "ansible-plugin-backstage-self-service",
    "ansible-backstage-plugin-auth-backend-module-rhaap-provider",
    "ansible-plugin-backstage-apme",
    "ansible-backstage-plugin-catalog-backend-module-apme",
)


class BuildImageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="apme build test ")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.pack = self.work / "pack.tar.gz"
        with tarfile.open(self.pack, "w:gz") as pack:
            for plugin in PLUGINS:
                data = io.BytesIO()
                with tarfile.open(fileobj=data, mode="w:gz") as package:
                    content = json.dumps({"name": plugin}).encode()
                    entry = tarfile.TarInfo("package/package.json")
                    entry.size = len(content)
                    package.addfile(entry, io.BytesIO(content))
                entry = tarfile.TarInfo(plugin + "-dynamic-1.0.0.tgz")
                entry.size = len(data.getvalue())
                pack.addfile(entry, io.BytesIO(data.getvalue()))
        self.pack_hash = "sha256:" + hashlib.sha256(self.pack.read_bytes()).hexdigest()
        with zipfile.ZipFile(self.work / "artifact.zip", "w") as archive:
            archive.write(self.pack, "pack.tar.gz")
        self.stub("gh", '''#!/usr/bin/env python3
import json, os, pathlib, sys
w = pathlib.Path(os.environ["FIXTURE_DIR"])
endpoint = sys.argv[2]
with (w / "api.log").open("a") as log:
    log.write(endpoint + "\\n")
if endpoint.endswith("/actions/runs"):
    print(json.dumps({"workflow_runs":[{"id":1,"head_sha":"a"*40,
        "head_branch":"main","status":"completed","conclusion":"success",
        "created_at":"2026-10-20T00:00:00Z"}]}))
elif endpoint.endswith("/artifacts"):
    print(json.dumps({"artifacts":[{"id":2,"name":"plugins-" + os.environ.get("APME_PACK_FORMAT", "oci"),"expired":False}]}))
elif endpoint.endswith("/zip"):
    sys.stdout.buffer.write((w / "artifact.zip").read_bytes())
else:
    print('{"default_branch":"main"}')
''')
        self.stub("podman", '''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
w = pathlib.Path(os.environ["FIXTURE_DIR"])
args = sys.argv[1:]
if "--authfile" in args:
    path = args[args.index("--authfile")+1]
    config = pathlib.Path(path).read_text()
    host = args[-1] if args[0] == "login" else ("quay.io" if args[0] == "push" else "registry.redhat.io")
    assert set(json.loads(config)["credHelpers"]) == {host}, "auth must contain only the current registry"
    helper = "docker-credential-" + json.loads(config)["credHelpers"][host]
    creds = json.loads(subprocess.check_output([helper, "get"], input=host.encode()))
    expected = "quay-test-secret" if host == "quay.io" else "redhat-test-secret"
    assert creds["Secret"] == expected
    if args[0] == "login":
        subprocess.run([helper, "store"], input=json.dumps(creds).encode(), check=True)
        assert pathlib.Path(path).read_text() == config
    assert expected not in config
if args[0] == "login":
    assert "--password-stdin" in args and "--authfile" in args
    assert sys.stdin.read().strip() in ("quay-test-secret", "redhat-test-secret")
    if os.environ.get("CHECK_REAL_AUTH"):
        # Skopeo uses the same containers/image credential-helper contract,
        # without Podman remote's requirement for a running VM on macOS.
        user = subprocess.check_output([os.environ["REAL_AUTH_CLI"], "login",
            "--authfile", path, "--get-login", host], text=True).strip()
        assert user == ("robot" if host == "quay.io" else "rh")
with (w / "podman.log").open("a") as log:
    log.write(json.dumps(args) + "\\n")
if args[0] == "build":
    context = pathlib.Path(args[-1])
    assert (context / "plugin-pack.tar.gz").is_file()
    assert (context / "ci/extract-plugin-pack.py").is_file()
    assert not any("secret" in p.name for p in context.rglob("*"))
if args[0] == os.environ.get("FAIL_COMMAND"):
    sys.exit(42)
if args[0] == "push":
    assert "--authfile" in args
    pathlib.Path(args[args.index("--digestfile")+1]).write_text("sha256:" + "b"*64)
if args[:2] == ["image", "inspect"]:
    print(os.environ.get("IMAGE_ID", "c"*64))
''')
        self.stub("uname", '#!/usr/bin/env bash\nprintf "%s\\n" "${HOST_ARCH:-x86_64}"\n')
        self.stub("skopeo", '''#!/usr/bin/env python3
import json, os, pathlib, sys
w = pathlib.Path(os.environ["FIXTURE_DIR"])
with (w / "remote.log").open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
state = os.environ.get("REMOTE_STATE", "missing")
if state == "exists":
    print('{"schemaVersion":2}')
    sys.exit(0)
print({"missing": "manifest unknown: tag not found",
       "denied": "unauthorized: authentication required",
       "network": "connection reset by peer",
       "notfound": "404 page not found"}[state], file=sys.stderr)
sys.exit(1)
''')
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(
            ("APME_", "QUAY_", "REGISTRY_REDHAT_", "BASE_IMAGE"))}
        self.env.update(PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        FIXTURE_DIR=str(self.work), GH_TOKEN="github-test-secret",
                        QUAY_USERNAME="robot", QUAY_TOKEN="quay-test-secret", APME_PACK_FORMAT="npm")
        self.env["REAL_AUTH_CLI"] = shutil.which("skopeo") or ""

    def stub(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_build(self, *args, ok=True):
        result = subprocess.run(["bash", str(SCRIPT), "--output-dir", str(self.work / "output"),
                                 *args], env=self.env, capture_output=True, text=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stderr, "")
        else:
            self.assertNotEqual(result.returncode, 0)
        for secret in ("github-test-secret", "quay-test-secret", "redhat-test-secret"):
            self.assertNotIn(secret, result.stdout + result.stderr)
            for path in (self.work / "output").rglob("*"):
                if path.is_file():
                    self.assertNotIn(secret.encode(), path.read_bytes())
        self.assertFalse(list((self.work / "output").glob(".auth.*")))
        self.assertFalse(list((self.work / "output").glob(".context.*")))
        return result

    def calls(self):
        path = self.work / "podman.log"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_local_build_never_logs_in_to_quay_or_pushes(self):
        self.env.pop("QUAY_USERNAME")
        self.env.pop("QUAY_TOKEN")
        result = self.run_build()
        calls = self.calls()
        self.assertEqual([call[0] for call in calls], ["build", "image"])
        build = calls[0]
        self.assertIn("quay.io/aapdemo/apme-eap:apme-" + SHA + "-" + self.pack_hash[7:19], build)
        for arg in ("PLUGIN_PACK_SHA256=" + self.pack_hash, "PLUGIN_PACK_FORMAT=npm",
                    "BASE_IMAGE=registry.redhat.io/rhdh/rhdh-hub-rhel9:1.9",
                    "org.opencontainers.image.revision=" + SHA,
                    "org.opencontainers.image.source=https://github.com/ansible/ansible-rhdh-plugins",
                    "io.apme.artifact.id=2", "io.apme.pack.sha256=" + self.pack_hash):
            self.assertIn(arg, build)
        self.assertTrue(any(arg.startswith("org.opencontainers.image.created=") for arg in build))
        self.assertTrue(any(arg.endswith("/Containerfile.ci") for arg in build))
        self.assertIn(str(self.work / "output/artifact.env"), result.stdout)
        self.assertIn("Local image digest (config): sha256:" + "c" * 64, result.stdout)

    def test_push_requires_flag_and_reports_registry_digest(self):
        self.env["IMAGE_ID"] = "sha256:" + "c" * 64
        result = self.run_build("--push", "--tag", "release_1")
        calls = self.calls()
        self.assertEqual([c[0] for c in calls], ["build", "image", "login", "push", "tag", "push"])
        immutable = "apme-" + SHA + "-" + self.pack_hash[7:19] + "-amd64"
        push_refs = [call[-1] for call in calls if call[0] == "push"]
        self.assertEqual(push_refs, [
            "docker://quay.io/aapdemo/apme-eap:" + immutable,
            "docker://quay.io/aapdemo/apme-eap:release_1",
        ])
        self.assertIn("quay.io/aapdemo/apme-eap@" + DIGEST, result.stdout)

    def test_push_derives_host_architecture_and_never_publishes_manifest_tag(self):
        for host, arch in (("x86_64", "amd64"), ("aarch64", "arm64"), ("arm64", "arm64")):
            with self.subTest(host=host):
                (self.work / "podman.log").unlink(missing_ok=True)
                self.env["HOST_ARCH"] = host
                self.run_build("--push")
                push = next(c for c in self.calls() if c[0] == "push")
                self.assertEqual(push[-1], "docker://quay.io/aapdemo/apme-eap:apme-"
                                 + SHA + "-" + self.pack_hash[7:19] + "-" + arch)

    def test_push_rejects_unknown_host_architecture(self):
        self.env["HOST_ARCH"] = "s390x"
        self.run_build("--push", ok=False)
        self.assertFalse(any(c[0] == "push" for c in self.calls()))

    def test_existing_immutable_image_cannot_be_overwritten_or_aliased(self):
        self.env["REMOTE_STATE"] = "exists"
        result = self.run_build("--push", "--tag", "release_1", ok=False)
        self.assertIn("already exists", result.stderr)
        self.assertFalse(any(c[0] in ("push", "tag") for c in self.calls()))

    def test_unknown_remote_status_fails_closed(self):
        for state in ("denied", "network", "notfound"):
            with self.subTest(state=state):
                self.env["REMOTE_STATE"] = state
                result = self.run_build("--push", ok=False)
                self.assertIn("confirm", result.stderr)
                self.assertFalse(any(c[0] == "push" for c in self.calls()))

    def test_alias_cannot_replace_an_artifact_derived_manifest_tag(self):
        result = self.run_build("--push", "--tag", "apme-" + SHA + "-" + self.pack_hash[7:19], ok=False)
        self.assertIn("reserved", result.stderr)
        self.assertFalse(any(c[0] == "push" for c in self.calls()))

    def test_replay_verifies_recorded_digest_and_source(self):
        self.env.update(APME_SOURCE_SHA=SHA, APME_PACK_SHA256=self.pack_hash,
                        APME_SOURCE_REPO="ansible/apme")
        self.run_build()
        self.assertIn("repos/ansible/apme/actions/runs", (self.work / "api.log").read_text())
        self.assertNotIn("repos/ansible/apme\n", (self.work / "api.log").read_text())

    def resolved_pack(self):
        resolved = self.work / "resolved pack"
        resolved.mkdir()
        shutil.copyfile(self.pack, resolved / "plugin-pack.tar.gz")
        (resolved / "artifact.env").write_text(
            "export APME_SOURCE_REPO=ansible/ansible-rhdh-plugins\n"
            f"export APME_SOURCE_SHA={SHA}\n"
            "export APME_RUN_ID=1 APME_ARTIFACT_ID=2 APME_ARTIFACT_NAME=plugins\n"
            "export APME_PACK_FILENAME=plugin-pack.tar.gz APME_PACK_FORMAT=npm\n"
            f"export APME_PACK_SHA256={self.pack_hash}\n")
        return resolved

    def test_resolved_pack_publishes_only_requested_architecture_without_fetch(self):
        resolved = self.resolved_pack()
        self.env.pop("GH_TOKEN")
        for arch in ("amd64", "arm64"):
            with self.subTest(arch=arch):
                (self.work / "podman.log").unlink(missing_ok=True)
                self.run_build("--pack-dir", str(resolved), "--architecture", arch, "--push")
                self.assertFalse((self.work / "api.log").exists())
                calls = self.calls()
                self.assertEqual([c[0] for c in calls], ["build", "image", "login", "push"])
                self.assertIn("--arch", calls[0])
                self.assertEqual(calls[0][calls[0].index("--arch") + 1], arch)
                self.assertEqual(calls[-1][-1], "docker://quay.io/aapdemo/apme-eap:apme-"
                                 + SHA + "-" + self.pack_hash[7:19] + "-" + arch)

    def test_resolved_pack_rejects_tampering_before_build_or_login(self):
        resolved = self.resolved_pack()
        with (resolved / "plugin-pack.tar.gz").open("ab") as pack:
            pack.write(b"changed")
        self.run_build("--pack-dir", str(resolved), "--architecture", "amd64", "--push", ok=False)
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.work / "api.log").exists())

    def test_architecture_rejects_invalid_values_and_unqualified_aliases(self):
        for args in (("--architecture", "x86"), ("--architecture", "amd64", "--tag", "latest")):
            with self.subTest(args=args):
                self.run_build(*args, ok=False)
                self.assertEqual(self.calls(), [])
                self.assertFalse((self.work / "api.log").exists())

    def test_changed_pack_fails_before_build_or_push(self):
        self.run_build("--source-ref", SHA, "--pack-sha256", DIGEST, "--push", ok=False)
        self.assertEqual(self.calls(), [])

    def test_invalid_options_fail_before_fetch(self):
        for args in (("--tag", "bad/tag"), ("--tag", "a" * 129), ("--tag", ""),
                     ("--source-ref", "main"), ("--source-repo", "invalid"),
                     ("--pack-sha256", "bad"), ("--tag",), ("--push=true",)):
            with self.subTest(args=args):
                self.run_build(*args, ok=False)
                self.assertFalse((self.work / "api.log").exists())

    def test_missing_quay_credentials_fails_before_fetch(self):
        self.env.pop("QUAY_TOKEN")
        self.run_build("--push", ok=False)
        self.assertFalse((self.work / "api.log").exists())

    def test_optional_redhat_login_uses_stdin_and_pipe_auth(self):
        self.env.update(REGISTRY_REDHAT_USERNAME="rh", REGISTRY_REDHAT_PASSWORD="redhat-test-secret")
        self.run_build()
        self.assertEqual([c[0] for c in self.calls()], ["login", "build", "image"])
        self.assertIn("--authfile", self.calls()[1])

    def test_failed_build_never_pushes(self):
        self.env["FAIL_COMMAND"] = "build"
        result = self.run_build("--push", ok=False)
        self.assertEqual(result.returncode, 42)
        self.assertEqual([c[0] for c in self.calls()], ["build"])

    def test_failed_login_never_pushes(self):
        self.env["FAIL_COMMAND"] = "login"
        result = self.run_build("--push", ok=False)
        self.assertEqual(result.returncode, 42)
        self.assertEqual([c[0] for c in self.calls()], ["build", "image", "login"])

    def test_failed_push_does_not_claim_publication(self):
        self.env["FAIL_COMMAND"] = "push"
        result = self.run_build("--push", ok=False)
        self.assertEqual(result.returncode, 42)
        self.assertNotIn("Published image:", result.stdout)

    def test_real_registry_client_can_read_environment_helper(self):
        if not self.env["REAL_AUTH_CLI"]:
            self.skipTest("Skopeo CLI unavailable")
        self.env["CHECK_REAL_AUTH"] = "yes"
        self.run_build("--push")

    def test_normalized_oci_pack_uses_ci_containerfile(self):
        self.env["APME_PACK_FORMAT"] = "oci"
        self.env["BASE_IMAGE"] = "registry.redhat.io/rhdh/rhdh-hub-rhel9@" + DIGEST
        layer = io.BytesIO()
        with tarfile.open(fileobj=layer, mode="w") as archive:
            for plugin in PLUGINS:
                content = json.dumps({"name": plugin}).encode()
                entry = tarfile.TarInfo(plugin + "/package.json")
                entry.size = len(content)
                archive.addfile(entry, io.BytesIO(content))
        with tarfile.open(self.pack, "w:gz") as archive:
            for name, content in (("layer.tar", layer.getvalue()),
                                  ("manifest.json", b'[{"Layers":["layer.tar"]}]')):
                entry = tarfile.TarInfo(name)
                entry.size = len(content)
                archive.addfile(entry, io.BytesIO(content))
        with zipfile.ZipFile(self.work / "artifact.zip", "w") as archive:
            archive.write(self.pack, "plugins.oci.tar.gz")
        self.run_build("--source-repo", "ansible/apme", "--source-ref", SHA)
        self.assertIn("PLUGIN_PACK_FORMAT=oci", self.calls()[0])
        self.assertIn("BASE_IMAGE=registry.redhat.io/rhdh/rhdh-hub-rhel9@" + DIGEST, self.calls()[0])
        self.assertTrue(any(arg.endswith("/Containerfile.ci") for arg in self.calls()[0]))


if __name__ == "__main__":
    unittest.main()
