"""``aap-demo version`` says when the install came from git or a local path."""

from __future__ import annotations

from aap_demo import __version__
from aap_demo.core import version as version_mod

SHA = "27b505d4c1e2f3a4b5c6d7e8f90123456789abcd"
GIT_RECORD = {
    "url": "https://github.com/RedHatOfficial/aap-demo.git",
    "vcs_info": {"vcs": "git", "commit_id": SHA, "requested_revision": "27b505d"},
}


def test_a_git_install_reports_the_commit_and_the_spec() -> None:
    assert version_mod.direct_source(GIT_RECORD) == {
        "mode": "git",
        "spec": "git+https://github.com/RedHatOfficial/aap-demo.git@27b505d",
        "sha": "27b505d",
    }


def test_a_git_install_without_a_ref_has_no_at_suffix() -> None:
    record = {"url": GIT_RECORD["url"], "vcs_info": {"vcs": "git", "commit_id": SHA}}
    assert version_mod.direct_source(record)["spec"] == f"git+{GIT_RECORD['url']}"


def test_a_local_path_install_is_reported_as_local() -> None:
    record = {"url": "file:///home/me/aap-demo", "dir_info": {"editable": True}}
    assert version_mod.direct_source(record) == {
        "mode": "local",
        "spec": "file:///home/me/aap-demo",
        "sha": "unknown",
    }


def test_an_index_install_has_no_direct_source() -> None:
    assert version_mod.direct_source({}) == {}


def test_version_text_for_a_git_install(monkeypatch) -> None:
    monkeypatch.setattr(version_mod, "_repo_root", lambda: None)
    monkeypatch.setattr(version_mod, "_direct_url", lambda: GIT_RECORD)

    info = version_mod.version_info()
    text = version_mod.render_text(info)

    assert info.install_mode == "git"
    assert info.version == __version__
    assert info.full_version == f"{__version__}+g27b505d"
    assert text.splitlines()[0] == f"aap-demo {__version__}+g27b505d"
    assert "from:     git+https://github.com/RedHatOfficial/aap-demo.git@27b505d" in text
    assert "not the published release" in text


def test_version_text_for_a_release_is_unchanged(monkeypatch) -> None:
    monkeypatch.setattr(version_mod, "_repo_root", lambda: None)
    monkeypatch.setattr(version_mod, "_direct_url", lambda: {})

    info = version_mod.version_info()
    text = version_mod.render_text(info)

    assert info.install_mode == "package"
    assert text.splitlines()[0] == f"aap-demo {__version__}"
    assert "from:" not in text
    assert "published release" not in text


def test_short_version_adds_the_commit_for_a_git_install(monkeypatch) -> None:
    monkeypatch.setattr(version_mod, "_direct_url", lambda: GIT_RECORD)
    assert version_mod.short_version() == f"{__version__}+g27b505d"
    monkeypatch.setattr(version_mod, "_direct_url", lambda: {})
    assert version_mod.short_version() == __version__


def test_unreadable_metadata_never_raises(monkeypatch) -> None:
    def boom(_name):
        raise RuntimeError("no metadata")

    monkeypatch.setattr(version_mod.metadata, "distribution", boom)
    assert version_mod.direct_source() == {}
