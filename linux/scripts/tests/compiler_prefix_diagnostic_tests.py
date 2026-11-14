#!/usr/bin/env python3
"""Check diagnostic-only prefix construction and terminal refusals; no image build or linker result is proved."""

import copy
import importlib.util
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[1] / 'local-proof'
sys.path.insert(0, str(TOOLS))
spec = importlib.util.spec_from_file_location('compiler_prefix_diagnostic', TOOLS / 'compiler-prefix-diagnostic.py')
assert spec is not None and spec.loader is not None
MODULE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(MODULE)
probe_spec = importlib.util.spec_from_file_location('link_probe_launcher', TOOLS / 'launch-cross-clang-link-probe.py')
assert probe_spec is not None and probe_spec.loader is not None
PROBE = importlib.util.module_from_spec(probe_spec)
probe_spec.loader.exec_module(PROBE)


class DiagnosticTests(unittest.TestCase):
    def test_prefix_keeps_original_bytes_and_required_source_gate(self) -> None:
        source = 'FROM original\nLABEL kataglyphis.step=script-modes\nRUN parser\n' + MODULE.MARKER + 'RUN publish_llvm_target_ld_path; smoke-toolchain.sh\n'
        result = MODULE.prefix(source)
        self.assertTrue(result.startswith(source.split(MODULE.MARKER)[0]))
        self.assertIn(MODULE.VALUE, result)
        self.assertIn('smoke-toolchain.sh', source)
        for bad in [source + MODULE.MARKER, source.replace(MODULE.MARKER, ''), source.replace('publish_llvm_target_ld_path', 'other'),
                    source.replace('smoke-toolchain.sh', 'other'), source.replace('LABEL kataglyphis.step=script-modes', 'other')]:
            with self.subTest(source=bad), self.assertRaises(AssertionError):
                MODULE.prefix(bad)

    def test_command_preserves_spaces_and_refuses_push_or_cache_changes(self) -> None:
        argv = ['nerdctl', 'build', '--pull=false', '-t', 'old', '-f', 'oldfile', '--build-arg', 'VALUE=with spaces', '.']
        result = MODULE.command_for_prefix(argv, Path('/with spaces/Dockerfile'), 'ant-local/test-unverified:1')
        self.assertEqual(result[-3:], ['--build-arg', 'VALUE=with spaces', '.'])
        self.assertEqual(result[result.index('-f') + 1], '/with spaces/Dockerfile')
        self.assertEqual(argv[4:7], ['old', '-f', 'oldfile'])
        for flag in ['--push', '--push=true', '--output', '--output=type=image,push=true', '--no-cache', '--no-cache=true', '--target=unrelated']:
            with self.subTest(flag=flag), self.assertRaises(AssertionError):
                MODULE.command_for_prefix(argv[:-1] + [flag, '.'], Path('Dockerfile'), 'ant-local/test-unverified:1')
        for image in ['ant-local/test:1', 'remote/test-unverified:1', 'ant-local/test-unverified@sha256:a']:
            with self.subTest(image=image), self.assertRaises(AssertionError):
                MODULE.command_for_prefix(argv, Path('Dockerfile'), image)
        for flag in ['-t', '-f']:
            with self.subTest(duplicate=flag), self.assertRaises(AssertionError):
                MODULE.command_for_prefix(argv[:-1] + [flag, 'duplicate', '.'], Path('Dockerfile'), 'ant-local/test-unverified:1')

    def test_command_requires_the_original_transport_and_exact_flags(self) -> None:
        good = ['nerdctl', 'build', '--pull=false', '-t', 'old', '-f', 'oldfile', '--build-arg', 'A=B', '.']
        for index, value in [(0, 'other'), (1, 'run'), (2, '--pull=true'), (3, '--tag'), (5, '--file'), (9, 'foreign-context')]:
            bad = good.copy()
            bad[index] = value
            with self.subTest(index=index), self.assertRaises(AssertionError):
                MODULE.command_for_prefix(bad, Path('Dockerfile'), 'ant-local/test-unverified:1')

    def test_only_loaded_failed_terminal_can_supply_a_diagnostic(self) -> None:
        good = {'LoadState': 'loaded', 'MainPID': '0', 'ActiveState': 'failed', 'SubState': 'failed',
                'ExecMainStatus': '1', 'ExecMainExitTimestampMonotonic': '123'}
        with patch.object(MODULE, 'state', return_value=good):
            self.assertEqual(MODULE.require_failure({'unit': 'fixture.service'}), good)
        for key, value in [('LoadState', 'not-found'), ('MainPID', '42'), ('ActiveState', 'active'),
                           ('SubState', 'exited'), ('ExecMainStatus', '0'), ('ExecMainExitTimestampMonotonic', '0')]:
            bad = copy.deepcopy(good)
            bad[key] = value
            with self.subTest(key=key), patch.object(MODULE, 'state', return_value=bad), self.assertRaises(AssertionError):
                MODULE.require_failure({'unit': 'fixture.service'})


class ProbeReceiptTests(unittest.TestCase):
    def fixture(self, mode: str) -> dict:
        records = []
        for arch in ['amd64', 'arm64', 'riscv64']:
            for language in ['c', 'cxx']:
                required = mode == 'gcc-sysroot' or arch == 'amd64'
                child = {'returncode': 0 if required else 1, 'stdout': '', 'stderr': '' if required else 'fixture linker error', 'timed_out': False}
                records.append({'arch': arch, 'language': language, 'minimal_link': copy.deepcopy(child),
                    'dynamic_link': copy.deepcopy(child), 'static_link': copy.deepcopy(child),
                    'gcc_sysroot': {'returncode': 0, 'stdout': '/\n'},
                    'execution': {'returncode': 0, 'stdout': '42\n'} if required else None})
        return {'status': 'observed-cross-Clang-link-diagnostics-only', 'mode': mode, 'records': records,
                'actual_backends': {'returncode': 0, 'stdout': 'X86 AArch64 RISCV AMDGPU'}, 'environment': {'LD_PRELOAD': None},
                'native_clang_sha256_before': 'fixture', 'native_clang_sha256_after': 'fixture'}

    def test_native_gnu_empty_root_and_foreign_root_are_distinct(self) -> None:
        for mode in ['baseline', 'gcc-sysroot']:
            data = self.fixture(mode)
            for row in data['records'][:2]:
                row['gcc_sysroot']['stdout'] = ''
            PROBE.validate(data, mode)
        for root in ['', '/foreign']:
            data = self.fixture('gcc-sysroot')
            data['records'][2]['gcc_sysroot']['stdout'] = root
            with self.subTest(root=root), self.assertRaises(AssertionError):
                PROBE.validate(data, 'gcc-sysroot')

    def test_both_control_modes_require_actual_scope(self) -> None:
        for mode in ['baseline', 'gcc-sysroot']:
            with self.subTest(mode=mode):
                PROBE.validate(self.fixture(mode), mode)
        for edit in [lambda p: p.update(status='passed-image'), lambda p: p.update(mode='different'),
                     lambda p: p['actual_backends'].update(returncode=1), lambda p: p['actual_backends'].update(stdout='X86'),
                     lambda p: p['environment'].update(LD_PRELOAD='/override.so'), lambda p: p['records'].pop(),
                     lambda p: p['records'][0].update(language='other'), lambda p: p.update(native_clang_sha256_after='changed'),
                     lambda p: p['records'][0]['gcc_sysroot'].update(stdout='/wrong'),
                     lambda p: p['records'][0]['gcc_sysroot'].update(returncode=1),
                     lambda p: p['records'][0]['minimal_link'].update(returncode=1),
                     lambda p: p['records'][0]['dynamic_link'].update(returncode=1),
                     lambda p: p['records'][0]['static_link'].update(returncode=1),
                     lambda p: p['records'][0].update(execution=None),
                     lambda p: p['records'][0]['execution'].update(returncode=1),
                     lambda p: p['records'][0]['execution'].update(stdout='41')]:
            data = self.fixture('gcc-sysroot')
            edit(data)
            with self.subTest(edit=edit), self.assertRaises(AssertionError):
                PROBE.validate(data, 'gcc-sysroot')

    def test_expected_linker_failure_requires_a_real_nonzero_status_and_stderr(self) -> None:
        for edit in [lambda p: p['records'][2]['minimal_link'].update(returncode=0),
                     lambda p: p['records'][2]['minimal_link'].update(returncode=None),
                     lambda p: p['records'][2]['minimal_link'].update(returncode=-9),
                     lambda p: p['records'][2]['minimal_link'].update(timed_out=True),
                     lambda p: p['records'][2]['minimal_link'].update(stderr='')]:
            data = self.fixture('baseline')
            edit(data)
            with self.subTest(edit=edit), self.assertRaises(AssertionError):
                PROBE.validate(data, 'baseline')


if __name__ == '__main__':
    unittest.main()
