"""Local image cache uses the native V2 addon boundary."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import tarfile
from pathlib import Path

import pytest

from aap_demo.addons import get
from aap_demo.addons.local_cache import _image_patch
from aap_demo.cli.main import _addon_needs_cluster
from aap_demo.core.errors import AddonError
from aap_demo.exec.runner import CompletedCommand


def _args(*values: str) -> argparse.Namespace:
    return argparse.Namespace(addon="local-cache", addon_args=list(values))


def _valid_archive(path) -> None:
    with tarfile.open(path, "w") as archive:
        payload = b'{"imageLayoutVersion":"1.0.0"}\n'
        info = tarfile.TarInfo("oci-layout")
        info.size = len(payload)
        archive.addfile(info, io.BytesIO(payload))
        config = b'{"architecture":"amd64","os":"linux"}\n'
        config_digest = hashlib.sha256(config).hexdigest()
        info = tarfile.TarInfo(f"blobs/sha256/{config_digest}")
        info.size = len(config)
        archive.addfile(info, io.BytesIO(config))
        layer = b"layer"
        layer_digest = hashlib.sha256(layer).hexdigest()
        info = tarfile.TarInfo(f"blobs/sha256/{layer_digest}")
        info.size = len(layer)
        archive.addfile(info, io.BytesIO(layer))
        manifest = json.dumps(
            {
                "schemaVersion": 2,
                "config": {"digest": f"sha256:{config_digest}"},
                "layers": [{"digest": f"sha256:{layer_digest}"}],
            }
        ).encode()
        digest = hashlib.sha256(manifest).hexdigest()
        index = json.dumps(
            {"schemaVersion": 2, "manifests": [{"digest": f"sha256:{digest}"}]}
        ).encode()
        info = tarfile.TarInfo("index.json")
        info.size = len(index)
        archive.addfile(info, io.BytesIO(index))
        info = tarfile.TarInfo(f"blobs/sha256/{digest}")
        info.size = len(manifest)
        archive.addfile(info, io.BytesIO(manifest))
    return digest


def test_local_cache_is_registered_as_native_addon() -> None:
    addon = get("local-cache")
    assert addon.kind == "native"
    assert addon.public is True
    assert addon.needs_cluster is True


def test_host_only_cache_actions_skip_cluster_preflight() -> None:
    assert not _addon_needs_cluster("enable", _args("clear"))
    assert not _addon_needs_cluster("enable", _args("validate"))
    assert not _addon_needs_cluster("disable", _args())
    assert _addon_needs_cluster("enable", _args("load"))


def test_validate_accepts_a_complete_archive(app_ctx) -> None:
    cache = app_ctx.paths.legacy_dir / "local-cache" / "microshift"
    cache.mkdir(parents=True)
    reference = "registry.example/aap@sha256:abc"
    archive = cache / f"{hashlib.md5(reference.encode(), usedforsecurity=False).hexdigest()}.tar"
    manifest_digest = _valid_archive(archive)
    stem = archive.with_suffix("")
    stem.with_suffix(".ref").write_text(reference, encoding="utf-8")
    stem.with_suffix(".local-ref").write_text(
        f"registry.example/aap@sha256:{manifest_digest}", encoding="utf-8"
    )
    (cache / ".format-version").write_text("4", encoding="utf-8")

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


def test_clear_uses_configured_preset_and_keeps_addon_enabled(app_ctx) -> None:
    cache = app_ctx.paths.legacy_dir / "local-cache"
    (cache / "openshift").mkdir(parents=True)
    (cache / "openshift" / "abc.tar").write_bytes(b"cache")
    (cache / "microshift").mkdir()
    app_ctx.config.set("crc.preset", "openshift")
    app_ctx.config.set("addons.enabled", ["local-cache", "fleet"])

    assert get("local-cache").enable(app_ctx, _args("clear")) == 0
    assert not (cache / "openshift").exists()
    assert (cache / "microshift").exists()
    assert app_ctx.config.get("addons.enabled") == ["local-cache", "fleet"]


def test_image_patch_only_changes_matching_container() -> None:
    item = {
        "spec": {
            "template": {
                "spec": {
                    "containers": [
                        {"image": "registry.example/a@sha256:old", "imagePullPolicy": "Always"},
                        {"image": "unrelated:latest", "imagePullPolicy": "Always"},
                    ]
                }
            }
        }
    }

    patch = _image_patch(item, "registry.example/a@sha256:old", "registry.example/a@sha256:new")

    assert patch == [
        {
            "op": "replace",
            "path": "/spec/template/spec/containers/0/image",
            "value": "registry.example/a@sha256:new",
        },
        {
            "op": "replace",
            "path": "/spec/template/spec/containers/0/imagePullPolicy",
            "value": "IfNotPresent",
        },
    ]


def test_valid_archive_requires_an_oci_manifest(tmp_path) -> None:
    from aap_demo.addons.local_cache import _valid_oci_archive

    archive = tmp_path / "empty.tar"
    with tarfile.open(archive, "w") as tar:
        payload = b'{"imageLayoutVersion":"1.0.0"}\n'
        info = tarfile.TarInfo("oci-layout")
        info.size = len(payload)
        tar.addfile(info, io.BytesIO(payload))

    assert not _valid_oci_archive(archive)


def test_validate_rejects_a_digest_sidecar_for_another_manifest(app_ctx) -> None:
    cache = app_ctx.paths.legacy_dir / "local-cache" / "microshift"
    cache.mkdir(parents=True)
    reference = "registry.example/aap@sha256:abc"
    archive = cache / f"{hashlib.md5(reference.encode(), usedforsecurity=False).hexdigest()}.tar"
    _valid_archive(archive)
    stem = archive.with_suffix("")
    stem.with_suffix(".ref").write_text(reference, encoding="utf-8")
    stem.with_suffix(".local-ref").write_text(
        "registry.example/aap@sha256:" + "0" * 64, encoding="utf-8"
    )
    (cache / ".format-version").write_text("4", encoding="utf-8")

    with pytest.raises(AddonError, match="Cache validation failed"):
        get("local-cache").enable(app_ctx, _args("validate"))


def test_save_recovers_missing_digest_sidecar_before_pruning(app_ctx) -> None:
    cache = app_ctx.paths.legacy_dir / "local-cache" / "microshift"
    cache.mkdir(parents=True)
    reference = "registry.redhat.io/aap@sha256:abc"
    archive = (
        cache
        / f"{hashlib.md5((reference + chr(10)).encode(), usedforsecurity=False).hexdigest()}.tar"
    )
    _valid_archive(archive)
    archive.with_suffix(".ref").write_text(reference, encoding="utf-8")
    (cache / ".format-version").write_text("4", encoding="utf-8")

    image_json = json.dumps({"images": [{"repoDigests": [reference]}]})

    def ssh_result(argv):
        if "skopeo copy" in " ".join(argv):
            return CompletedCommand(argv=tuple(argv), returncode=1, stderr="export failed")
        return CompletedCommand(argv=tuple(argv), returncode=0, stdout=image_json)

    app_ctx.runner.register("ssh", ssh_result)
    with tarfile.open(archive) as tar:
        index = json.loads(tar.extractfile("index.json").read())
        digest = index["manifests"][0]["digest"]
        raw_manifest = tar.extractfile(f"blobs/{digest.replace(':', '/', 1)}").read().decode()
    app_ctx.runner.ok("skopeo inspect", stdout=raw_manifest)

    assert get("local-cache")._save(app_ctx, Path("/tmp/key")) == 0
    assert archive.is_file()
    assert archive.with_suffix(".ref").is_file()
    assert archive.with_suffix(".local-ref").is_file()
