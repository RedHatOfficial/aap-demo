"""The AO sync job gets its token from an AAP credential, not from launch extra_vars."""

from __future__ import annotations

import re
import urllib.parse
from typing import Any

import pytest

from aap_demo.addons.ao.demos import provision

TOKEN = "ao-secret-token"


class FakeAAP:
    """Just enough of the controller API for the AO control-plane path of main()."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, str, Any]] = []
        self.credential_types: list[dict[str, Any]] = []
        self.credentials: list[dict[str, Any]] = []
        self.templates: list[dict[str, Any]] = []
        self.attached: dict[int, list[int]] = {}
        self.next_id = 100

    def _new_id(self) -> int:
        self.next_id += 1
        return self.next_id

    def find(self, endpoint: str, name: str) -> dict[str, Any] | None:
        query = urllib.parse.urlencode({"name": name})
        return next(iter(self.request(f"/{endpoint}/?{query}").get("results", [])), None)

    def wait_for_project_sync(self, project_id: int, timeout: int = 180) -> None:
        return None

    def request(self, path: str, method: str = "GET", payload: Any = None) -> Any:
        self.calls.append((method, path, payload))
        route, _, raw_query = path.partition("?")
        query = dict(urllib.parse.parse_qsl(raw_query))
        if route == "/organizations/":
            return {"results": [{"id": 1, "name": "Default"}]}
        if route == "/inventories/":
            return {"results": [{"id": 2}]}
        if route == "/projects/":
            return {"results": []} if method == "GET" else {"id": self._new_id()}
        if route == "/credential_types/":
            if method == "POST":
                created = {"id": self._new_id(), **payload}
                self.credential_types.append(created)
                return created
            return {"results": [t for t in self.credential_types if t["name"] == query["name"]]}
        if route == "/credentials/":
            if method == "POST":
                created = {"id": self._new_id(), **payload}
                self.credentials.append(created)
                return created
            return {
                "results": [
                    c
                    for c in self.credentials
                    if c["name"] == query["name"]
                    and str(c["credential_type"]) == query["credential_type"]
                    and str(c["organization"]) == query["organization"]
                ]
            }
        found = re.fullmatch(r"/credentials/(\d+)/", route)
        if found and method == "PATCH":
            credential = next(c for c in self.credentials if c["id"] == int(found[1]))
            credential.update(payload)
            return credential
        if route == "/job_templates/":
            if method == "POST":
                created = {"id": self._new_id(), **payload}
                self.templates.append(created)
                return created
            name = query.get("name")
            return {"results": [t for t in self.templates if name in (None, t["name"])]}
        found = re.fullmatch(r"/job_templates/(\d+)/credentials/", route)
        if found:
            attached = self.attached.setdefault(int(found[1]), [])
            if method == "POST":
                attached.append(payload["id"])
                return {}
            return {"results": [{"id": i} for i in attached]}
        if re.fullmatch(r"/job_templates/\d+/launch/", route):
            return {"job": 7}
        if route == "/jobs/7/":
            return {"status": "successful"}
        if re.fullmatch(r"/(projects|job_templates)/\d+/", route):
            return {}
        raise AssertionError(f"unexpected request {method} {path}")


def run_main(fake: FakeAAP, monkeypatch: pytest.MonkeyPatch, token: str = TOKEN) -> int:
    monkeypatch.setattr(provision, "AAP", lambda *_a, **_k: fake)
    monkeypatch.setattr(provision.time, "sleep", lambda _s: None)
    return provision.main(
        [
            "--route",
            "aap.example",
            "--token",
            "aap-token",
            "--ao-api-url",
            "https://ao.example/api/v1",
            "--ao-api-host",
            "ao.example",
            "--ao-token",
            token,
            "--ao-credential-id",
            "3",
            "--ao-integration-id",
            "4",
        ]
    )


def control_template(fake: FakeAAP) -> dict[str, Any]:
    return next(t for t in fake.templates if t["name"] == provision.CONTROL_TEMPLATE_NAME)


def launches(fake: FakeAAP) -> list[Any]:
    return [payload for method, path, payload in fake.calls if path.endswith("/launch/")]


def test_the_token_is_not_sent_as_a_launch_extra_var(monkeypatch):
    fake = FakeAAP()
    assert run_main(fake, monkeypatch) == 0
    (launch,) = launches(fake)
    assert "ao_api_token" not in launch["extra_vars"]
    assert TOKEN not in repr(launch)
    assert "ao_api_token" not in provision.control_job_extra_vars(
        provision.argparse.Namespace(
            ao_api_url="u",
            ao_api_host="h",
            ao_token=TOKEN,
            ao_demo_ref="r",
            ao_demo_repository="https://example/repo.git",
            ao_credential_id="",
            ao_integration_id="",
            ao_agent_credential_id="",
            ao_agent_integration_id="",
            ao_agent_model_id="",
        )
    )


def test_a_credential_injects_the_token_into_the_sync_job(monkeypatch):
    fake = FakeAAP()
    run_main(fake, monkeypatch)
    (kind,) = fake.credential_types
    assert kind["name"] == provision.AO_CREDENTIAL_TYPE_NAME
    assert kind["kind"] == "cloud"
    assert kind["injectors"] == {"extra_vars": {"ao_api_token": "{{ token }}"}}
    (field,) = kind["inputs"]["fields"]
    assert field["id"] == "token" and field["secret"] is True
    (credential,) = fake.credentials
    assert credential["credential_type"] == kind["id"]
    assert credential["organization"] == 1
    assert credential["inputs"] == {"token": TOKEN}
    assert fake.attached[control_template(fake)["id"]] == [credential["id"]]


def test_the_credential_is_attached_before_the_job_launches(monkeypatch):
    fake = FakeAAP()
    run_main(fake, monkeypatch)
    paths = [(method, path) for method, path, _payload in fake.calls]
    template_id = control_template(fake)["id"]
    attach = paths.index(("POST", f"/job_templates/{template_id}/credentials/"))
    launch = paths.index(("POST", f"/job_templates/{template_id}/launch/"))
    assert attach < launch


def test_a_rerun_updates_the_token_and_reuses_the_credential(monkeypatch):
    fake = FakeAAP()
    run_main(fake, monkeypatch)
    run_main(fake, monkeypatch, token="rotated-token")
    assert len(fake.credential_types) == 1
    (credential,) = fake.credentials
    assert credential["inputs"] == {"token": "rotated-token"}
    assert fake.attached[control_template(fake)["id"]] == [credential["id"]]


@pytest.mark.parametrize(
    "inputs, injectors",
    [
        (provision.AO_CREDENTIAL_TYPE_INPUTS, {"env": {"AO_TOKEN": "{{ token }}"}}),
        (
            {"fields": [{"id": "token", "label": "AO API token", "type": "string"}]},
            provision.AO_CREDENTIAL_TYPE_INJECTORS,
        ),
        (
            {
                "fields": [
                    {"id": "token", "label": "AO API token", "type": "string", "secret": False}
                ],
                "required": ["token"],
            },
            provision.AO_CREDENTIAL_TYPE_INJECTORS,
        ),
        (
            {
                "fields": [
                    *provision.AO_CREDENTIAL_TYPE_INPUTS["fields"],
                    {"id": "extra", "label": "Extra", "type": "string"},
                ],
                "required": ["token"],
            },
            provision.AO_CREDENTIAL_TYPE_INJECTORS,
        ),
    ],
    ids=["other-injector", "token-not-secret", "token-secret-false", "extra-input"],
)
def test_a_same_named_type_aap_demo_did_not_create_stops(monkeypatch, inputs, injectors):
    fake = FakeAAP()
    fake.credential_types.append(
        {
            "id": 50,
            "name": provision.AO_CREDENTIAL_TYPE_NAME,
            "inputs": inputs,
            "injectors": injectors,
        }
    )
    with pytest.raises(RuntimeError, match="is not the one aap-demo creates"):
        run_main(fake, monkeypatch)
    assert not fake.credentials
    assert not launches(fake)


def test_a_same_named_credential_in_another_organization_is_left_alone(monkeypatch):
    fake = FakeAAP()
    run_main(fake, monkeypatch)
    (ours,) = fake.credentials
    other = {**ours, "id": 900, "organization": 2, "inputs": {"token": "theirs"}}
    fake.credentials.insert(0, other)
    run_main(fake, monkeypatch, token="rotated-token")
    assert other["inputs"] == {"token": "theirs"} and other["organization"] == 2
    assert ours["inputs"] == {"token": "rotated-token"}


def test_the_playbook_still_reads_ao_api_token():
    playbook = (
        provision.Path(__file__).resolve().parents[2] / provision.CONTROL_PLAYBOOK
    ).read_text(encoding="utf-8")
    assert "ao_api_token | length > 0" in playbook


@pytest.mark.parametrize(
    "route",
    ["/credentials/", "/job_templates/{id}/credentials/"],
    ids=["credential-lookup", "attached-lookup"],
)
def test_a_credential_list_without_results_stops(monkeypatch, route):
    fake = FakeAAP()
    answer = fake.request

    def request(path: str, method: str = "GET", payload: Any = None) -> Any:
        listing = path.partition("?")[0]
        if method == "GET" and re.fullmatch(route.replace("{id}", r"\d+"), listing):
            return {"detail": "unexpected"}
        return answer(path, method, payload)

    fake.request = request  # type: ignore[method-assign]
    with pytest.raises(RuntimeError, match="no results list"):
        run_main(fake, monkeypatch)
    assert not launches(fake)
