"""The demo archive is extracted without following links (ADR-045)."""

from __future__ import annotations

import io
import tarfile
from pathlib import Path

import pytest

from aap_demo.addons.ao.demos import import_demos


def _archive(path: Path, *, link: bool) -> None:
    with tarfile.open(path, "w:gz") as archive:
        data = b"{}"
        info = tarfile.TarInfo("repo/demos/ao/flow.json")
        info.size = len(data)
        archive.addfile(info, io.BytesIO(data))
        if link:
            evil = tarfile.TarInfo("repo/escape")
            evil.type = tarfile.SYMTYPE
            evil.linkname = "/tmp"
            archive.addfile(evil)


@pytest.mark.parametrize("link", [False, True])
def test_links_in_the_archive_are_refused(monkeypatch, tmp_path, link: bool) -> None:
    source = tmp_path / "upstream.tar.gz"
    _archive(source, link=link)
    monkeypatch.setattr(
        import_demos, "download_archive", lambda _url, dest: dest.write_bytes(source.read_bytes())
    )
    sources = import_demos.workflow_sources(None, "https://example.test/repo", "main")
    if link:
        with pytest.raises(RuntimeError, match="link"):
            with sources:
                pass
    else:
        with sources as root:
            assert (root / "demos" / "ao" / "flow.json").is_file()
