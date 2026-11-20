"""Native V2 local OCI image cache addon.

The cache is intentionally host-owned state.  CRC image-store operations go
through the shared runner/SSH seams; no shell installer is invoked.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import tarfile
from functools import partial
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
            return self._clear(ctx, forget=False)
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
        return self._clear(ctx, forget=True)

    def _clear(self, ctx: AppContext, *, forget: bool) -> int:
        cache = _cache_dir(ctx)
        if cache.exists():
            shutil.rmtree(cache)
            _say(ctx, f"Cleared image cache for {_preset(ctx)}")
        else:
            _say(ctx, f"No image cache found for {_preset(ctx)}")
        if forget:
            _forget_enabled(ctx)
        return 0

    def _validate(self, ctx: AppContext) -> int:
        cache = _cache_dir(ctx)
        if not cache.is_dir():
            raise AddonError(f"No image cache found for {_preset(ctx)}")
        format_current = _format_current(cache)
        checked = 0
        failed = 0
        for archive in sorted(cache.glob("*.tar")):
            checked += 1
            stem = archive.with_suffix("")
            ref_file = stem.with_suffix(".ref")
            reference = ref_file.read_text(encoding="utf-8").strip() if ref_file.is_file() else ""
            local_file = stem.with_suffix(".local-ref")
            local_reference = (
                local_file.read_text(encoding="utf-8").strip() if local_file.is_file() else ""
            )
            valid = (
                format_current
                and _valid_oci_archive(archive)
                and ref_file.is_file()
                and reference
                and stem.name
                in {
                    hashlib.md5(reference.encode(), usedforsecurity=False).hexdigest(),
                    hashlib.md5((reference + "\n").encode(), usedforsecurity=False).hexdigest(),
                }
                and local_reference
                and "@sha256:" in local_reference
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
                reference = fields[2]
                key = _ssh_key(ctx)
                result = _remote(ctx, key, f"sudo crictl inspecti {shlex_quote(reference)}")
                if result.ok:
                    reference_text = str(reference)
                    render(
                        ctx.console,
                        {"reference": reference_text},
                        output=ctx.output,
                        text=partial(str, reference_text),
                    )
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
        catalog_versions = _catalog_versions(images)
        format_current = _format_current(cache)
        saved = 0
        skipped = 0
        failed = 0
        current_stems = set()
        catalog_rows = []
        for ref in refs:
            stem = _cache_stem(cache, ref)
            current_stems.add(stem.name)
            archive = stem.with_suffix(".tar")
            ref_file = stem.with_suffix(".ref")
            local_file = stem.with_suffix(".local-ref")
            usable = format_current and _cache_entry_usable(stem, ref)
            if usable:
                skipped += 1
                local_ref = local_file.read_text(encoding="utf-8").strip()
                if ref in catalog_versions:
                    catalog_rows.append(_catalog_row(catalog_versions[ref], ref, local_ref, ctx))
                continue
            command = (
                f"rm -f {REMOTE_ARCHIVE} && "
                f"sudo skopeo copy --quiet --remove-signatures "
                f"containers-storage:{shlex_quote(ref)} "
                f"oci-archive:{REMOTE_ARCHIVE}:aap-demo-cache; status=$?; "
                f"if [ $status -eq 0 ]; then sudo cat {REMOTE_ARCHIVE}; fi; "
                f"sudo rm -f {REMOTE_ARCHIVE}; exit $status"
            )
            temporary = cache / f".{stem.name}.tar.tmp"
            result = _remote(ctx, key, command, output_path=temporary, timeout=900)
            if not result.ok:
                temporary.unlink(missing_ok=True)
                failed += 1
                continue
            if not _valid_oci_archive(temporary):
                temporary.unlink(missing_ok=True)
                failed += 1
                continue
            local_ref = _archive_digest(ctx, temporary, ref)
            if not local_ref:
                temporary.unlink(missing_ok=True)
                failed += 1
                continue
            ref_tmp = cache / f".{stem.name}.ref.tmp"
            local_tmp = cache / f".{stem.name}.local-ref.tmp"
            ref_tmp.write_text(ref + "\n", encoding="utf-8")
            local_tmp.write_text(local_ref + "\n", encoding="utf-8")
            temporary.replace(archive)
            ref_tmp.replace(ref_file)
            local_tmp.replace(local_file)
            saved += 1
            if ref in catalog_versions:
                catalog_rows.append(_catalog_row(catalog_versions[ref], ref, local_ref, ctx))
        for archive in cache.glob("*.tar"):
            stem = archive.with_suffix("")
            if stem.name not in current_stems:
                _remove_entry(stem)
            elif not (
                _valid_oci_archive(archive)
                and stem.with_suffix(".ref").is_file()
                and stem.with_suffix(".local-ref").is_file()
            ):
                _remove_entry(stem)
        metadata = cache / "catalog-digests"
        if catalog_rows:
            temporary_metadata = cache / "catalog-digests.tmp"
            temporary_metadata.write_text("".join(sorted(set(catalog_rows))), encoding="utf-8")
            temporary_metadata.replace(metadata)
        else:
            metadata.unlink(missing_ok=True)
        if saved or (format_current and (cache / ".format-version").is_file()):
            (cache / ".format-version").write_text(CACHE_FORMAT_VERSION, encoding="utf-8")
        if saved or skipped:
            _remember_enabled(ctx)
        _say(ctx, f"Saved {saved} images, {skipped} already cached, {failed} failed")
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
            if not ref_file.is_file():
                failed += 1
                continue
            reference = ref_file.read_text(encoding="utf-8").strip()
            if not _valid_oci_archive(archive):
                failed += 1
                continue
            if not local_ref_file.is_file():
                local_ref = _archive_digest(ctx, archive, reference)
                if not local_ref:
                    failed += 1
                    continue
                local_ref_file.write_text(local_ref + "\n", encoding="utf-8")
            else:
                local_ref = local_ref_file.read_text(encoding="utf-8").strip()
            present = _remote(ctx, key, f"sudo crictl inspecti {shlex_quote(local_ref)}")
            if present.ok:
                loaded += 1
                continue
            result = _remote(
                ctx,
                key,
                f"cat > {REMOTE_ARCHIVE} && sudo skopeo copy --all --preserve-digests "
                f"oci-archive:{REMOTE_ARCHIVE}:aap-demo-cache "
                f"containers-storage:{shlex_quote(local_ref)}; status=$?; "
                f"rm -f {REMOTE_ARCHIVE}; exit $status",
                stdin_path=archive,
                timeout=900,
            )
            if not result.ok:
                failed += 1
                continue
            if _remote(ctx, key, f"sudo crictl inspecti {shlex_quote(local_ref)}").ok:
                loaded += 1
            else:
                failed += 1
        _say(ctx, f"Loaded {loaded} images ({failed} failed)")
        return 0 if not failed else 1

    def _rewrite(self, ctx: AppContext, key: Path) -> int:
        mappings = _mappings(_cache_dir(ctx))
        rewritten = 0
        available: Dict[str, bool] = {}
        for resource in (
            "deployments",
            "statefulsets",
            "daemonsets",
            "jobs",
            "cronjobs",
            "csv",
            "catalogsources",
        ):
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
                        if mapping[1] not in available:
                            available[mapping[1]] = _remote(
                                ctx, key, f"sudo crictl inspecti {shlex_quote(mapping[1])}"
                            ).ok
                        if not available[mapping[1]]:
                            continue
                        name = item.get("metadata", {}).get("name")
                        namespace = item.get("metadata", {}).get("namespace")
                        kind = str(item.get("kind", resource.rstrip("s"))).lower()
                        if (
                            name
                            and namespace
                            and ctx.runner.run(
                                [
                                    "kubectl",
                                    "patch",
                                    kind,
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
    return str(ctx.config.get("crc.preset", "microshift") or "microshift")


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
    stdin_path: Optional[Path] = None,
    timeout: Optional[float] = None,
    output_path: Optional[Path] = None,
):
    return ctx.runner.run(
        ssh_mod.remote_argv(key, "bash", "-c", command, sudo=False),
        input=input,
        stdin_path=stdin_path,
        timeout=timeout,
        stdout_path=output_path,
    )


def _format_current(cache: Path) -> bool:
    marker = cache / ".format-version"
    return marker.is_file() and marker.read_text(encoding="utf-8").strip() == CACHE_FORMAT_VERSION


def _image_refs(images: Iterable[Dict[str, Any]]) -> List[str]:
    refs: List[str] = []
    for image in images:
        for ref in image.get("repoDigests", []) or []:
            if any(ref.startswith(f"{registry}/") for registry in REGISTRIES) and ref not in refs:
                refs.append(ref)
    return refs


def _cache_stem(cache: Path, ref: str) -> Path:
    """Use the V1 newline-hashed key for new entries and read old keys too."""
    current = cache / hashlib.md5(ref.encode(), usedforsecurity=False).hexdigest()
    legacy = cache / hashlib.md5((ref + "\n").encode(), usedforsecurity=False).hexdigest()
    if any(legacy.with_suffix(suffix).is_file() for suffix in (".tar", ".ref", ".local-ref")):
        return legacy
    if any(current.with_suffix(suffix).is_file() for suffix in (".tar", ".ref", ".local-ref")):
        return current
    return legacy


def _cache_entry_usable(stem: Path, ref: str) -> bool:
    ref_file = stem.with_suffix(".ref")
    local_file = stem.with_suffix(".local-ref")
    return (
        _valid_oci_archive(stem.with_suffix(".tar"))
        and ref_file.is_file()
        and ref_file.read_text(encoding="utf-8").strip() == ref
        and local_file.is_file()
        and bool(local_file.read_text(encoding="utf-8").strip())
    )


def _catalog_versions(images: Iterable[Dict[str, Any]]) -> Dict[str, str]:
    versions: Dict[str, str] = {}
    for image in images:
        digests = image.get("repoDigests", []) or []
        for tag in image.get("repoTags", []) or []:
            if not tag.startswith("registry.redhat.io/redhat/redhat-operator-index:v"):
                continue
            version = tag.rsplit(":v", 1)[1]
            for digest in digests:
                if digest.startswith("registry.redhat.io/redhat/redhat-operator-index@"):
                    versions[digest] = version
    return versions


def _catalog_row(version: str, original: str, local: str, ctx: AppContext) -> str:
    channel = str(ctx.config.get("deploy.channel", "") or "")
    match = re.search(r"(?:^|-)((?:\d+)\.(?:\d+))(?:-|$)", channel)
    aap_version = (match.group(1) if match else "") or str(ctx.env.get("AAP_VERSION") or "all")
    return f"{version}\t{original}\t{local}\t{aap_version}\n"


def _valid_oci_archive(path: Path) -> bool:
    if not path.is_file():
        return False
    try:
        with tarfile.open(path) as archive:
            names = set(archive.getnames())
            if "oci-layout" not in names or "index.json" not in names:
                return False
            index_member = archive.extractfile("index.json")
            if index_member is None:
                return False
            index = json.loads(index_member.read())
            manifests = index.get("manifests", [])
            if not isinstance(manifests, list) or not manifests:
                return False
            checked: set[str] = set()

            def descriptor_blob(descriptor: Dict[str, Any]) -> Optional[bytes]:
                digest = descriptor.get("digest")
                if not isinstance(digest, str) or not digest.startswith("sha256:"):
                    return None
                blob = f"blobs/{digest.replace(':', '/', 1)}"
                if blob not in names:
                    return None
                member = archive.extractfile(blob)
                if member is None:
                    return None
                data = member.read()
                digest_value = digest.split(":", 1)[1]
                if digest_value not in checked and hashlib.sha256(data).hexdigest() != digest_value:
                    return None
                checked.add(digest_value)
                return data

            def visit(descriptor: Dict[str, Any]) -> bool:
                data = descriptor_blob(descriptor)
                if data is None:
                    return False
                try:
                    document = json.loads(data)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    return False
                if isinstance(document.get("manifests"), list):
                    return all(
                        isinstance(child, dict) and visit(child) for child in document["manifests"]
                    )
                config = document.get("config")
                layers = document.get("layers", [])
                if not isinstance(config, dict) or not isinstance(layers, list):
                    return False
                return descriptor_blob(config) is not None and all(
                    isinstance(layer, dict) and descriptor_blob(layer) is not None
                    for layer in layers
                )

            return all(isinstance(entry, dict) and visit(entry) for entry in manifests)
    except (OSError, tarfile.TarError):
        return False
    except (AttributeError, KeyError, TypeError, ValueError, json.JSONDecodeError):
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
    patch = []
    templates = []
    kind = str(item.get("kind", "")).lower()
    if kind == "catalogsource":
        if item.get("spec", {}).get("image") == old:
            return [{"op": "replace", "path": "/spec/image", "value": new}]
        return []
    if kind in ("csv", "clusterserviceversion"):
        for index, deployment in enumerate(
            item.get("spec", {}).get("install", {}).get("spec", {}).get("deployments", []) or []
        ):
            templates.append(
                (
                    deployment.get("spec", {}).get("template", {}).get("spec", {}),
                    f"/spec/install/spec/deployments/{index}/spec/template/spec",
                )
            )
    elif kind == "cronjob":
        templates.append(
            (
                item.get("spec", {})
                .get("jobTemplate", {})
                .get("spec", {})
                .get("template", {})
                .get("spec", {}),
                "/spec/jobTemplate/spec/template/spec",
            )
        )
    else:
        templates.append(
            (item.get("spec", {}).get("template", {}).get("spec", {}), "/spec/template/spec")
        )
    for template, prefix in templates:
        for field in ("containers", "initContainers"):
            for index, container in enumerate(template.get(field, []) or []):
                if container.get("image") not in (old, new):
                    continue
                if container.get("image") == old:
                    patch.append(
                        {"op": "replace", "path": f"{prefix}/{field}/{index}/image", "value": new}
                    )
                if container.get("imagePullPolicy") == "Always":
                    patch.append(
                        {
                            "op": "replace",
                            "path": f"{prefix}/{field}/{index}/imagePullPolicy",
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
