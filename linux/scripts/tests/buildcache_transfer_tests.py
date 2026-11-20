"""Real synthetic cache files and an explicit unit double test transport, not actual solves, ownership or cache hits."""

from __future__ import annotations

import importlib
import json
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import TYPE_CHECKING
from unittest import mock

from native_oci_seed_tests import blob

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'linux/scripts/local-proof'))
cache = importlib.import_module('buildcache_transfer')

if TYPE_CHECKING:
    from typing import Any


class CacheTransferTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='cache transfer ')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / 'source cache'
        self.destination = self.root / 'fresh destination'
        self.receipt = self.root / 'transfer receipt.json'
        self.proof = self.root / 'stopped producer.json'
        self.unit = 'fixture-cache-producer.service'
        self.terminal = {'Id': self.unit, 'LoadState': 'loaded', 'ActiveState': 'active', 'SubState': 'exited',
                         'MainPID': '0', 'Result': 'success', 'ExecMainStatus': '0'}
        self.stopped = {'Id': self.unit, 'ActiveState': 'inactive', 'MainPID': '0'}
        self.save_proof()
        self.make_cache()
        self.live = False
        patcher = mock.patch.object(cache, 'checked_run', side_effect=self.unit_state)
        patcher.start()
        self.addCleanup(patcher.stop)

    def unit_state(self, command: list[str]) -> subprocess.CompletedProcess[str]:
        self.assertEqual(command, ['systemctl', '--user', 'show', self.unit, '--property=ActiveState,MainPID'])
        value = 'ActiveState=activating\nMainPID=987\n' if self.live else 'ActiveState=inactive\nMainPID=0\n'
        return subprocess.CompletedProcess(command, 0, stdout=value)

    def save_proof(self) -> None:
        self.proof.write_text(json.dumps({'terminal': self.terminal, 'stopped': self.stopped}))

    def make_cache(self) -> None:
        (self.source / 'blobs/sha256').mkdir(parents=True)
        layer = blob(self.source, b'independent synthetic compressed cache layer', 'application/vnd.oci.image.layer.v1.tar+gzip')
        config = blob(self.source, b'{"layers":[],"records":[]}', 'application/vnd.buildkit.cacheconfig.v0')
        self.manifest: dict[str, Any] = {'schemaVersion': 2, 'layers': [layer, layer], 'config': config}
        self.write_manifest()
        (self.source / 'oci-layout').write_text('{"imageLayoutVersion":"1.0.0"}\n')

    def write_manifest(self) -> None:
        selected = blob(self.source, json.dumps(self.manifest).encode(), 'application/vnd.oci.image.manifest.v1+json')
        (self.source / 'index.json').write_text(json.dumps({'schemaVersion': 2, 'manifests': [selected]}))

    def transfer(self) -> dict[str, Any]:
        return cache.transfer_cache(self.source, self.destination, self.proof, self.receipt)

    def test_real_links_independent_metadata_exact_accounting_and_reverification(self) -> None:
        metadata = {name: (self.source / name).read_bytes() for name in ('index.json', 'oci-layout')}
        result = self.transfer()
        self.assertEqual(cache.verify_transfer(self.receipt), result)
        self.assertEqual(result['verified_unique_blobs'], 3)
        self.assertEqual(result['shared_unique_bytes'], sum(path.stat().st_size for path in (self.destination / 'blobs/sha256').iterdir()))
        self.assertFalse(result['cache_hits_claimed'])
        self.assertFalse(result['image_accepted'])
        self.assertFalse(result['publication'])
        for name, original in metadata.items():
            self.assertEqual((self.destination / name).read_bytes(), original)
            self.assertFalse((self.destination / name).samefile(self.source / name))
            self.assertEqual((self.source / name).read_bytes(), original)
        for path in (self.source / 'blobs/sha256').iterdir():
            self.assertTrue(path.samefile(self.destination / 'blobs/sha256' / path.name))

    def test_existing_destination_and_receipt_are_preserved(self) -> None:
        self.destination.mkdir()
        with self.assertRaisesRegex(AssertionError, 'existing destination'):
            self.transfer()
        self.destination.rmdir()
        self.receipt.write_bytes(b'original receipt')
        with self.assertRaisesRegex(AssertionError, 'existing transfer receipt'):
            self.transfer()
        self.assertEqual(self.receipt.read_bytes(), b'original receipt')

    def test_paths_cannot_overlap_or_traverse_symlinks(self) -> None:
        self.destination = self.source / 'child cache'
        with self.assertRaisesRegex(AssertionError, 'paths overlap'):
            self.transfer()
        self.destination = self.root / 'fresh'
        alias = self.root / 'source alias'
        alias.symlink_to(self.source, target_is_directory=True)
        self.source = alias
        with self.assertRaisesRegex(AssertionError, 'symlink components'):
            self.transfer()

    def test_receipt_cannot_modify_the_source_tree(self) -> None:
        self.receipt = self.source / 'new receipt.json'
        with self.assertRaisesRegex(AssertionError, 'Receipt overlaps'):
            self.transfer()
        self.assertFalse(self.receipt.exists())

    def test_failed_unstopped_and_restarted_producers_refuse_before_writing(self) -> None:
        self.terminal['Result'] = 'exit-code'
        self.save_proof()
        with self.assertRaisesRegex(AssertionError, 'complete successfully'):
            self.transfer()
        self.terminal['Result'] = 'success'
        self.stopped['MainPID'] = '123'
        self.save_proof()
        with self.assertRaisesRegex(AssertionError, 'not stopped'):
            self.transfer()
        self.stopped['MainPID'] = '0'
        self.save_proof()
        self.live = True
        with self.assertRaisesRegex(AssertionError, 'currently live'):
            self.transfer()
        self.assertFalse(self.destination.exists())

    def test_bad_blobs_unsupported_cache_and_empty_layers_refuse(self) -> None:
        self.manifest['config']['mediaType'] = 'application/vnd.oci.image.config.v1+json'
        self.write_manifest()
        with self.assertRaisesRegex(AssertionError, 'BuildKit cache manifest'):
            self.transfer()
        self.manifest['config']['mediaType'] = 'application/vnd.buildkit.cacheconfig.v0'
        layers = self.manifest['layers']
        self.manifest['layers'] = []
        self.write_manifest()
        with self.assertRaisesRegex(AssertionError, 'no layers'):
            self.transfer()
        self.manifest['layers'] = layers
        self.write_manifest()
        path = cache.descriptor_path(self.source, layers[0])
        path.write_bytes(b'corrupt')
        with self.assertRaisesRegex(AssertionError, 'Blob bytes differ'):
            self.transfer()
        self.assertFalse(self.destination.exists())

    def test_link_failure_retains_diagnostics_without_passed_receipt(self) -> None:
        with mock.patch.object(cache.os, 'link', side_effect=OSError('fixture hardlink failure')), self.assertRaisesRegex(OSError, 'fixture hardlink failure'):
            self.transfer()
        self.assertTrue(self.destination.exists())
        self.assertFalse(self.receipt.exists())

    def test_verifier_rejects_metadata_aliases_blob_copies_and_changed_receipts(self) -> None:
        record = self.transfer()
        self.receipt.write_text(json.dumps({**record, 'cache_hits_claimed': True}))
        with self.assertRaisesRegex(AssertionError, 'grants no acceptance'):
            cache.verify_transfer(self.receipt)
        self.receipt.write_text(json.dumps(record))
        metadata = self.destination / 'oci-layout'
        metadata.unlink()
        metadata.hardlink_to(self.source / metadata.name)
        with self.assertRaisesRegex(AssertionError, 'must be copied'):
            cache.verify_transfer(self.receipt)
        metadata.unlink()
        metadata.write_bytes((self.source / metadata.name).read_bytes())
        copied = next((self.destination / 'blobs/sha256').iterdir())
        contents = copied.read_bytes()
        copied.unlink()
        copied.write_bytes(contents)
        with self.assertRaisesRegex(AssertionError, 'not shared'):
            cache.verify_transfer(self.receipt)

    def test_layout_and_manifest_headers_and_conflicting_descriptors_refuse(self) -> None:
        layout_path = self.source / 'oci-layout'
        layout_path.write_text('{"imageLayoutVersion":"9.9.9"}')
        with self.assertRaisesRegex(AssertionError, 'Unsupported cache layout'):
            self.transfer()
        layout_path.write_text('{"imageLayoutVersion":"1.0.0"}')
        index_path = self.source / 'index.json'
        original = index_path.read_bytes()
        index = json.loads(original)
        index['manifests'].append(index['manifests'][0])
        index_path.write_text(json.dumps(index))
        with self.assertRaisesRegex(AssertionError, 'exactly one manifest'):
            self.transfer()
        index = json.loads(original)
        index['manifests'][0]['mediaType'] = 'fixture/unknown'
        index_path.write_text(json.dumps(index))
        with self.assertRaisesRegex(AssertionError, 'Unsupported cache manifest type'):
            self.transfer()
        self.manifest['layers'][1] = {**self.manifest['layers'][0], 'mediaType': 'fixture/conflict'}
        self.write_manifest()
        with self.assertRaisesRegex(AssertionError, 'Conflicting cache descriptors'):
            self.transfer()

    def test_terminal_fields_and_unit_binding_remain_required(self) -> None:
        for key, value, message in [('LoadState', 'not-found', 'complete successfully'), ('MainPID', '123', 'live or failed'),
                                     ('ExecMainStatus', '1', 'live or failed'), ('ActiveState', 'failed', 'successful terminal'),
                                     ('SubState', 'running', 'successful terminal'), ('Id', 'another.service', 'unit differs')]:
            with self.subTest(key=key):
                original = self.terminal[key]
                self.terminal[key] = value
                self.save_proof()
                with self.assertRaisesRegex(AssertionError, message):
                    self.transfer()
                self.terminal[key] = original
                self.save_proof()
        self.assertFalse(self.destination.exists())

    def test_mutating_source_metadata_leaves_no_passed_receipt(self) -> None:
        original_link = cache.os.link

        def change_metadata(source: Path, destination: Path, **kwargs: bool) -> None:
            original_link(source, destination, **kwargs)
            (self.source / 'index.json').write_text('{}')

        with mock.patch.object(cache.os, 'link', side_effect=change_metadata), self.assertRaisesRegex(AssertionError, 'metadata changed during transfer'):
            self.transfer()
        self.assertFalse(self.receipt.exists())

    def test_receipt_inventory_and_proof_cannot_change(self) -> None:
        record = self.transfer()
        for key, value, message in [('status', 'passed', 'Unexpected cache transfer receipt'),
                                    ('schema_version', 9, 'Unexpected cache transfer receipt'),
                                    ('descriptors', [], 'Cache layout differs'), ('metadata_sha256', {}, 'Cache metadata differs'),
                                    ('verified_unique_blobs', 99, 'blob count differs'), ('shared_unique_bytes', 0, 'byte accounting differs'),
                                    ('producer_proof_sha256', '0' * 64, 'Producer proof differs'),
                                    ('producer_unit', 'other.service', 'Producer proof differs')]:
            with self.subTest(key=key):
                self.receipt.write_text(json.dumps({**record, key: value}))
                with self.assertRaisesRegex(AssertionError, message):
                    cache.verify_transfer(self.receipt)

    def test_source_symlinked_blob_and_metadata_refuse(self) -> None:
        metadata = self.source / 'oci-layout'
        saved = self.root / 'saved metadata'
        metadata.rename(saved)
        metadata.symlink_to(saved)
        with self.assertRaisesRegex(AssertionError, 'regular files'):
            self.transfer()
        metadata.unlink()
        saved.rename(metadata)
        blob_path = cache.descriptor_path(self.source, self.manifest['layers'][0])
        payload = self.root / 'saved payload'
        blob_path.rename(payload)
        blob_path.symlink_to(payload)
        with self.assertRaisesRegex(AssertionError, 'regular blob'):
            self.transfer()

    def test_other_filesystem_refuses_before_writing(self) -> None:
        original_stat = Path.stat

        def other_device(path: Path, *, follow_symlinks: bool = True) -> os.stat_result:
            result = original_stat(path, follow_symlinks=follow_symlinks)
            if path == self.source:
                values = list(result)
                values[2] += 1
                return os.stat_result(values)
            return result

        with mock.patch.object(Path, 'stat', other_device), self.assertRaisesRegex(AssertionError, 'same filesystem'):
            self.transfer()
        self.assertFalse(self.destination.exists())

    def test_changed_producer_proof_during_copy_cannot_pass(self) -> None:
        original_link = cache.os.link

        def change_proof(source: Path, destination: Path, **kwargs: bool) -> None:
            original_link(source, destination, **kwargs)
            self.proof.write_text(self.proof.read_text() + '\n')

        with mock.patch.object(cache.os, 'link', side_effect=change_proof), self.assertRaisesRegex(AssertionError, 'Producer proof changed'):
            self.transfer()
        self.assertFalse(self.receipt.exists())

    def test_rendered_import_uses_actual_arguments_and_exact_destination(self) -> None:
        self.transfer()
        log = self.root / 'normal dry run.log'
        command = ['nerdctl', 'build', '-t', 'ant-local/fixture:cross-compiler-amd64', '--cache-from', 'type=local,src=' + str(self.destination), '.']
        log.write_text('ordinary driver output\n[DRY RUN] ' + shlex.join(command) + '\n')
        record = cache.verify_rendered_import(self.receipt, log, 'ant-local/fixture:cross-compiler-amd64')
        self.assertTrue(record['rendered_import_verified'])
        self.assertEqual(record['dry_run_log_sha256'], cache.sha(log))
        with self.assertRaisesRegex(AssertionError, 'image differs'):
            cache.verify_rendered_import(self.receipt, log, 'ant-local/other:cross-compiler-amd64')
        for extra in [[], ['--no-cache'], ['--cache-from', 'type=local,src=/wrong namespace']]:
            with self.subTest(extra=extra):
                arguments = command[:4] + extra + command[4:] if extra else command[:4] + ['.']
                log.write_text('[DRY RUN] ' + shlex.join(arguments) + '\n')
                with self.assertRaisesRegex(AssertionError, 'disables caching|import differs or is missing'):
                    cache.verify_rendered_import(self.receipt, log, 'ant-local/fixture:cross-compiler-amd64')
        log.write_text('[DRY RUN] ' + shlex.join(command) + '\n[DRY RUN] ' + shlex.join(command) + '\n')
        with self.assertRaisesRegex(AssertionError, 'exactly one rendered normal build'):
            cache.verify_rendered_import(self.receipt, log, 'ant-local/fixture:cross-compiler-amd64')


if __name__ == '__main__':
    unittest.main()
