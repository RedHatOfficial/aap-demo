"""Tests for the APME OCI archive publisher."""

import importlib.util
from pathlib import Path
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "addons" / "apme-eap" / "scripts" / "push_oci_archive.py"
SPEC = importlib.util.spec_from_file_location("push_oci_archive", SCRIPT)
assert SPEC and SPEC.loader
PUSH_OCI_ARCHIVE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PUSH_OCI_ARCHIVE)


class RedirectingRegistryTests(unittest.TestCase):
    def test_registry_request_follows_route_redirect(self):
        with mock.patch.object(
            PUSH_OCI_ARCHIVE,
            "request",
            side_effect=[
                (
                    302,
                    {"Location": "https://registry.apps.127.0.0.1.nip.io/v2/apme/manifests/8593383"},
                    b"",
                ),
                (201, {}, b""),
            ],
        ) as request:
            status, _, _ = PUSH_OCI_ARCHIVE.request_with_redirects(
                "http",
                "registry.apps.127.0.0.1.nip.io",
                80,
                "PUT",
                "/v2/apme/manifests/8593383",
                headers={"Content-Type": "application/vnd.oci.image.manifest.v1+json"},
                body=b"manifest",
                verify_tls=False,
            )

        self.assertEqual(status, 201)
        request.assert_has_calls([
            mock.call(
                "http",
                "registry.apps.127.0.0.1.nip.io",
                80,
                "PUT",
                "/v2/apme/manifests/8593383",
                headers={"Content-Type": "application/vnd.oci.image.manifest.v1+json"},
                body=b"manifest",
                verify_tls=False,
            ),
            mock.call(
                "https",
                "registry.apps.127.0.0.1.nip.io",
                443,
                "PUT",
                "/v2/apme/manifests/8593383",
                headers={"Content-Type": "application/vnd.oci.image.manifest.v1+json"},
                body=b"manifest",
                verify_tls=False,
            ),
        ])

    def test_blob_upload_start_follows_registry_route_redirect(self):
        tar = mock.Mock(spec=tarfile.TarFile)
        source = mock.Mock()
        source.read.side_effect = [b"plugin-bytes", b""]
        tar.extractfile.return_value = source

        with mock.patch.object(
            PUSH_OCI_ARCHIVE,
            "blob_exists",
            return_value=False,
        ), mock.patch.object(
            PUSH_OCI_ARCHIVE,
            "request",
            side_effect=[
                (
                    302,
                    {"Location": "http://registry.internal:5000/v2/apme/blobs/uploads/"},
                    b"",
                ),
                (
                    202,
                    {"Location": "http://registry.internal:5000/v2/apme/blobs/uploads/upload-id"},
                    b"",
                ),
            ],
        ), mock.patch.object(PUSH_OCI_ARCHIVE, "connection") as connection:
            conn = connection.return_value
            response = mock.Mock()
            response.status = 201
            conn.getresponse.return_value = response

            PUSH_OCI_ARCHIVE.upload_blob(
                "https",
                "registry.apps.127.0.0.1.nip.io",
                443,
                "/v2/apme",
                "sha256:abc123",
                tar,
                "blobs/sha256/abc123",
                len(b"plugin-bytes"),
                False,
            )

        connection.assert_called_with("http", "registry.internal", 5000, False)
        conn.putrequest.assert_called_once_with(
            "PUT",
            "/v2/apme/blobs/uploads/upload-id?digest=sha256:abc123",
        )
        conn.send.assert_called_once_with(b"plugin-bytes")


class OciPushRoleTests(unittest.TestCase):
    @unittest.skipIf(shutil.which("ansible-playbook") is None, "ansible-playbook is not installed")
    def test_role_pushes_archive_to_plugin_image_repository(self):
        role_dir = SCRIPT.parents[1] / "playbooks" / "roles"
        with tempfile.TemporaryDirectory() as root:
            recorder = Path(root) / "record-argv.py"
            output = Path(root) / "argv.txt"
            archive = Path(root) / "plugin.oci.tar.gz"
            playbook = Path(root) / "playbook.yml"
            archive.write_bytes(b"placeholder")
            recorder.write_text(
                "#!/usr/bin/env python3\n"
                "import sys\n"
                f"open({str(output)!r}, 'w').write('\\n'.join(sys.argv[1:]))\n",
                encoding="utf-8",
            )
            recorder.chmod(0o755)
            playbook.write_text(
                "---\n"
                "- hosts: localhost\n"
                "  gather_facts: false\n"
                "  vars:\n"
                f"    collection_root: {SCRIPT.parents[1]}\n"
                "    plugin_sha: '8593383'\n"
                "    oci_registry: registry.example.test/apme\n"
                f"    apme_oci_tar_resolved: {archive}\n"
                f"    apme_oci_push_python_binary: {recorder}\n"
                "  roles:\n"
                "    - apme_oci_push\n",
                encoding="utf-8",
            )

            env = {
                **os.environ,
                "ANSIBLE_LOCAL_TEMP": str(Path(root) / "ansible-local"),
                "ANSIBLE_REMOTE_TEMP": str(Path(root) / "ansible-remote"),
                "ANSIBLE_ROLES_PATH": str(role_dir),
            }
            subprocess.run(
                ["ansible-playbook", "-i", "localhost,", "-c", "local", str(playbook)],
                check=True,
                env=env,
                capture_output=True,
                text=True,
            )

            argv = output.read_text(encoding="utf-8").splitlines()
        self.assertEqual(argv[argv.index("--repository") + 1], "apme/apme-prototype-plugins")


if __name__ == "__main__":
    unittest.main()
