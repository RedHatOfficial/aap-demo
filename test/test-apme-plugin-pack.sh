#!/usr/bin/env bash
# Exercise real archives and the extractor CLI without a container or network.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$repo_root" <<'PY'
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

REPO = Path(sys.argv.pop())
EXTRACTOR = REPO / 'addons/apme-eap/ci/extract-plugin-pack.py'
PLUGINS = (
    'ansible-plugin-scaffolder-backend-module-backstage-rhaap',
    'ansible-backstage-plugin-catalog-backend-module-rhaap',
    'ansible-plugin-backstage-self-service',
    'ansible-backstage-plugin-auth-backend-module-rhaap-provider',
    'ansible-plugin-backstage-apme',
    'ansible-backstage-plugin-catalog-backend-module-apme',
)


def archive(entries):
    """Entries explicitly describe member name, payload and optional tar type."""
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w:gz') as tar:
        for name, payload, *kind in entries:
            member = tarfile.TarInfo(name)
            member.type = kind[0] if kind else tarfile.REGTYPE
            member.mode = 0o755 if name.endswith('run.sh') else 0o644
            member.size = len(payload) if member.isreg() else 0
            if member.issym() or member.islnk():
                member.linkname = '/tmp/escape'
            tar.addfile(member, io.BytesIO(payload) if member.isreg() else None)
    return data.getvalue()


def digest(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def plugin_entries(plugin, prefix=None):
    root = prefix or plugin
    return [
        (root + '/package.json', json.dumps({'name': plugin}).encode()),
        (root + '/dist/index.js', b'plugin code\n'),
        (root + '/run.sh', b'#!/bin/sh\nexit 0\n'),
    ]


def pack(format='oci', count=6, extra=(), outer_extra=(), replacement=None):
    if format == 'npm':
        return archive([
            ('nested/' + p + '-dynamic-1.0.0.tgz',
             archive(plugin_entries(p, 'package') + (list(extra) if p == PLUGINS[0] else [])))
            for p in PLUGINS[:count]
        ] + list(outer_extra))
    layer = archive([entry for p in PLUGINS[:count] for entry in plugin_entries(p)] + list(extra))
    if format == 'layout':
        layer_hash = digest(layer)
        manifest = json.dumps({'schemaVersion': 2, 'layers': [{'digest': layer_hash}]}).encode()
        index = json.dumps({'schemaVersion': 2, 'manifests': [{'digest': digest(manifest)}]}).encode()
        return archive([
            ('index.json', index),
            ('blobs/sha256/' + digest(manifest)[7:], manifest),
            ('blobs/sha256/' + layer_hash[7:], layer),
        ] + list(outer_extra))
    layers = ['layer.tar']
    entries = [('layer.tar', layer)]
    if replacement is not None:
        layers.append('update.tar')
        entries.append(('update.tar', archive(replacement)))
    return archive([('manifest.json', json.dumps([{'Layers': layers}]).encode())] + entries + list(outer_extra))


class ExtractorTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='apme-extract-test-')
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name).resolve()
        self.source = self.root / 'plugin-pack.tar.gz'
        self.dest = self.root / 'dist with spaces'

    def run_extract(self, data, format='oci', checksum=None):
        self.source.write_bytes(data)
        env = dict(os.environ, PLUGIN_PACK_FORMAT=format,
                   PLUGIN_PACK_SHA256=digest(data) if checksum is None else checksum)
        return subprocess.run([sys.executable, str(EXTRACTOR), '--archive', str(self.source),
                               '--dest', str(self.dest)], env=env, text=True, capture_output=True)

    def success(self, data, format='oci'):
        result = self.run_extract(data, format)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        self.assertEqual(sorted(p.name for p in self.dest.iterdir()), sorted(PLUGINS))
        for plugin in PLUGINS:
            self.assertTrue((self.dest / plugin / 'package.json').is_file())
        return result

    def failure(self, data, format='oci', diagnostic=None, checksum=None):
        result = self.run_extract(data, format, checksum)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('Traceback', result.stderr)
        if diagnostic:
            self.assertIn(diagnostic.lower(), result.stderr.lower())
        self.assertFalse(self.dest.exists(), 'invalid pack installed partial plugins')

    def test_copies_all_six_plugins_in_docker_oci_and_npm_formats(self):
        for format in ('oci', 'layout', 'npm'):
            with self.subTest(format=format):
                self.dest = self.root / format
                self.success(pack(format), 'oci' if format == 'layout' else format)
                for plugin in PLUGINS:
                    self.assertEqual((self.dest / plugin / 'dist/index.js').read_bytes(), b'plugin code\n')
                    self.assertTrue((self.dest / plugin / 'run.sh').stat().st_mode & 0o111)

    def test_checks_digest_before_parsing_or_writing(self):
        self.failure(b'not an archive', checksum='sha256:' + '0' * 64, diagnostic='checksum mismatch')

    def test_requires_well_formed_digest(self):
        for checksum in ('', 'abc', 'sha256:123', 'md5:' + '0' * 64, 'sha256:' + 'g' * 64):
            with self.subTest(checksum=checksum):
                self.failure(pack(), checksum=checksum, diagnostic='PLUGIN_PACK_SHA256')

    def test_reports_both_missing_apme_plugins(self):
        for format in ('oci', 'npm'):
            with self.subTest(format=format):
                result = self.run_extract(pack(format, count=4), format)
                self.assertNotEqual(result.returncode, 0)
                for plugin in PLUGINS[4:]:
                    self.assertIn(plugin, result.stderr)
                self.assertFalse(self.dest.exists())

    def test_rejects_unsupported_format(self):
        self.failure(pack(), format='zip', diagnostic='format')

    def test_rejects_traversal_absolute_and_backslash_paths_at_each_boundary(self):
        for name in ('../escape', '/tmp/escape', PLUGINS[0] + '/../escape', 'package/../../escape', 'package\\escape'):
            for format in ('oci', 'npm'):
                for boundary in ('inner', 'outer'):
                    with self.subTest(name=name, format=format, boundary=boundary):
                        kwargs = {'extra' if boundary == 'inner' else 'outer_extra': [(name, b'bad')]}
                        self.failure(pack(format, **kwargs), format, 'unsafe')
        self.assertFalse((self.root / 'escape').exists())

    def test_rejects_links_devices_and_fifos(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE, tarfile.CHRTYPE, tarfile.BLKTYPE):
            for format in ('oci', 'npm'):
                with self.subTest(kind=kind, format=format):
                    root = PLUGINS[0] if format == 'oci' else 'package'
                    self.failure(pack(format, extra=[(root + '/unsafe', b'', kind)]), format, 'type')

    def test_rejects_whiteouts_and_npm_files_outside_package(self):
        self.failure(pack(extra=[(PLUGINS[0] + '/.wh.package.json', b'')]), diagnostic='whiteout')
        self.failure(pack('npm', extra=[('other/escape', b'bad')]), 'npm', 'package/')

    def test_safe_oci_metadata_is_not_installed(self):
        self.success(pack(extra=[('LICENSE', b'license'), ('licenses/LICENSE', b'license')]))

    def test_validates_package_content_and_identity(self):
        for content in (b'not JSON', b'{}', b'{"name":"unrelated"}'):
            self.failure(pack(replacement=[(PLUGINS[0] + '/package.json', content)]), diagnostic='package.json')

    def test_rejects_later_type_conflicts_including_implicit_directories(self):
        for path, kind in ((PLUGINS[0], tarfile.REGTYPE),
                           (PLUGINS[0] + '/dist', tarfile.REGTYPE),
                           (PLUGINS[0] + '/package.json', tarfile.DIRTYPE)):
            with self.subTest(path=path):
                self.failure(pack(replacement=[(path, b'bad', kind)]), diagnostic='conflict')

    def test_applies_layers_in_order(self):
        self.success(pack(replacement=[(PLUGINS[0] + '/dist/index.js', b'updated')]))
        self.assertEqual((self.dest / PLUGINS[0] / 'dist/index.js').read_bytes(), b'updated')

    def test_rejects_ambiguous_npm_versions(self):
        duplicate = (PLUGINS[0] + '-dynamic-2.0.0.tgz', archive(plugin_entries(PLUGINS[0], 'package')))
        self.failure(pack('npm', outer_extra=[duplicate]), 'npm', 'ambiguous')

    def test_rejects_broken_archives_and_missing_layers(self):
        self.failure(b'corrupt archive', diagnostic='archive')
        self.failure(archive([('manifest.json', b'[{"Layers":["missing.tar"]}]')]), diagnostic='member')
        self.failure(archive([('manifest.json', b'[{"Layers":[null]}]')]), diagnostic='layer')

    def test_verifies_oci_descriptor_digests(self):
        data = pack('layout')
        with tarfile.open(fileobj=io.BytesIO(data)) as tar:
            entries = [(m.name, tar.extractfile(m).read()) for m in tar]
        for index in (1, 2):
            corrupt = list(entries)
            name, content = corrupt[index]
            corrupt[index] = (name, content + b'corruption')
            self.failure(archive(corrupt), diagnostic='digest')

    def test_rejects_destination_symlink_without_touching_its_target(self):
        self.dest.mkdir()
        target = self.root / 'existing'
        target.mkdir()
        (target / 'sentinel').write_text('unchanged')
        (self.dest / PLUGINS[0]).symlink_to(target, target_is_directory=True)
        result = self.run_extract(pack())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('destination', result.stderr)
        self.assertEqual(list(target.iterdir()), [target / 'sentinel'])
        self.assertEqual(len(list(self.dest.iterdir())), 1)

    def test_checked_in_real_six_plugin_pack(self):
        fixture = REPO / 'addons/apme-eap/plugin_packs/apme-prototype-plugins-8593383-20260718025043.oci.tar.gz'
        self.success(fixture.read_bytes())


unittest.main(verbosity=2)
PY
