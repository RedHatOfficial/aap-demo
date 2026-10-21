"""Exercise the deployment roles against local files and container-command doubles."""

import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons/apme-eap"
ROLES = ADDON / "playbooks/roles"
DIGEST = "sha256:" + "a" * 64
PLUGIN_NAMES = (
    "ansible-plugin-scaffolder-backend-module-backstage-rhaap",
    "ansible-backstage-plugin-catalog-backend-module-rhaap",
    "ansible-plugin-backstage-self-service",
    "ansible-backstage-plugin-auth-backend-module-rhaap-provider",
    "ansible-plugin-backstage-apme",
    "ansible-backstage-plugin-catalog-backend-module-apme",
)


class InstalledPluginTests(unittest.TestCase):
    def test_complete_pack_passes_but_missing_or_wrong_identity_fails(self):
        validate = runpy.run_path(str(ROLES / "apme_preloaded_image/files/verify_plugins.py"))["validate"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in PLUGIN_NAMES:
                (root / name).mkdir()
                (root / name / "package.json").write_text(json.dumps({"name": name + "-dynamic"}))
            validate(root)
            (root / PLUGIN_NAMES[-1] / "package.json").unlink()
            with self.assertRaisesRegex(ValueError, "missing or invalid package.json"):
                validate(root)
            (root / PLUGIN_NAMES[-1] / "package.json").write_text('{"name":"wrong-plugin"}')
            with self.assertRaisesRegex(ValueError, "invalid package.json identity"):
                validate(root)


class SavedImageSettingsTests(unittest.TestCase):
    def test_scalar_quoting_is_preserved_and_empty_reference_selects_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            variables = Path(directory) / "vars.yml"
            variables.write_text('apme_preloaded_image_ref: "" # use local build\n'
                                 'apme_preloaded_image_auth_file: "/path with spaces/auth.json"\n')
            result = subprocess.run(
                ["bash", "-c", 'source "$1"; apme_saved_yaml_value "$2" apme_preloaded_image_auth_file \'""\'; '
                 'if apme_preloaded_image_selected "$2"; then exit 1; fi', "test", str(ADDON / "lib.sh"), str(variables)],
                env={**os.environ, "APME_PRELOADED_IMAGE_REF": ""}, text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), '"/path with spaces/auth.json"')


@unittest.skipIf(shutil.which("ansible-playbook") is None, "ansible-playbook is not installed")
class DeploymentImageTests(unittest.TestCase):
    def run_roles(self, variables, roles, check=False, tasks=None, prepare=None, run_exit=0):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            if prepare:
                prepare(work)
            recorder = work / "container-command"
            recorder.write_text(
                "#!/usr/bin/env python3\nimport json, sys\n"
                f"with open({str(work / 'commands')!r}, 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                f"print(json.dumps({{'Digest': {DIGEST!r}}}) if 'inspect' in sys.argv else 'validated six plugins')\n"
                f"sys.exit({run_exit} if sys.argv[1] == 'run' else 0)\n"
            )
            recorder.chmod(0o755)
            defaults = {
                "collection_root": str(ADDON),
                "apme_portal_helm_values_path": str(work / "values.yml"),
                "ansible_python_interpreter": "{{ ansible_playbook_python }}",
                "ansible_architecture": "x86_64",
                "openshift_project_name": "apme",
                "openshift_cluster_domain": "apps.example.test",
                "openshift_api_url": "https://api.example.test:6443",
                "aap_host": "https://aap.example.test",
                "configure_github_secrets": False,
                "apme_preloaded_image_skopeo_binary": str(recorder),
                "apme_preloaded_image_podman_binary": str(recorder),
                "apme_image_build_skopeo_binary": str(recorder),
                "apme_image_build_podman_binary": str(recorder),
                **variables,
            }
            play = {"name": "Test image deployment", "hosts": "localhost", "gather_facts": False,
                    "vars": defaults, "roles": roles}
            if tasks:
                play["tasks"] = tasks
            playbook = work / "play.yml"
            playbook.write_text(yaml.safe_dump([play]))
            result = subprocess.run(
                ["ansible-playbook", "-i", "localhost,", "-c", "local", str(playbook)]
                + (["--check"] if check else []),
                env={**os.environ, "ANSIBLE_ROLES_PATH": str(ROLES),
                     "ANSIBLE_COLLECTIONS_PATH": str(work / "collections") + os.pathsep
                     + os.environ.get("ANSIBLE_COLLECTIONS_PATH", str(Path.home() / ".ansible/collections")),
                     "ANSIBLE_LOCAL_TEMP": str(work / "local"),
                     "ANSIBLE_REMOTE_TEMP": str(work / "remote"), "ANSIBLE_NOCOLOR": "1"},
                text=True, capture_output=True,
            )
            output = result.stdout + result.stderr
            values = yaml.safe_load((work / "values.yml").read_text()) \
                if result.returncode == 0 and (work / "values.yml").exists() else None
            commands = [json.loads(line) for line in (work / "commands").read_text().splitlines()] \
                if (work / "commands").exists() else []
            return result.returncode, output, values, commands

    def test_tag_image_renders_all_six_local_plugins_and_never_builds(self):
        rc, output, values, commands = self.run_roles(
            {"apme_preloaded_image_ref": "quay.io/aapdemo/apme-eap:release-1"},
            ["apme_preloaded_image", "apme_helm_values"],
        )
        self.assertEqual(rc, 0, output)
        image = values["redhat-developer-hub"]["upstream"]["backstage"]["image"]
        self.assertEqual(image["registry"], "quay.io")
        self.assertEqual(image["repository"], "aapdemo/apme-eap")
        self.assertEqual(image["digest"], DIGEST)
        plugins = values["redhat-developer-hub"]["global"]["dynamic"]["plugins"]
        self.assertEqual(sum(p["package"].startswith("./dynamic-plugins/dist/ansible-") for p in plugins), 6)
        self.assertFalse(any(p["package"].startswith("oci://") for p in plugins))
        self.assertTrue(any(c[0] == "run" and "quay.io/aapdemo/apme-eap@" + DIGEST in c for c in commands))
        self.assertFalse(any(c[0] == "build" for c in commands))

    def test_digest_preserved_without_remote_inspection_in_check_mode(self):
        ref = "registry.example.test:5000/team/apme@" + DIGEST
        rc, output, _, commands = self.run_roles(
            {"apme_preloaded_image_ref": ref}, ["apme_preloaded_image"], check=True,
            tasks=[{"name": "Check parsed digest", "ansible.builtin.assert": {"that": [
                "apme_preloaded_registry == 'registry.example.test:5000'",
                "apme_preloaded_repository == 'team/apme'",
                "apme_preloaded_digest == '" + DIGEST + "'",
                "apme_preloaded_tag == ''",
                "not apme_preloaded_image_validated",
            ]}}],
        )
        self.assertEqual(rc, 0, output)
        self.assertEqual(commands, [])

    def test_unqualified_or_malformed_image_fails_before_container_commands(self):
        for ref in ("apme:latest", "team/apme:latest", "quay.io/team/apme", "quay.io/team/apme@sha256:abc", "https://quay.io/team/apme:latest"):
            with self.subTest(ref=ref):
                rc, output, _, commands = self.run_roles({"apme_preloaded_image_ref": ref}, ["apme_preloaded_image"])
                self.assertNotEqual(rc, 0, output)
                self.assertIn(ref, output)
                self.assertEqual(commands, [])

    def test_fallback_requires_resolved_pack_even_in_check_mode(self):
        rc, output, _, commands = self.run_roles(
            {"plugin_sha": "8593383", "oci_registry": "registry.example.test/apme"},
            ["apme_image_build"], check=True,
        )
        self.assertNotEqual(rc, 0, output)
        self.assertIn("apme_oci_tar_resolved", output)
        self.assertEqual(commands, [])

    def test_prebuilt_pack_resolution_does_not_require_bundled_archive(self):
        rc, output, _, _ = self.run_roles(
            {"collection_root": "/nonexistent", "apme_preloaded_image_ref": "quay.io/aapdemo/apme-eap:v1"}, [],
            tasks=[{"name": "Resolve deployment inputs", "ansible.builtin.include_tasks": str(ADDON / "playbooks/tasks/resolve_plugin_pack.yml")}],
            check=True,
        )
        self.assertEqual(rc, 0, output)

    def test_failed_plugin_check_stops_before_helm_rendering(self):
        rc, output, values, _ = self.run_roles(
            {"apme_preloaded_image_ref": "quay.io/aapdemo/apme-eap:v1", "apme_preloaded_image_verify": False},
            ["apme_preloaded_image", "apme_helm_values"], run_exit=1,
        )
        self.assertNotEqual(rc, 0, output)
        self.assertIsNone(values)
        self.assertNotIn("Copy portal Helm values template", output)

    def test_main_playbook_prebuilt_mode_skips_local_push_and_build(self):
        play = yaml.safe_load((ADDON / "playbooks/deploy_apme_portal.yml").read_text())[0]
        roles = [role for role in play["roles"] if role["role"] in (
            "apme_preloaded_image", "apme_oci_push", "apme_image_build"
        )]
        rc, output, _, commands = self.run_roles(
            {"apme_preloaded_image_ref": "quay.io/aapdemo/apme-eap:v1"}, roles, check=True,
        )
        self.assertEqual(rc, 0, output)
        self.assertEqual(commands, [])

    def test_local_build_uses_verified_normalized_pack_and_retains_registry_namespace(self):
        rc, output, values, commands = self.run_roles(
            {"plugin_sha": "8593383", "oci_registry": "registry.example.test/apme",
             "oci_registry_internal": "registry.svc:5000/apme", "apme_image_build_force": True,
             "apme_oci_tar_resolved": str(ADDON / "plugin_packs/apme-prototype-plugins-8593383-20260718025043.oci.tar.gz")},
            ["apme_image_build", "apme_helm_values"],
        )
        self.assertEqual(rc, 0, output)
        image = values["redhat-developer-hub"]["upstream"]["backstage"]["image"]
        self.assertEqual(image["registry"], "registry.svc:5000")
        self.assertEqual(image["repository"], "apme/rhdh-apme-preloaded")
        build = next(c for c in commands if c[0] == "build")
        self.assertIn("--build-arg=PLUGIN_PACK_FORMAT=oci", build)
        self.assertIn("--build-arg=PLUGIN_PACK_SHA256=sha256:943f67afce1f9d1852df09b74da0126ef73f861e1ffc066e5196cc3701f341c3", build)
        push = next(c for c in commands if c[0] == "copy")
        self.assertIn("docker://registry.example.test/apme/rhdh-apme-preloaded:8593383", push)

    def test_named_pull_secret_requires_explicit_credentials(self):
        rc, output, _, _ = self.run_roles(
            {"apme_preloaded_image_ref": "quay.io/aapdemo/apme-eap:v1",
             "apme_preloaded_image_pull_secret": "quay-pull", "apme_preloaded_image_auth_file": ""},
            ["apme_preloaded_image"], check=True,
        )
        self.assertNotEqual(rc, 0, output)
        self.assertIn("Set apme_preloaded_image_auth_file", output)

    def test_private_image_creates_scoped_pull_secret_and_renders_its_name(self):
        def prepare(work):
            (work / "auth.json").write_text(json.dumps({"auths": {
                "quay.io": {"auth": "ZGVtbzpkZW1v"}, "other.example": {"auth": "dW51c2Vk"}
            }}))
            module = work / "collections/ansible_collections/kubernetes/core/plugins/modules/k8s.py"
            module.parent.mkdir(parents=True)
            module.write_text(
                "from ansible.module_utils.basic import AnsibleModule\nimport json, base64\n"
                "def main():\n"
                "    m = AnsibleModule(argument_spec={k: {'type': 'raw'} for k in "
                "['state', 'api_key', 'kubeconfig', 'host', 'validate_certs', 'definition']}, supports_check_mode=True)\n"
                "    d = m.params['definition']\n"
                "    auth = json.loads(base64.b64decode(d['data']['.dockerconfigjson']))\n"
                "    if d['type'] != 'kubernetes.io/dockerconfigjson' or d['metadata'] != "
                "{'name': 'quay-pull', 'namespace': 'apme'} or auth != "
                "{'auths': {'quay.io': {'auth': 'ZGVtbzpkZW1v'}}}:\n"
                "        m.fail_json(msg='incorrect pull secret payload')\n"
                f"    with open({str(work / 'commands')!r}, 'a') as f: f.write('[\"secret-created\"]\\n')\n"
                "    m.exit_json(changed=False)\n"
                "if __name__ == '__main__': main()\n"
            )
            # The renderer parses (but must skip) MicroShift-only info tasks.
            module.with_name("k8s_info.py").write_text(
                "from ansible.module_utils.basic import AnsibleModule\n"
                "AnsibleModule(argument_spec={}).fail_json(msg='unexpected cluster lookup')\n"
            )

        rc, output, values, commands = self.run_roles(
            {"apme_preloaded_image_ref": "quay.io/aapdemo/apme-eap:v1",
             "apme_preloaded_image_pull_secret": "quay-pull",
             "apme_preloaded_image_auth_file": "{{ apme_portal_helm_values_path | dirname }}/auth.json"},
            ["apme_preloaded_image", "apme_helm_values"], prepare=prepare,
        )
        self.assertEqual(rc, 0, output)
        self.assertEqual(values["redhat-developer-hub"]["upstream"]["backstage"]["image"]["pullSecrets"], ["quay-pull"])
        self.assertIn(["secret-created"], commands)


if __name__ == "__main__":
    unittest.main()
