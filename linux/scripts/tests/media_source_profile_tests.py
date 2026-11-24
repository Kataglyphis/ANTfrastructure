"""Real Git fixtures grade the Media-only source boundary; a full-proof double stands in for the preflight, and no build or cache hit is proved."""

from __future__ import annotations

import importlib
import os
import shutil
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
PROFILE = importlib.import_module('media_source_profile')
HANDOFF = importlib.import_module('stage_handoff_profile')
RUNTIME = importlib.import_module('runtime_source_profile')
DOCKERFILES = {
    'linux/Dockerfile.base': 'RUN --mount=type=bind,source=linux/scripts/01-core/common.sh,target=/c true\n',
    'linux/Dockerfile.toolchain': 'COPY --chmod=755 linux/scripts/02-toolchain/ /opt/t/\n'
                                  'RUN --mount=type=bind,source=linux/scripts/03-media/build/${LIB}/x,target=/x true\n',
    'linux/Dockerfile.sdk': 'LABEL org.kataglyphis.build-script-closure=demo\nCOPY --from=hub-scripts / /opt/s/\n',
    'linux/Dockerfile.amd': 'RUN --mount=type=bind,source=linux/scripts/01-core,target=/core true\n',
    'linux/Dockerfile.media': 'RUN --mount=type=bind,source=linux/scripts/03-media/build/opencv/build.sh,target=/b true\n',
    'linux/Dockerfile.android': 'COPY linux/scripts/03-media/android-dispatch.sh /opt/d.sh\n',
}
FILES = {
    'linux/scripts/01-core/common.sh': 'core\n',
    'linux/scripts/01-core/runtime-build-fns.sh': 'host only\n',
    'linux/scripts/03-media/build/opencv/build.sh': 'media input\n',
    'linux/scripts/03-media/android-dispatch.sh': 'android input\n',
    'linux/scripts/02-toolchain/gcc.sh': 'gcc\n',
    'linux/scripts/03-media/build/onnxruntime/x': 'shared upstream prefix\n',
    'linux/scripts/04-runtime/media-only.sh': 'media only\n',
    'linux/scripts/05-frameworks/sdk-only.sh': 'closure member\n',
    'linux/scripts/script-closures/demo.txt': '05-frameworks/sdk-only.sh|frameworks/sdk-only.sh\n',
    'notes/page.txt': 'docs\n',
}


def git(repository: Path, *arguments: str) -> str:
    environment = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    return subprocess.run(['git', '-C', str(repository), *arguments], capture_output=True, text=True,
                          check=True, env=environment).stdout.strip()


class MediaSourceProfileTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='Media source profile ')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.gpu_source = self.root / 'gpu source'
        self.media_source = self.root / 'media source'
        self.write(self.gpu_source, {**DOCKERFILES, **FILES,
                                     'linux/scripts/script_closure.py': (ROOT / 'linux/scripts/script_closure.py').read_text()})
        git(self.gpu_source.parent, 'init', '-q', str(self.gpu_source))
        self.commit(self.gpu_source)
        self.parent = git(self.gpu_source, 'rev-parse', 'HEAD')
        git(self.root, 'clone', '-q', str(self.gpu_source), str(self.media_source))
        self.proof = self.root / 'complete media proof.json'
        self.proof.write_text('independent fixture proof bytes')
        self.full = mock.Mock(return_value={'actual_full_registry_mutations': 17, 'actual_preflight_group_count': 42})
        patcher = mock.patch.object(PROFILE, 'full_source', self.full)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.gpu: dict[str, Any] = {'source': str(self.gpu_source), 'source_revision': self.parent,
                                    'variant': 'rocm', 'stage': 'gpu'}

    @staticmethod
    def write(root: Path, files: dict[str, str]) -> None:
        for relative, text in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)

    @staticmethod
    def commit(repository: Path) -> None:
        git(repository, 'add', '-A')
        git(repository, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'fixture')

    def change(self, files: dict[str, str]) -> None:
        self.write(self.media_source, files)
        self.commit(self.media_source)

    def select(self) -> tuple:
        return PROFILE.select_media_source(self.gpu, self.media_source, self.proof)

    def refused(self, message: str) -> None:
        with self.assertRaisesRegex(AssertionError, message):
            self.select()

    def test_media_only_change_is_admitted_with_its_review(self) -> None:
        self.change({'linux/scripts/04-runtime/media-only.sh': 'new\n', 'notes/page.txt': 'new docs\n'})
        source, revision, proof, review = self.select()
        self.assertEqual((source, revision, proof), (self.media_source.resolve(), git(self.media_source, 'rev-parse', 'HEAD'),
                                                     self.proof.resolve()))
        self.assertEqual(review['changed_paths'], ['linux/scripts/04-runtime/media-only.sh', 'notes/page.txt'])
        self.assertEqual((review['GPU_source_revision'], review['full_registry_mutations']), (self.parent, 17))
        self.assertGreater(review['upstream_inputs_compared'], len(DOCKERFILES))
        self.full.assert_called_once_with(self.media_source.resolve(), self.proof, revision)

    def test_mounted_file_change_is_refused(self) -> None:
        self.change({'linux/scripts/01-core/common.sh': 'changed\n'})
        self.refused('linux/scripts/01-core')

    def test_copied_directory_change_is_refused(self) -> None:
        self.change({'linux/scripts/02-toolchain/new.sh': 'added\n'})
        self.refused('linux/scripts/02-toolchain')

    def test_change_under_an_expanded_mount_prefix_is_refused(self) -> None:
        self.change({'linux/scripts/03-media/build/onnxruntime/x': 'changed\n'})
        self.refused('linux/scripts/03-media/build')

    def test_upstream_dockerfile_change_is_refused(self) -> None:
        self.change({'linux/Dockerfile.sdk': DOCKERFILES['linux/Dockerfile.sdk'] + 'RUN true\n'})
        self.refused('linux/Dockerfile.sdk')

    def test_closure_member_change_is_refused(self) -> None:
        self.change({'linux/scripts/05-frameworks/sdk-only.sh': 'changed closure\n'})
        self.refused('selected SDK or GPU script closure')

    def test_parent_source_must_be_an_ancestor_and_another_revision(self) -> None:
        self.refused('different revision')
        git(self.media_source, 'checkout', '-q', '--orphan', 'unrelated')
        self.write(self.media_source, {'notes/page.txt': 'unrelated history\n'})
        self.commit(self.media_source)
        with self.assertRaises(subprocess.CalledProcessError):
            self.select()

    def test_only_reviewed_rocm_gpu_parents_and_distinct_sources(self) -> None:
        self.change({'notes/page.txt': 'new docs\n'})
        for field, value in (('variant', 'nvidia'), ('stage', 'media')):
            with self.subTest(field=field):
                bad = dict(self.gpu, **{field: value})
                with self.assertRaisesRegex(AssertionError, 'ROCm GPU parents only'):
                    PROFILE.select_media_source(bad, self.media_source, self.proof)
        with self.assertRaisesRegex(AssertionError, 'distinct'):
            PROFILE.select_media_source(self.gpu, self.gpu_source, self.proof)

    def test_handoff_rechecks_the_recorded_review(self) -> None:
        self.change({'notes/page.txt': 'new docs\n'})
        source, revision, proof, review = self.select()
        invocation = {'source': str(source), 'source_revision': revision, 'source_full_preflight_proof': str(proof),
                      'source_full_preflight_sha256': HANDOFF.sha(proof), 'parent_source_revision': self.parent,
                      'Media_source_review': review}
        HANDOFF.validate_source_fields(invocation, self.gpu)
        for field, value in (('Media_source_review', dict(review, changed_paths=[])), ('source_revision', self.parent),
                             ('parent_source_revision', revision)):
            with self.subTest(field=field), self.assertRaises(AssertionError):
                HANDOFF.validate_source_fields(dict(invocation, **{field: value}), self.gpu)
        self.proof.write_text('changed proof bytes')
        with self.assertRaisesRegex(AssertionError, 'proof changed'):
            HANDOFF.validate_source_fields(invocation, self.gpu)

    def test_handoff_without_review_keeps_exact_inheritance(self) -> None:
        previous = {'source': 'a', 'source_revision': 'b', 'source_full_preflight_proof': 'c', 'source_full_preflight_sha256': 'd'}
        HANDOFF.validate_source_fields(dict(previous, parent_source_revision='b'), previous)
        with self.assertRaisesRegex(AssertionError, 'exact proven parent source'):
            HANDOFF.validate_source_fields(dict(previous, source='other', parent_source_revision='b'), previous)

    def runtime_select(self, parent: str | None = None) -> tuple:
        android = {'source': str(self.gpu_source), 'source_revision': parent or self.parent, 'stage': 'android',
                   'variant': 'rocm', 'target_arch': 'amd64'}
        return RUNTIME.select_runtime_source(android, self.media_source, self.proof)

    def test_runtime_host_only_change_is_admitted_with_its_review(self) -> None:
        self.change({'linux/scripts/01-core/runtime-build-fns.sh': 'repaired\n', 'notes/page.txt': 'docs\n'})
        source, review = self.runtime_select()
        self.assertEqual(source, self.media_source.resolve())
        self.assertEqual(review['profile'], 'host-only-runtime-delta')
        self.assertEqual(review['host_only_inputs_changed'], ['linux/scripts/01-core/runtime-build-fns.sh'])
        self.assertEqual(review['runtime_source_revision'], git(self.media_source, 'rev-parse', 'HEAD'))
        self.assertEqual(review['Android_source_revision'], self.parent)

    def test_runtime_change_to_any_base_to_android_input_is_refused(self) -> None:
        for path in ('linux/scripts/01-core/common.sh', 'linux/scripts/03-media/build/opencv/build.sh',
                     'linux/scripts/03-media/android-dispatch.sh', 'linux/Dockerfile.android',
                     'linux/scripts/05-frameworks/sdk-only.sh'):
            with self.subTest(path=path):
                self.change({path: 'changed ' + path + '\n'})
                with self.assertRaisesRegex(AssertionError, 'image input|script closure'):
                    self.runtime_select()
                git(self.media_source, 'reset', '-q', '--hard', 'HEAD~1')

    def test_runtime_stage_naming_the_host_file_is_refused(self) -> None:
        self.change({'linux/Dockerfile.android': DOCKERFILES['linux/Dockerfile.android'] + '# runtime-build-fns.sh\n'})
        named_parent = git(self.media_source, 'rev-parse', 'HEAD')
        self.change({'linux/scripts/01-core/runtime-build-fns.sh': 'repaired\n'})
        with self.assertRaisesRegex(AssertionError, 'names a host-only'):
            self.runtime_select(named_parent)

    def launcher(self, *extra: str) -> subprocess.CompletedProcess[str]:
        required = [f'--{name}={self.root / name}' for name in ('compiler-plan', 'gpu-invocation', 'parent-proof', 'output')]
        command = [sys.executable, str(ROOT / 'linux/scripts/local-proof/launch-normal-media.py'), *required,
                   '--unit=webgpu-normal-media-amd64-20261123-9.service', '--image-repo=ant-local/webgpu-fixture', *extra]
        return subprocess.run(command, capture_output=True, text=True, check=False, timeout=60)

    def test_launcher_requires_both_alternate_source_options_and_rocm(self) -> None:
        for extra, message in (((f'--media-source={self.media_source}',), 'go together'),
                               ((f'--media-source-proof={self.proof}',), 'go together'),
                               (('--variant=nvidia', f'--media-source={self.media_source}', f'--media-source-proof={self.proof}'),
                                'reviewed for ROCm only')):
            with self.subTest(extra=extra):
                result = self.launcher(*extra)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

    def test_launcher_binds_the_reviewed_source_into_its_record(self) -> None:
        text = (ROOT / 'linux/scripts/local-proof/launch-normal-media.py').read_text()
        self.assertIn("source, revision, proof, review = select_media_source(invocation, args.media_source, args.media_source_proof)", text)
        self.assertIn("source_full_preflight_sha256=sha(proof), Media_source_review=review)", text)
        self.assertIn("return launch_stage(source, args.output.resolve()", text)

    def test_shipped_upstream_inputs_cover_the_real_dockerfiles(self) -> None:
        for name in PROFILE.UPSTREAM_DOCKERFILES:
            with self.subTest(name=name):
                self.assertTrue(PROFILE.dockerfile_inputs((ROOT / name).read_text()))
        self.assertTrue(shutil.which('git'))


if __name__ == '__main__':
    unittest.main()
