"""Native V2 local OCI image cache addon.

The cache is intentionally host-owned state.  CRC image-store operations go
through the shared runner/SSH seams; no shell installer is invoked.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import shutil
import tarfile
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

from aap_demo.addons.base import AddonKind
from aap_demo.addons.common.state import enabled_names, set_enabled_names
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError
from aap_demo.core.output import is_structured, render
from aap_demo.exec import ssh as ssh_mod

CACHE_FORMAT_VERSION = "4"
REMOTE_ARCHIVE = "/tmp/aap-demo-local-cache.oci"
REGISTRIES = ("registry.redhat.io", "registry.k8s.io")


class LocalCacheAddon:
    name = "local-cache"
    kind: AddonKind = "native"
    public = True
    needs_cluster = True

    def enable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        action = str((getattr(args, "addon_args", None) or ["save"])[0])
        if action in ("clear", "delete"):
            return self._clear(ctx)
        if action == "validate":
            return self._validate(ctx)
        if action == "catalog-ref":
            return self._catalog_ref(ctx, (getattr(args, "addon_args", None) or [])[1:])
        key = _ssh_key(ctx)
        if action == "load":
            return self._load(ctx, key)
        if action == "rewrite":
            return self._rewrite(ctx, key)
        if action in ("save", "deploy"):
            return self._save(ctx, key)
        raise AddonError(f"unknown local-cache action {action!r}")

    def disable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        del args
        return self._clear(ctx)

    def _clear(self, ctx: AppContext) -> int:
        cache = _cache_dir(ctx)
        if cache.exists():
            shutil.rmtree(cache)
            _say(ctx, f"Cleared image cache for {_preset(ctx)}")
        else:
            _say(ctx, f"No image cache found for {_preset(ctx)}")
        _forget_enabled(ctx)
        return 0

    def _validate(self, ctx: AppContext) -> int:
        cache = _cache_dir(ctx)
        if not cache.is_dir():
            raise AddonError(f"No image cache found for {_preset(ctx)}")
        checked = 0
        failed = 0
        for archive in sorted(cache.glob("*.tar")):
            checked += 1
            stem = archive.with_suffix("")
            valid = (
                _valid_oci_archive(archive)
                and (stem.with_suffix(".ref")).is_file()
                and (stem.with_suffix(".local-ref")).is_file()
            )
            if not valid:
                failed += 1
                ctx.console.err(f"Invalid cache entry: {archive.stem}")
        if not checked:
            raise AddonError(f"No cached image archives found for {_preset(ctx)}")
        if failed:
            raise AddonError(f"Cache validation failed: {failed}/{checked} archive(s) invalid")
        _say(ctx, f"Cache validation passed: {checked} archive(s) valid")
        return 0

    def _catalog_ref(self, ctx: AppContext, values: List[str]) -> int:
        if not values or not (_cache_dir(ctx) / "catalog-digests").is_file():
            raise AddonError("no matching cached operator catalog")
        version, *aap_version = values
        wanted = aap_version[0] if aap_version else ""
        for line in (_cache_dir(ctx) / "catalog-digests").read_text(encoding="utf-8").splitlines():
            fields = line.split("\t")
            if (
                len(fields) >= 4
                and fields[0] == version
                and (not wanted or fields[3] in ("", "all", wanted))
            ):
                key = _ssh_key(ctx)
                result = _remote(ctx, key, f"crictl inspecti {shlex_quote(fields[2])}")
                if result.ok:
                    ctx.console.out(fields[2])
                    return 0
        raise AddonError("no usable cached operator catalog")

    def _save(self, ctx: AppContext, key: Path) -> int:
        cache = _cache_dir(ctx)
        cache.mkdir(parents=True, exist_ok=True)
        payload = _remote(ctx, key, "sudo crictl images -o json")
        if not payload.ok:
            raise AddonError("could not inspect CRC images", hint=payload.stderr.strip() or None)
        try:
            images = json.loads(payload.stdout or "{}").get("images", [])
        except json.JSONDecodeError as exc:
            raise AddonError("CRC returned invalid image metadata") from exc
        refs = _image_refs(images)
        if not refs:
            raise AddonError("no registry images found in CRC")
        saved = 0
        skipped = 0
        current_stems = set()
        for ref in refs:
            stem = cache / hashlib.md5(ref.encode(), usedforsecurity=False).hexdigest()
            current_stems.add(stem.name)
            archive = stem.with_suffix(".tar")
            ref_file = stem.with_suffix(".ref")
            local_file = stem.with_suffix(".local-ref")
            if _valid_oci_archive(archive) and ref_file.is_file() and local_file.is_file():
                skipped += 1
                continue
            _remove_entry(stem)
            command = (
                f"rm -f {REMOTE_ARCHIVE} && "
                f"sudo skopeo copy --quiet --remove-signatures "
                f"containers-storage:{shlex_quote(ref)} "
                f"oci-archive:{REMOTE_ARCHIVE}:aap-demo-cache && "
                f"sudo base64 -w0 {REMOTE_ARCHIVE}; status=$?; "
                f"sudo rm -f {REMOTE_ARCHIVE}; exit $status"
            )
            result = _remote(ctx, key, command, timeout=900)
            if not result.ok:
                continue
            try:
                archive.write_bytes(base64.b64decode(result.stdout, validate=True))
            except (ValueError, UnicodeError):
                archive.unlink(missing_ok=True)
                continue
            if not _valid_oci_archive(archive):
                archive.unlink(missing_ok=True)
                continue
            ref_file.write_text(ref, encoding="utf-8")
            local_ref = _archive_digest(ctx, archive, ref)
            if not local_ref:
                archive.unlink(missing_ok=True)
                ref_file.unlink(missing_ok=True)
                continue
            local_file.write_text(local_ref, encoding="utf-8")
            saved += 1
        for archive in cache.glob("*.tar"):
            stem = archive.with_suffix("")
            if (
                stem.name not in current_stems
                or not _valid_oci_archive(archive)
                or not stem.with_suffix(".ref").is_file()
                or not stem.with_suffix(".local-ref").is_file()
            ):
                _remove_entry(stem)
        if saved:
            (cache / ".format-version").write_text(CACHE_FORMAT_VERSION, encoding="utf-8")
        if saved or skipped:
            _remember_enabled(ctx)
        _say(ctx, f"Saved {saved} images, {skipped} already cached")
        return 0 if saved or skipped else 1

    def _load(self, ctx: AppContext, key: Path) -> int:
        archives = sorted(_cache_dir(ctx).glob("*.tar"))
        if not archives:
            raise AddonError(f"No cached images found for {_preset(ctx)}")
        loaded = 0
        failed = 0
        for archive in archives:
            local_ref_file = archive.with_suffix(".local-ref")
            ref_file = archive.with_suffix(".ref")
            if not local_ref_file.is_file() or not ref_file.is_file():
                failed += 1
                continue
            local_ref = local_ref_file.read_text(encoding="utf-8").strip()
            encoded = base64.b64encode(archive.read_bytes()).decode()
            command = (
                f"base64 -d > {REMOTE_ARCHIVE} && "
                f"sudo skopeo copy --all --preserve-digests "
                f"oci-archive:{REMOTE_ARCHIVE}:aap-demo-cache "
                f"containers-storage:{shlex_quote(local_ref)}; "
                f"status=$?; rm -f {REMOTE_ARCHIVE}; exit $status"
            )
            result = _remote(ctx, key, command, input=encoded, timeout=900)
            if result.ok and _remote(ctx, key, f"sudo crictl inspecti {shlex_quote(local_ref)}").ok:
                loaded += 1
            else:
                failed += 1
                archive.unlink(missing_ok=True)
                ref_file.unlink(missing_ok=True)
                local_ref_file.unlink(missing_ok=True)
        _say(ctx, f"Loaded {loaded} images ({failed} failed)")
        return 0 if not failed else 1

    def _rewrite(self, ctx: AppContext, key: Path) -> int:
        del key
        mappings = _mappings(_cache_dir(ctx))
        rewritten = 0
        for resource in ("deployments", "statefulsets", "daemonsets", "jobs", "cronjobs"):
            result = ctx.runner.run(["kubectl", "get", resource, "-A", "-o", "json"])
            if not result.ok:
                continue
            try:
                items = json.loads(result.stdout or "{}").get("items", [])
            except json.JSONDecodeError:
                continue
            for item in items:
                for mapping in mappings:
                    patch = _image_patch(item, mapping[0], mapping[1])
                    if patch:
                        name = item.get("metadata", {}).get("name")
                        namespace = item.get("metadata", {}).get("namespace")
                        if (
                            name
                            and namespace
                            and ctx.runner.run(
                                [
                                    "kubectl",
                                    "patch",
                                    resource[:-1],
                                    name,
                                    "-n",
                                    namespace,
                                    "--type=json",
                                    "-p",
                                    json.dumps(patch),
                                ]
                            ).ok
                        ):
                            rewritten += 1
        _say(ctx, f"Rewrote {rewritten} workload image reference(s)")
        return 0


def _preset(ctx: AppContext) -> str:
    return str(ctx.env.get("CRC_PRESET") or "microshift")


def _cache_dir(ctx: AppContext) -> Path:
    return ctx.paths.legacy_dir / "local-cache" / _preset(ctx)


def _ssh_key(ctx: AppContext) -> Path:
    key = ssh_mod.detect_ssh_key(ssh_mod.crc_machines_dir(ctx.env))
    if key is None:
        raise AddonError("CRC SSH key not found", hint="Is the cluster running?")
    return key


def _remote(
    ctx: AppContext,
    key: Path,
    command: str,
    *,
    input: Optional[str] = None,
    timeout: Optional[float] = None,
):
    return ctx.runner.run(
        ssh_mod.remote_argv(key, "bash", "-c", command, sudo=False),
        input=input,
        timeout=timeout,
    )


def _image_refs(images: Iterable[Dict[str, Any]]) -> List[str]:
    refs: List[str] = []
    for image in images:
        for ref in image.get("repoDigests", []) or []:
            if any(ref.startswith(f"{registry}/") for registry in REGISTRIES) and ref not in refs:
                refs.append(ref)
    return refs


def _valid_oci_archive(path: Path) -> bool:
    if not path.is_file():
        return False
    try:
        with tarfile.open(path) as archive:
            return "oci-layout" in archive.getnames()
    except (OSError, tarfile.TarError):
        return False


def _remove_entry(stem: Path) -> None:
    for suffix in (".tar", ".ref", ".local-ref"):
        stem.with_suffix(suffix).unlink(missing_ok=True)


def _archive_digest(ctx: AppContext, archive: Path, ref: str) -> str:
    result = ctx.runner.run(["skopeo", "inspect", "--raw", f"oci-archive:{archive}:aap-demo-cache"])
    if not result.ok:
        return ""
    digest = hashlib.sha256((result.stdout or "").encode()).hexdigest()
    return f"{ref.split('@', 1)[0]}@sha256:{digest}"


def _mappings(cache: Path) -> List[tuple]:
    mappings = []
    for local_file in cache.glob("*.local-ref"):
        original = local_file.with_suffix(".ref")
        if original.is_file():
            mappings.append(
                (
                    original.read_text(encoding="utf-8").strip(),
                    local_file.read_text(encoding="utf-8").strip(),
                )
            )
    return mappings


def _image_patch(item: Dict[str, Any], old: str, new: str) -> List[Dict[str, Any]]:
    template = item.get("spec", {}).get("template", {}).get("spec", {})
    patch = []
    for field in ("containers", "initContainers"):
        for index, container in enumerate(template.get(field, []) or []):
            if container.get("image") == old:
                patch.append(
                    {
                        "op": "replace",
                        "path": f"/spec/template/spec/{field}/{index}/image",
                        "value": new,
                    }
                )
            if container.get("imagePullPolicy") == "Always":
                patch.append(
                    {
                        "op": "replace",
                        "path": f"/spec/template/spec/{field}/{index}/imagePullPolicy",
                        "value": "IfNotPresent",
                    }
                )
    return patch


def shlex_quote(value: str) -> str:
    """Quote a value for the remote shell without importing shell execution."""
    return "'" + value.replace("'", "'\\''") + "'"


def _remember_enabled(ctx: AppContext) -> None:
    names = enabled_names(ctx)
    if "local-cache" not in names:
        names.append("local-cache")
    set_enabled_names(ctx, names, save=True)


def _forget_enabled(ctx: AppContext) -> None:
    set_enabled_names(
        ctx, [name for name in enabled_names(ctx) if name != "local-cache"], save=True
    )


def _say(ctx: AppContext, message: str) -> None:
    if is_structured(ctx.output):
        render(ctx.console, {"message": message}, output=ctx.output)
    else:
        ctx.console.out(message)
