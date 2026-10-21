#!/usr/bin/env python3
"""Verify and install a complete APME Docker/OCI or nested npm plugin pack.

Only standard-library modules are needed in the RHDH base image. CLI path
overrides let offline tests exercise the same installation as container builds.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tarfile
import tempfile


PLUGINS = (
    "ansible-plugin-scaffolder-backend-module-backstage-rhaap",
    "ansible-backstage-plugin-catalog-backend-module-rhaap",
    "ansible-plugin-backstage-self-service",
    "ansible-backstage-plugin-auth-backend-module-rhaap-provider",
    "ansible-plugin-backstage-apme",
    "ansible-backstage-plugin-catalog-backend-module-apme",
)
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def safe_path(name):
    require(isinstance(name, str) and name and not name.startswith("/")
            and "\\" not in name and "\x00" not in name
            and ".." not in name.split("/"), "unsafe archive path: {!r}".format(name))
    parts = tuple(part for part in name.split("/") if part not in ("", "."))
    require(not any(part.startswith(".wh.") for part in parts),
            "unsupported OCI whiteout: " + name)
    return parts


def safe_member(member):
    parts = safe_path(member.name)
    require(member.isdir() or member.isreg(),
            "unsupported archive entry type: " + member.name)
    require(parts or member.isdir(), "unsafe empty archive filename")
    return parts


def indexed_members(archive):
    result = {}
    for member in archive:
        parts = safe_member(member)
        if not parts:
            continue
        name = "/".join(parts)
        require(name not in result, "duplicate archive member: " + name)
        result[name] = member
    return result


def regular_member(archive, members, name):
    name = "/".join(safe_path(name))
    member = members.get(name)
    require(member is not None and member.isreg(),
            "missing or nonregular archive member: " + name)
    return archive.extractfile(member)


def json_member(archive, members, name):
    with regular_member(archive, members, name) as source:
        return json.load(source)


def copy_hashed(source, dest=None):
    checksum = hashlib.sha256()
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        checksum.update(chunk)
        if dest is not None:
            dest.write(chunk)
    return "sha256:" + checksum.hexdigest()


def descriptor_path(descriptor):
    require(isinstance(descriptor, dict) and isinstance(descriptor.get("digest"), str)
            and DIGEST.fullmatch(descriptor["digest"]), "invalid OCI descriptor digest")
    return "blobs/sha256/" + descriptor["digest"][7:]


def oci_layers(archive, members):
    if "manifest.json" in members:
        manifest = json_member(archive, members, "manifest.json")
        require(isinstance(manifest, list) and len(manifest) == 1
                and isinstance(manifest[0], dict), "invalid or ambiguous Docker manifest")
        layers = manifest[0].get("Layers")
        require(isinstance(layers, list) and layers
                and all(isinstance(layer, str) and layer for layer in layers),
                "invalid Docker manifest layers")
        return layers
    index = json_member(archive, members, "index.json")
    require(isinstance(index, dict) and isinstance(index.get("manifests"), list)
            and len(index["manifests"]) == 1, "invalid or ambiguous OCI index")
    manifest_path = descriptor_path(index["manifests"][0])
    with regular_member(archive, members, manifest_path) as source:
        content = source.read()
    require("sha256:" + hashlib.sha256(content).hexdigest() == index["manifests"][0]["digest"],
            "OCI manifest digest mismatch")
    manifest = json.loads(content)
    require(isinstance(manifest, dict) and isinstance(manifest.get("layers"), list)
            and manifest["layers"], "invalid OCI manifest layers")
    return [descriptor_path(layer) for layer in manifest["layers"]]


def install_members(archive, stage, plugin=None):
    for member in archive:
        parts = safe_member(member)
        if not parts:
            continue
        if plugin is not None:
            require(parts[0] == "package", "npm member must be beneath package/: " + member.name)
            parts = (plugin,) + parts[1:]
        # License and image metadata outside the plugin roots are validated,
        # but never copied into the runtime plugin directory.
        if parts[0] not in PLUGINS:
            continue
        target = stage.joinpath(*parts)
        require(len(parts) > 1 or member.isdir(), "conflicting plugin root: " + member.name)
        for parent in reversed(target.parents):
            if parent == stage or stage in parent.parents:
                require(not parent.exists() or parent.is_dir(),
                        "conflicting archive directory: " + str(parent.relative_to(stage)))
                parent.mkdir(exist_ok=True)
        require(not target.exists() or target.is_dir() == member.isdir(),
                "conflicting archive entry: " + member.name)
        if member.isdir():
            target.mkdir(exist_ok=True)
        else:
            with archive.extractfile(member) as source, target.open("wb") as dest:
                shutil.copyfileobj(source, dest)
            # Retain executable bits, strip special bits, and permit runtime
            # user 1001 to read files installed by root.
            target.chmod(0o644 | (member.mode & 0o111))


def extract_pack(archive_path, format, stage):
    with tarfile.open(archive_path, "r:*") as outer:
        members = indexed_members(outer)
        if format == "oci":
            for layer_path in oci_layers(outer, members):
                # Spool one layer at a time, avoiding in-memory copies of the
                # large real pack and verifying OCI blobs before reading tar.
                with regular_member(outer, members, layer_path) as source, tempfile.TemporaryFile() as layer:
                    checksum = copy_hashed(source, layer)
                    canonical = "/".join(safe_path(layer_path))
                    if canonical.startswith("blobs/sha256/"):
                        require(checksum == "sha256:" + canonical[len("blobs/sha256/"):],
                                "OCI layer digest mismatch")
                    layer.seek(0)
                    with tarfile.open(fileobj=layer, mode="r|*") as inner:
                        install_members(inner, stage)
        else:
            for plugin in PLUGINS:
                matches = [name for name in members
                           if Path(name).name.startswith(plugin + "-dynamic-") and name.endswith(".tgz")]
                require(len(matches) <= 1, "ambiguous npm packages for " + plugin)
                if matches:
                    with regular_member(outer, members, matches[0]) as source:
                        with tarfile.open(fileobj=source, mode="r|*") as inner:
                            install_members(inner, stage, plugin)


def validate_plugins(stage):
    missing = [plugin for plugin in PLUGINS if not (stage / plugin / "package.json").is_file()]
    require(not missing, "missing required plugins: " + ", ".join(missing))
    for plugin in PLUGINS:
        with (stage / plugin / "package.json").open() as source:
            try:
                metadata = json.load(source)
            except ValueError as error:
                raise ValueError("invalid package.json for " + plugin) from error
        scoped = "@ansible/" + plugin[len("ansible-"):]
        require(isinstance(metadata, dict)
                and metadata.get("name") in (plugin, plugin + "-dynamic", scoped, scoped + "-dynamic"),
                "invalid package.json identity for " + plugin)


def publish_plugins(stage, destination):
    for parent in (destination,) + tuple(destination.parents):
        require(not parent.is_symlink(), "unsafe destination symlink: " + str(parent))
    for plugin in PLUGINS:
        target = destination / plugin
        require(not target.exists() and not target.is_symlink(),
                "destination plugin already exists: " + plugin)
    destination.mkdir(parents=True, exist_ok=True)
    for plugin in PLUGINS:
        shutil.copytree(stage / plugin, destination / plugin)
        print("Installed " + plugin, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, default=Path("/tmp/plugin-pack.tar.gz"))
    parser.add_argument("--dest", type=Path, default=Path("/opt/app-root/src/dynamic-plugins/dist"))
    args = parser.parse_args()
    expected = os.environ.get("PLUGIN_PACK_SHA256", "")
    format = os.environ.get("PLUGIN_PACK_FORMAT", "")
    require(DIGEST.fullmatch(expected), "PLUGIN_PACK_SHA256 must be sha256:<64 lowercase hex digits>")
    require(format in ("oci", "npm"), "unsupported PLUGIN_PACK_FORMAT: " + repr(format))
    with args.archive.open("rb") as source:
        require(copy_hashed(source) == expected, "plugin pack checksum mismatch")
    with tempfile.TemporaryDirectory(prefix="apme-plugin-pack-") as work:
        stage = Path(work)
        extract_pack(args.archive, format, stage)
        validate_plugins(stage)
        publish_plugins(stage, args.dest.absolute())


if __name__ == "__main__":
    try:
        main()
    except tarfile.TarError as error:
        print("plugin pack: invalid archive: " + str(error).splitlines()[0], file=sys.stderr)
        sys.exit(1)
    except (ValueError, OSError, EOFError) as error:
        print("plugin pack: " + str(error), file=sys.stderr)
        sys.exit(1)
