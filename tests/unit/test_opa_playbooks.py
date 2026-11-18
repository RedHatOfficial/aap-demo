"""OPA playbook loading and bootstrap contract tests."""

from __future__ import annotations

import yaml

from aap_demo.addons.opa_playbooks import playbook_files, playbooks_root


def test_all_opa_playbooks_are_available() -> None:
    root = playbooks_root()
    assert all(
        (root / name).is_file()
        for name in (
            "bootstrap.yml",
            "load-policies.yml",
            "test-policies.yml",
            "clear-policies.yml",
            "demo-policy.yml",
        )
    )
    assert set(playbook_files()) == {
        "bootstrap.yml",
        "load-policies.yml",
        "test-policies.yml",
        "clear-policies.yml",
        "demo-policy.yml",
    }


def test_bootstrap_uses_uri_and_has_both_states() -> None:
    text = playbook_files()["bootstrap.yml"]
    documents = list(yaml.safe_load_all(text))
    assert "ansible.builtin.uri" in text
    assert "state == 'present'" in text
    assert "state == 'absent'" in text
    for name in (
        "OPA | Load Example Policies",
        "OPA | Test Policies",
        "OPA | Clear Policies",
        "OPA | Demo Policy",
    ):
        assert name in text
    assert "survey_enabled: true" in text
    assert "Attach AAP credential to demo policy template" in text
    assert "Read demo policy template credentials" in text
    assert "status_code: [200, 201, 204, 400]" not in text
    assert "Delete OPA credentials" in text
    assert "lookup('ansible.builtin.url'" not in text
    assert "aap_password" not in text.split("debug", 1)[-1]
    assert documents
