"""Local image cache uses the native V2 addon boundary."""

from __future__ import annotations

import argparse
import io
import tarfile

from aap_demo.addons import get


def _args(*values: str) -> argparse.Namespace:
    return argparse.Namespace(addon="local-cache", addon_args=list(values))


def _valid_archive(path) -> None:
    with tarfile.open(path, "w") as archive:
        payload = b'{"imageLayoutVersion":"1.0.0"}\n'
        info = tarfile.TarInfo("oci-layout")
        info.size = len(payload)
        archive.addfile(info, io.BytesIO(payload))


def test_local_cache_is_registered_as_native_addon() -> None:
    addon = get("local-cache")
    assert addon.kind == "native"
    assert addon.public is True
    assert addon.needs_cluster is True


def test_validate_accepts_a_complete_archive(app_ctx) -> None:
    cache = app_ctx.paths.legacy_dir / "local-cache" / "microshift"
    cache.mkdir(parents=True)
    archive = cache / "abc.tar"
    _valid_archive(archive)
    (cache / "abc.ref").write_text("registry.example/aap@sha256:abc", encoding="utf-8")
    (cache / "abc.local-ref").write_text("registry.example/aap@sha256:def", encoding="utf-8")

    assert get("local-cache").enable(app_ctx, _args("validate")) == 0
    assert "Cache validation passed: 1 archive" in app_ctx.console.stdout


def test_disable_clears_only_the_selected_preset(app_ctx) -> None:
    cache = app_ctx.paths.legacy_dir / "local-cache"
    (cache / "microshift").mkdir(parents=True)
    (cache / "microshift" / "abc.tar").write_bytes(b"cache")
    (cache / "other-preset").mkdir()
    app_ctx.config.set("addons.enabled", ["local-cache", "fleet"])

    assert get("local-cache").disable(app_ctx, argparse.Namespace(addon="local-cache")) == 0
    assert not (cache / "microshift").exists()
    assert (cache / "other-preset").exists()
    assert app_ctx.config.get("addons.enabled") == ["fleet"]
