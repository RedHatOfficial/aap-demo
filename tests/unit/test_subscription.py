"""Applying a subscription manifest only when the user has agreed to."""

from __future__ import annotations

import io
import json
import os
import urllib.error
from pathlib import Path
from typing import Any, Dict, List

import pytest

from aap_demo.cluster import subscription
from aap_demo.core.context import AppContext

SECRET_BYTES = b"manifest-contents"


class _Response(io.BytesIO):
    status = 200

    def __enter__(self) -> "_Response":
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()


class _Api:
    def __init__(self, *, licensed: bool = False, post: Any = None, get: Any = None) -> None:
        self.licensed = licensed
        self.post = post
        self.get = get
        self.posts: List[Dict[str, Any]] = []

    def __call__(self, request: Any, **_: Any) -> Any:
        if request.data is None:
            if isinstance(self.get, Exception):
                raise self.get
            info = {"valid_key": True} if self.licensed else {}
            return _Response(json.dumps({"license_info": info}).encode())
        self.posts.append(json.loads(request.data))
        if isinstance(self.post, Exception):
            raise self.post
        return _Response(json.dumps({"valid_key": True, "subscription_name": "AAP"}).encode())


@pytest.fixture
def ready(app_ctx: AppContext, monkeypatch: pytest.MonkeyPatch) -> AppContext:
    monkeypatch.setattr(subscription.ssl, "create_default_context", lambda **_: None)
    app_ctx.paths.ingress_ca.parent.mkdir(parents=True, exist_ok=True)
    app_ctx.paths.ingress_ca.write_text("ca")
    app_ctx.env = {"AAP_DEMO_INTERACTIVE": "0"}
    monkeypatch.setattr(subscription.prompts, "can_ask", lambda env: False)
    return app_ctx


def _manifest(folder: Path, name: str = "manifest_x_1.zip", age: int = 0) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / name
    path.write_bytes(SECRET_BYTES)
    path.chmod(0o600)
    os.utime(path, (1000 - age, 1000 - age))
    return path


def _run(ctx: AppContext, api: _Api, answer: str = "") -> None:
    subscription.ensure(
        ctx,
        route="aap.test",
        password="pw",  # pragma: allowlist secret
        opener=api,
        read=lambda _q: answer,
    )


def test_explicit_path_wins_and_is_not_replaced(app_ctx: AppContext, tmp_path: Path) -> None:
    _manifest(app_ctx.paths.config_dir)
    explicit = _manifest(tmp_path / "other", "anything.zip")
    assert subscription.locate(str(explicit), app_ctx.paths) == explicit
    assert subscription.locate(str(tmp_path / "gone.zip"), app_ctx.paths) is None


def test_config_folder_comes_first_and_newest_wins(app_ctx: AppContext) -> None:
    _manifest(app_ctx.paths.state_dir, "manifest_state.zip")
    old = _manifest(app_ctx.paths.config_dir, "manifest_old.zip", age=50)
    new = _manifest(app_ctx.paths.config_dir, "manifest_new.zip")
    assert subscription.locate("", app_ctx.paths) == new
    old.unlink()
    new.unlink()
    assert subscription.locate("", app_ctx.paths).name == "manifest_state.zip"


def test_the_older_command_folder_is_searched_last(app_ctx: AppContext) -> None:
    legacy = _manifest(app_ctx.paths.legacy_dir, "manifest_legacy.zip")
    assert subscription.locate("", app_ctx.paths) == legacy
    state = _manifest(app_ctx.paths.state_dir, "manifest_state.zip", age=50)
    assert subscription.locate("", app_ctx.paths) == state


def test_a_licensed_aap_is_left_alone(ready: AppContext) -> None:
    _manifest(ready.paths.config_dir)
    ready.config.set("deploy.auto_license", True)
    api = _Api(licensed=True)
    _run(ready, api)
    assert api.posts == []


def test_off_by_default_without_a_terminal(ready: AppContext) -> None:
    _manifest(ready.paths.config_dir)
    api = _Api()
    _run(ready, api)
    assert api.posts == []
    assert "--auto-license" in ready.console.stdout + ready.console.stderr


def test_yes_does_not_agree_to_spend_a_license(
    ready: AppContext, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(subscription.prompts, "can_ask", lambda env: True)
    ready.assume_yes = True
    _manifest(ready.paths.config_dir)
    api = _Api()
    _run(ready, api, answer="y")
    assert api.posts == []


@pytest.mark.parametrize(("answer", "applied"), [("", False), ("n", False), ("y", True)])
def test_the_prompt_defaults_to_no(
    ready: AppContext, monkeypatch: pytest.MonkeyPatch, answer: str, applied: bool
) -> None:
    monkeypatch.setattr(subscription.prompts, "can_ask", lambda env: True)
    _manifest(ready.paths.config_dir)
    api = _Api()
    _run(ready, api, answer=answer)
    assert bool(api.posts) is applied


def test_auto_license_applies_without_asking(ready: AppContext) -> None:
    ready.config.set("deploy.auto_license", True)
    _manifest(ready.paths.config_dir)
    api = _Api()
    subscription.ensure(
        ready,
        route="aap.test",
        password="pw",  # pragma: allowlist secret
        opener=api,
        read=lambda _q: pytest.fail("must not ask"),
    )
    assert api.posts[0]["eula_accepted"] is True
    assert "Subscription applied: AAP" in ready.console.stdout


def test_no_manifest_says_where_to_put_one(ready: AppContext) -> None:
    api = _Api()
    _run(ready, api)
    text = ready.console.stdout + ready.console.stderr
    assert "--manifest PATH" in text and "subscription_allocations" in text


def test_a_rejected_manifest_warns_and_does_not_fail(ready: AppContext) -> None:
    ready.config.set("deploy.auto_license", True)
    _manifest(ready.paths.config_dir)
    rejected = urllib.error.HTTPError(
        "u",
        400,
        "Bad",
        None,
        io.BytesIO(b'{"error": "Invalid subscription"}'),  # type: ignore[arg-type]
    )
    _run(ready, _Api(post=rejected))
    text = ready.console.stdout + ready.console.stderr
    assert "Invalid subscription" in text and "active today" in text


def test_a_network_error_never_shows_the_manifest(ready: AppContext) -> None:
    ready.config.set("deploy.auto_license", True)
    _manifest(ready.paths.config_dir)
    _run(ready, _Api(post=OSError("boom manifest-contents")))
    text = ready.console.stdout + ready.console.stderr
    assert "Could not apply" in text and "manifest-contents" not in text


def test_loose_permissions_warn(ready: AppContext) -> None:
    path = _manifest(ready.paths.config_dir)
    path.chmod(0o644)
    _run(ready, _Api())
    assert "chmod 600" in ready.console.stdout + ready.console.stderr


def test_without_the_ingress_ca_nothing_is_sent(ready: AppContext) -> None:
    ready.paths.ingress_ca.unlink()
    api = _Api()
    _run(ready, api)
    assert api.posts == []


def test_a_failed_subscription_read_applies_nothing(ready: AppContext) -> None:
    ready.config.set("deploy.auto_license", True)
    _manifest(ready.paths.config_dir)
    api = _Api(get=urllib.error.HTTPError("u", 503, "Down", None, io.BytesIO(b"{}")))  # type: ignore[arg-type]
    _run(ready, api)
    assert api.posts == []
    assert "HTTP 503" in ready.console.stdout + ready.console.stderr


def test_redirects_are_not_followed() -> None:
    handler = subscription._NoRedirect()
    assert handler.redirect_request(None, None, 307, "", {}, "https://other.example/") is None
