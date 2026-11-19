"""OPA native Kubernetes resource rendering."""

from __future__ import annotations

import pytest

from aap_demo.addons.opa_resources import OWNER, owned, resource_documents


def test_resources_have_expected_kinds_image_and_route() -> None:
    docs = resource_documents("aap-operator", "1.20.2", "opa.apps.example.test")
    assert [(d["kind"], d["metadata"]["name"]) for d in docs] == [
        ("Deployment", "opa"),
        ("Service", "opa"),
        ("Route", "opa"),
    ]
    assert docs[0]["metadata"]["labels"]["app.kubernetes.io/managed-by"] == OWNER
    container = docs[0]["spec"]["template"]["spec"]["containers"][0]
    assert container["image"] == "openpolicyagent/opa:1.20.2"
    assert container["ports"] == [{"name": "http", "containerPort": 8181}]
    assert docs[2]["spec"]["host"] == "opa.apps.example.test"


def test_ownership_requires_both_labels() -> None:
    doc = resource_documents("aap-operator", "1.20.2", "opa.apps.example.test")[0]
    assert owned(doc)
    doc["metadata"]["labels"]["app.kubernetes.io/managed-by"] = "other"
    assert not owned(doc)


@pytest.mark.parametrize("version", ["", "1.20.2\n", "../../bad"])
def test_invalid_image_version_is_rejected(version: str) -> None:
    with pytest.raises(ValueError, match="OPA version"):
        resource_documents("aap-operator", version, "opa.apps.example.test")
