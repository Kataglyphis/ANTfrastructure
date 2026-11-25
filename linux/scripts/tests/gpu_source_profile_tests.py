"""Real fixture files and explicit Git/full-proof doubles grade repair boundaries, not history authenticity or actual builds."""

from __future__ import annotations

import hashlib
import importlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import TYPE_CHECKING
from unittest import mock

if TYPE_CHECKING:
    from typing import Any

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'linux/scripts/local-proof'))
PROFILE = importlib.import_module('gpu_source_profile')
SDK = '652e5440c9cbbecee486ff86dab873b9ace967ec'
BASE = '175a56af51308679fd084dc91dae621ba0c85b4c'
HIP_PATH = 'linux/scripts/03-media/build/migraphx/check-hip-compiler.sh'
OLD_HIP = 'flags=(--cuda-device-only -std=c++17)\nhip_machine="$(elf_machine_name "$1")" || return\n'
NEW_HIP = 'flags=(--cuda-device-only --no-gpu-bundle-output -std=c++17)\nhip_machine="$(elf_machine_name "$1")" || { printf \'HIP probe output is not a readable ELF device object\\n\' >&2; return 1; }\n'


class GpuSourceProfileTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='GPU source repair ')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.producer = self.root / 'frozen SDK source'
        self.source = self.root / 'reviewed GPU source'
        self.proof = self.root / 'complete new source.json'
        self.proof.write_text('independent fixture proof bytes')
        self.head = 'f' * 40
        self.ancestor = True
        self.base_paths = {'linux/scripts/03-media/build/migraphx/source-check.sh'} | {
            'linux/scripts/local-proof/' + name for name in ('buildcache_transfer.py', 'compiler_plan_profile.py',
                'inventory.json', 'prepare-next-compiler-plan.py', 'seed-buildkit-cache.py')}
        self.repair_paths = {HIP_PATH} | {'linux/scripts/local-proof/' + name for name in
            ('launch-normal-gpu.py', 'gpu_source_profile.py', 'inventory.json')}
        self.repair_paths.update({'AGENTS.md', 'docs/scripts/mutations.json', 'linux/scripts/tests/synthetic.sh'})
        for source in (self.producer, self.source):
            for relative in (HIP_PATH, 'linux/Dockerfile.sdk', 'linux/Dockerfile.amd', 'linux/scripts/01-core/versions.env'):
                path = source / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(OLD_HIP if relative == HIP_PATH else 'independent unchanged input ' + relative)
        (self.source / HIP_PATH).write_text(NEW_HIP)
        self.plan: dict[str, Any] = {'source': str(self.producer), 'source_revision': SDK,
                                     'full_source_preflight_proof': str(self.root / 'original full proof.json')}
        self.full = mock.Mock(return_value={'actual_full_registry_mutations': 17, 'actual_preflight_group_count': 43})
        for name, replacement in [('checked_run', self.git_command), ('full_source', self.full)]:
            patcher = mock.patch.object(PROFILE, name, replacement)
            patcher.start()
            self.addCleanup(patcher.stop)

    def git_command(self, command: list[str]) -> subprocess.CompletedProcess[str]:
        self.assertEqual(command[:3], ['git', '-C', str(self.source)])
        arguments = command[3:]
        if arguments == ['rev-parse', 'HEAD']:
            value = self.head
        elif arguments == ['merge-base', '--is-ancestor', BASE, self.head]:
            if not self.ancestor:
                raise subprocess.CalledProcessError(1, command)
            value = ''
        elif arguments == ['diff', '--name-only', SDK, BASE]:
            value = '\n'.join(sorted(self.base_paths))
        elif arguments == ['diff', '--name-only', BASE, self.head]:
            value = '\n'.join(sorted(self.repair_paths))
        else:
            self.fail('Unexpected fixture Git command: ' + repr(command))
        return subprocess.CompletedProcess(command, 0, value, '')

    def select(self) -> tuple:
        return PROFILE.select_gpu_source(self.plan, self.source, self.proof)

    def test_default_keeps_original_source_and_proof_without_new_profile(self) -> None:
        value = PROFILE.select_gpu_source(self.plan, None, None)
        self.assertEqual(value, (self.producer, SDK, Path(self.plan['full_source_preflight_proof']), None))
        self.full.assert_not_called()

    def test_exact_repair_retains_both_source_identities_and_full_proof(self) -> None:
        source, revision, proof, review = self.select()
        self.assertEqual((source, revision, proof), (self.source, self.head, self.proof))
        self.full.assert_called_once_with(self.source, self.proof, self.head)
        self.assertEqual(review['profile'], 'hip-object-output')
        self.assertEqual(review['SDK_source_revision'], SDK)
        self.assertEqual(review['GPU_source_revision'], self.head)
        self.assertEqual((review['full_registry_mutations'], review['all_preflight_groups']), (17, 43))
        self.assertTrue(review['compiler_and_SDK_inputs_preserved'])
        self.assertFalse(review['cache_hits_claimed'])

    def test_alternate_source_and_proof_must_be_paired(self) -> None:
        for source, proof in ((self.source, None), (None, self.proof)):
            with self.subTest(source=source), self.assertRaisesRegex(AssertionError, 'requires its complete source proof'):
                PROFILE.select_gpu_source(self.plan, source, proof)

    def test_alternate_source_cannot_alias_original(self) -> None:
        with self.assertRaisesRegex(AssertionError, 'must be distinct'):
            PROFILE.select_gpu_source(self.plan, self.producer, self.proof)

    def test_unreviewed_SDK_revision_and_missing_ancestry_refuse(self) -> None:
        self.plan['source_revision'] = 'a' * 40
        with self.assertRaisesRegex(AssertionError, 'reviewed frozen SDK source'):
            self.select()
        self.plan['source_revision'] = SDK
        self.ancestor = False
        with self.assertRaises(subprocess.CalledProcessError):
            self.select()

    def test_intervening_changes_cannot_gain_or_drop_an_image_input(self) -> None:
        original = self.base_paths.copy()
        for changed in (original | {'linux/Dockerfile.sdk'}, original - {'linux/scripts/03-media/build/migraphx/source-check.sh'}):
            with self.subTest(changed=changed):
                self.base_paths = changed
                with self.assertRaisesRegex(AssertionError, 'intervening image inputs'):
                    self.select()

    def test_unknown_repair_paths_and_missing_required_changes_refuse(self) -> None:
        original = self.repair_paths.copy()
        for changed in (original | {'quality/uv.lock'}, original | {'linux/Dockerfile.amd'}, original - {HIP_PATH}):
            with self.subTest(changed=changed):
                self.repair_paths = changed
                with self.assertRaisesRegex(AssertionError, 'HIP repair input changes'):
                    self.select()

    def test_only_the_exact_HIP_flag_and_error_diagnostic_are_allowed(self) -> None:
        path = self.source / HIP_PATH
        for value in (OLD_HIP, NEW_HIP + 'exit 0\n', NEW_HIP.replace('--no-gpu-bundle-output', '-nogpulib')):
            with self.subTest(value=value):
                path.write_text(value)
                with self.assertRaisesRegex(AssertionError, 'more than the exact HIP'):
                    self.select()

    def test_original_HIP_anchors_must_be_present_once(self) -> None:
        for value in ('unrecognized old source', OLD_HIP + OLD_HIP):
            with self.subTest(value=value):
                (self.producer / HIP_PATH).write_text(value)
                with self.assertRaisesRegex(AssertionError, 'Unrecognized original HIP check'):
                    self.select()

    def test_changed_Dockerfile_or_pins_refuse_even_if_Git_double_omits_them(self) -> None:
        for relative in ('linux/Dockerfile.sdk', 'linux/Dockerfile.amd', 'linux/scripts/01-core/versions.env'):
            with self.subTest(relative=relative):
                path = self.source / relative
                original = path.read_bytes()
                path.write_bytes(b'changed input')
                with self.assertRaisesRegex(AssertionError, 'Dockerfile or pins differ'):
                    self.select()
                path.write_bytes(original)

    def test_failed_complete_source_proof_remains_fatal(self) -> None:
        self.full.side_effect = ValueError('fixture complete source proof refused')
        with self.assertRaisesRegex(ValueError, 'complete source proof refused'):
            self.select()

    def exercise_reviewed_profile(self, table: str, profile: str, relatives: tuple[str, ...]) -> None:
        expected = {}
        for relative in relatives:
            path = self.source / relative
            path.parent.mkdir(parents=True,exist_ok=True)
            raw = ('independent reviewed fixture ' + relative).encode()
            path.write_bytes(raw)
            expected[relative] = hashlib.sha256(raw).hexdigest()
        self.repair_paths.update(expected)
        with mock.patch.object(PROFILE,table,expected):
            review = self.select()[3]
            self.assertEqual(review['profile'],profile)
            self.assertEqual(set(review['reviewed_changes']),PROFILE.REPAIR_CHANGES | expected.keys())
            for relative in expected:
                path = self.source / relative
                raw = path.read_bytes()
                path.write_bytes(raw + b'changed')
                with self.subTest(relative=relative), self.assertRaisesRegex(AssertionError,'Backend install repair bytes differ'):
                    self.select()
                path.write_bytes(raw)
            for relative in ('linux/Dockerfile.sdk','linux/scripts/01-core/versions.env'):
                path = self.source / relative
                raw = path.read_bytes()
                path.write_bytes(raw + b'changed')
                with self.subTest(relative=relative), self.assertRaisesRegex(AssertionError,'Dockerfile or pins differ'):
                    self.select()
                path.write_bytes(raw)
            for relative in expected:
                self.repair_paths.remove(relative)
                with self.subTest(relative=relative), self.assertRaisesRegex(AssertionError,'HIP repair input changes|Backend install repair bytes differ'):
                    self.select()
                self.repair_paths.add(relative)

    def test_backend_install_profile_requires_every_reviewed_file_byte(self) -> None:
        self.exercise_reviewed_profile('BACKEND_REPAIR_HASHES','backend-install-manifest',
            ('linux/scripts/03-media/build/migraphx/stage-backend-install.py',
             'linux/scripts/06-packaging/media-payloads.sh','linux/Dockerfile.amd','linux/Dockerfile.package',
             'linux/scripts/local-proof/proof_profiles.py'))

    def test_runtime_load_profile_requires_every_reviewed_file_byte(self) -> None:
        self.exercise_reviewed_profile('RUNTIME_REPAIR_HASHES','backend-runtime-load',
            ('linux/scripts/03-media/build/migraphx/stage-backend-install.py',
             'linux/scripts/03-media/build/migraphx/build-image.sh','linux/scripts/06-packaging/media-payloads.sh',
             'linux/Dockerfile.amd','linux/Dockerfile.package','linux/scripts/local-proof/proof_profiles.py'))

    def test_backend_production_file_hashes_preserve_the_earlier_profile(self) -> None:
        expected = {
            'linux/scripts/03-media/build/migraphx/stage-backend-install.py', 'linux/scripts/06-packaging/media-payloads.sh',
            'linux/Dockerfile.amd', 'linux/Dockerfile.package',
            'linux/scripts/local-proof/proof_profiles.py',
        }
        self.assertEqual(set(PROFILE.BACKEND_REPAIR_HASHES),expected)
        original = json.dumps(PROFILE.BACKEND_REPAIR_HASHES,sort_keys=True).encode()
        self.assertEqual(hashlib.sha256(original).hexdigest(),'a0f24c3d70f3c9a1a3931b17224eb3180add3c0e402f809a982ddda140f4e3a4')

    def test_runtime_profile_rejects_added_or_missing_paths_before_reading_files(self) -> None:
        required = PROFILE.REPAIR_CHANGES | PROFILE.RUNTIME_REPAIR_HASHES.keys()
        for paths in (required | {'quality/uv.lock'}, required - {HIP_PATH},
                      required - {'linux/scripts/03-media/build/migraphx/stage-backend-install.py'}):
            with self.subTest(paths=paths), self.assertRaisesRegex(AssertionError,'HIP repair input changes'):
                PROFILE.repair_profile(paths)

    def test_runtime_production_file_hashes_bind_current_reviewed_bytes(self) -> None:
        expected = {'linux/scripts/03-media/build/migraphx/stage-backend-install.py',
                    'linux/scripts/03-media/build/migraphx/build-image.sh','linux/scripts/06-packaging/media-payloads.sh',
                    'linux/Dockerfile.amd','linux/Dockerfile.package','linux/scripts/local-proof/proof_profiles.py'}
        self.assertEqual(set(PROFILE.RUNTIME_REPAIR_HASHES),expected)
        for relative, sha256 in PROFILE.RUNTIME_REPAIR_HASHES.items():
            self.assertEqual(hashlib.sha256((ROOT / relative).read_bytes()).hexdigest(),sha256,relative)


if __name__ == '__main__':
    unittest.main()
