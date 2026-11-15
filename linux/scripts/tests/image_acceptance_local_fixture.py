"""Synthetic producer files and engine/unit doubles; no real BuildKit, runtime image, source qualification or consumer acceptance."""

from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
import types
from collections.abc import Generator
from contextlib import ExitStack, contextmanager
from pathlib import Path
from typing import Any
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location('local_acceptance_main', SCRIPTS / 'image-acceptance.py')
assert SPEC is not None and SPEC.loader is not None
MAIN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MAIN)
LOCAL = MAIN.local_module()
RUNTIME = LOCAL.local_api('runtime_launch_profile')
NAMES = ['AccelerANTgine', 'OxidANT', 'ANThology', 'OmniAccelerANT', 'jotrockenmitlocken', 'WebDavClient']


class LocalFixture:
    def __init__(self, root: Path, arch: str = 'amd64', variant: str = 'rocm') -> None:
        self.root, self.arch, self.variant = root, arch, variant
        self.platform = 'linux/' + arch
        self.unit = 'webgpu-normal-runtime-' + arch + '-99999999-1.service'
        self.manifest, self.config = 'sha256:' + 'a' * 64, 'sha256:' + 'd' * 64
        self.reference = 'docker.io/ant-local/webgpu-fixture@' + self.manifest
        self.calls: list[list[str]] = []
        self.received_sources: list[dict | None] = []
        self.alias_ready = False
        self.engine_failure = self.consumer_status = 0
        self.consumer_timeout = self.producer_present = self.consumer_present = self.dirty_consumer = False
        self.host_head, self.host_dirty, self.exit_timestamp = 'c' * 40, '', '7'
        self.systemctl_state: dict[str, str] = {}
        self.journal_rows: list[dict[str, Any]] = []
        self.full_source = mock.Mock()
        self.terminal = mock.Mock(return_value={'Id':self.unit, 'LoadState':'loaded', 'ActiveState':'active',
                                               'SubState':'exited', 'MainPID':'0', 'Result':'success', 'ExecMainStatus':'0'})
        self.make_inputs()
        self.make_invocation()
        self.make_image()
        self.save()
        self.plan = root / 'plan.json'
        self.contract = MAIN.read_plan(MAIN.DEFAULT_PLAN)
        self.plan.write_text(json.dumps({**self.contract, 'platform':self.platform}))
        self.args = types.SimpleNamespace(image=self.reference, engine='engine', plan=str(self.plan),
            workspace=str(root / 'consumers'), receipt=str(root / 'receipt.json'), replay=None,
            local_runtime_invocation=str(self.invocation_path))

    def make_inputs(self) -> None:
        self.directory, self.host, self.source = self.root / 'producer', self.root / 'host', self.root / 'source'
        self.directory.mkdir()
        self.source.mkdir()
        self.full_proof = self.root / 'complete-source-proof.json'
        self.full_proof.write_text('{"synthetic":true}\n')
        self.android_path, self.parent_path = self.root / 'android.json', self.root / 'native-parent.json'
        self.android = {'stage':'android', 'variant':self.variant, 'target_arch':self.arch,
                        'source_revision':'b' * 40, 'image':'ant-local/webgpu-fixture:cross-android-' + self.arch}
        self.parent = {'manifest':'sha256:' + 'b' * 64, 'config':'sha256:' + 'e' * 64, 'source_revision':'b' * 40}
        self.android_path.write_text(json.dumps(self.android))
        self.parent_path.write_text(json.dumps(self.parent))
        self.workers = RUNTIME.runtime_worker_files(self.host)
        for path in self.workers:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('# synthetic worker identity\n')
        self.cleanup_path = self.directory / 'cleanup.json'
        self.cleanup = {'exit_status':0, 'owner_label':'org.kataglyphis.normal-runtime', 'run_id':'f' * 32}
        self.cleanup_path.write_text(json.dumps(self.cleanup))
        self.invocation_path = self.directory / 'invocation.json'

    def make_invocation(self) -> None:
        prefix = 'ant-local/webgpu-fixture:runtime-' + (self.variant or 'default') + '-99999999-1'
        self.tag = prefix + '-' + self.arch
        self.parent_reference = 'docker.io/ant-local/webgpu-fixture@' + self.parent['manifest']
        flags = ['CROSS_VARIANT=' + self.variant, 'ENABLE_AMD=' + ('true' if self.variant == 'rocm' else 'false'),
                 'ENABLE_NVIDIA=' + ('true' if self.variant == 'nvidia' else 'false'),
                 'RUNTIME_WHEELS_SOURCE=image', 'RUNTIME_IMAGE_SMOKE=1', 'RUNTIME_INPUT_PREFLIGHT=1',
                 'WRAPPER_CONTENT_GATE=1', 'ANCESTRY_STAMP_ENFORCE=1', 'CROSS_NO_PUSH=1', 'ARTIFACT_CONTEXT_MODE=oci',
                 'CROSS_RUN_ID=runtime-' + 'f' * 32, 'APP_REF=' + '9' * 40,
                 'RUNTIME_ANDROID_PIN_' + self.arch + '=' + self.parent_reference]
        command = ['systemd-run', '--user', '--expand-environment=no', '--unit=' + self.unit, *flags,
                   '/bin/bash', str(self.source / 'linux/scripts/build-runtime-manifest.sh'), '--image', prefix,
                   '--target-arches', self.arch, '--artifact-image-prefix', 'ant-local/webgpu-fixture:cross-android',
                   '--artifact-build-mode', 'cross', '--skip-manifest']
        self.invocation: dict[str, Any] = {'stage':'runtime', 'variant':self.variant, 'target_arch':self.arch,
            'unit':self.unit, 'launch_status':0, 'publication':False, 'output':str(self.directory),
            'source':str(self.source), 'source_revision':'a' * 40, 'parent_source_revision':'b' * 40,
            'source_full_preflight_passed':True, 'producer_source_unchanged':True,
            'source_full_preflight_proof':str(self.full_proof), 'source_full_preflight_sha256':LOCAL.fingerprint(self.full_proof),
            'image':self.tag, 'image_prefix':prefix, 'app_ref':'9' * 40, 'command':command,
            'Android_invocation':str(self.android_path), 'Android_invocation_sha256':LOCAL.fingerprint(self.android_path),
            'parent_OCI_proof':str(self.parent_path), 'parent_OCI_proof_sha256':LOCAL.fingerprint(self.parent_path),
            'parent_manifest':self.parent['manifest'], 'parent_config':self.parent['config'],
            'host_tools_revision':'c' * 40, 'engine_wrapper':str(self.host / 'linux/scripts/owned-nerdctl.py'),
            'selected_host_workers_sha256':{str(path):LOCAL.fingerprint(path) for path in self.workers},
            'run_id':'f' * 32, 'expected_runtime_run_id':'runtime-' + 'f' * 32, 'owner_label':'org.kataglyphis.normal-runtime'}

    def make_image(self) -> None:
        self.tag_image: dict[str, Any] = {'Id':self.config, 'RepoDigests':[self.reference], 'Os':'linux', 'Architecture':self.arch,
            'Config':{'Labels':{'org.kataglyphis.run-id':'runtime-' + 'f' * 32, 'org.kataglyphis.parent-stage':'android',
                'org.kataglyphis.parent-digest':self.parent_reference, 'org.opencontainers.image.revision':'a' * 40,
                'org.opencontainers.image.version':'9' * 40}}}
        self.digest_image = copy.deepcopy(self.tag_image)
        self.alias_row = {'Name':self.reference, 'Digest':self.manifest, 'Platform':self.platform}

    def save(self) -> None:
        self.invocation_path.write_text(json.dumps(self.invocation))

    def api(self, name: str) -> Any:
        return {'runtime_launch_profile':RUNTIME, 'normal_stage_launch':types.SimpleNamespace(full_source=self.full_source),
                'gpu_handoff_profile':types.SimpleNamespace(terminal=self.terminal)}[name]

    def dispatch(self, command: list[str], **options: Any) -> subprocess.CompletedProcess[str]:
        self.calls.append(list(command))
        status, stdout, stderr = 0, '', ''
        if command[0] == 'systemctl':
            stdout = '\n'.join(f'{key}={value}' for key,value in self.systemctl_state.items()) if self.systemctl_state else self.exit_timestamp
        elif command[0] == 'journalctl':
            stdout = '\n'.join(json.dumps(row) for row in self.journal_rows)
        elif command[0] == 'git':
            stdout = self.host_head if command[-1] == 'HEAD' else self.host_dirty
        elif command[0] == 'engine':
            status, stdout, stderr = self.engine_command(command, options)
        else:
            raise AssertionError('Unexpected synthetic command: ' + repr(command))
        result = subprocess.CompletedProcess(command, status, stdout, stderr)
        if options.get('check'):
            result.check_returncode()
        return result

    def engine_command(self, command: list[str], options: dict[str, Any]) -> tuple[int, str, str]:
        if self.engine_failure:
            return self.engine_failure, 'query stdout', 'query stderr'
        if command[1:3] == ['image', 'inspect']:
            image = self.tag_image if command[3] == self.tag else self.digest_image
            return 0, json.dumps([image]), ''
        if command[1] == 'images':
            return 0, json.dumps(self.alias_row) + '\n' if self.alias_ready else '', ''
        if command[1:3] == ['image', 'tag']:
            if command[3:] != [self.tag, self.reference]:
                raise AssertionError('Alias must use actual tag and exact local digest')
            self.alias_ready = True
            return 0, 'tagged', ''
        if command[1] == 'ps':
            producer = any(value.startswith('label=') for value in command)
            present = self.producer_present if producer else self.consumer_present
            selected = command[command.index('--filter') + 1].removeprefix('name=')
            return 0, selected + '\n' if present else '', ''
        if command[1] == 'pull':
            return 0, 'synthetic registry pull', ''
        if command[1] == 'info':
            return 0, 'rootless', ''
        if command[1] == 'run':
            return self.consumer_command(command, options)
        if command[1] == 'rm':
            return 0, '', ''
        raise AssertionError('Unexpected synthetic engine operation: ' + repr(command))

    def consumer_command(self, command: list[str], options: dict[str, Any]) -> tuple[int, str, str]:
        if self.reference not in command:
            raise AssertionError('Consumer must use the immutable local reference')
        if self.consumer_timeout:
            raise subprocess.TimeoutExpired(command, 30)
        options['stdout'].write(b'synthetic consumer output\n')
        return self.consumer_status, '', ''

    def snapshot(self, checkout: Path, spec: dict[str, Any], expected: dict | None) -> dict[str, Any]:
        checkout.mkdir(parents=True, exist_ok=True)
        self.received_sources.append(expected)
        return {'repository':spec['repository'], 'revision':'d' * 40, 'submodules':'', 'data_locks':{'models.lock':'e' * 64}}

    def git(self, checkout: Path, *command: str) -> str:
        if command[0] == 'status':
            return ' M tracked-source' if self.dirty_consumer and checkout != MAIN.ROOT else ''
        return 'c' * 40

    @contextmanager
    def commands(self) -> Generator[None, None, None]:
        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(LOCAL, 'local_api', side_effect=self.api))
            stack.enter_context(mock.patch.object(LOCAL.subprocess, 'run', side_effect=self.dispatch))
            stack.enter_context(mock.patch.object(MAIN, 'git', side_effect=self.git))
            stack.enter_context(mock.patch.object(MAIN, 'source_snapshot', side_effect=self.snapshot))
            stack.enter_context(mock.patch.object(MAIN, 'collect_locks', return_value={}))
            yield
