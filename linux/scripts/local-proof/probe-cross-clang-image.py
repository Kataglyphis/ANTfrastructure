#!/usr/bin/env python3
"""Check real baked cross wrappers and CPU code generation; this does not prove full C++ ABI, SDK or GPU acceptance."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import runpy
import shlex
import shutil
import subprocess
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from proof_types import Helpers, Json

TARGETS = {'amd64': ('x86_64-linux-gnu', '/'), 'arm64': ('aarch64-linux-gnu', '/'),
           'riscv64': ('riscv64-linux-gnu', '/')}
BACKENDS = {'X86', 'AArch64', 'RISCV', 'AMDGPU'}
BAKED_FILES = ('smoke-toolchain.sh', 'smoke-common.sh', 'probe-compiler-defaults.py', 'llvm-loader-path.sh')
PREFIX = '/opt/llvm-target-amd64'
PROFILES = ('compiler', *('sdk-' + arch for arch in TARGETS))
FOREIGN_MACHINES = {'arm64': 'AArch64', 'riscv64': 'RISC-V'}


def sha(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def sdk_materialization(payload: Json, arch: str, helpers: Helpers) -> None:
    materialized = payload.get('materialization')
    assert isinstance(materialized, dict), 'SDK materialization facts are required'
    assert materialized['alias_is_symlink'] is True and materialized['alias_target'] == '/opt/llvm-target', 'SDK native architecture alias differs'
    expected = sorted({'llvm-target-amd64', 'llvm-target-' + arch})
    assert materialized['architecture_prefixes'] == expected, 'SDK architecture prefixes differ'
    assert set(materialized['drivers']) == {'clang', 'clang++'}, 'Both SDK driver byte comparisons are required'
    for row in materialized['drivers'].values():
        assert re.fullmatch(r'[0-9a-f]{64}', row['alias_sha256']) and row['alias_sha256'] == row['target_sha256'], 'SDK architecture alias selects different compiler bytes'
        if arch != 'amd64':
            machine = re.escape(FOREIGN_MACHINES[arch])
            assert re.search(rf'^\s*Machine:\s+{machine}\s*$', helpers['output'](row['elf']), re.MULTILINE), 'Target-native SDK driver has the wrong ELF machine'
    if arch != 'amd64':
        assert materialized['host_prefix_is_real'] is True, 'Foreign SDK must retain its host-native tool prefix'


def validate(payload: Json, gcc_pin: str, llvm_pin: str, helpers: Helpers, *, profile: str = 'compiler') -> Json:
    assert profile in PROFILES, 'Unknown compiler image probe profile'
    assert payload.get('profile', 'compiler') == profile, 'Image probe profile differs'
    arch = profile.removeprefix('sdk-')
    targets = TARGETS if profile == 'compiler' else {arch: TARGETS[arch]}
    if profile != 'compiler':
        sdk_materialization(payload, arch, helpers)
    output = helpers['output']
    assert payload['schema_version'] == 1 and payload['gcc_pin'] == gcc_pin and payload['llvm_pin'] == llvm_pin
    backends = output(payload['backends']).split()
    assert len(backends) == 4 and set(backends) == BACKENDS, 'Native LLVM must carry exactly the three CPU backends and AMDGPU'
    expected = {f'{driver}-{arch}' for driver in ('clang', 'clang++') for arch in targets}
    assert set(payload['wrappers']) == expected, 'Every actual architecture wrapper is required'
    for name, row in payload['wrappers'].items():
        driver, arch = name.rsplit('-', 1)
        triplet, sysroot = targets[arch]
        assert row['selected'] == '/usr/local/bin/' + name, 'PATH selected another architecture wrapper'
        lines = row['script'].splitlines()
        assert len(lines) == 2 and lines[0] == '#!/usr/bin/env bash', 'Unexpected generated wrapper layout'
        assert shlex.split(lines[1]) == ['exec', f'{PREFIX}/bin/{driver}', '--target=' + triplet,
                                        '--sysroot=' + sysroot, f'--gcc-toolchain=/opt/gcc-{gcc_pin}', '$@'], 'Wrapper does not bind the source driver and target contract'
        helpers['llvm_facts']({'version':row['version']}, llvm_pin)
    smoke = output(payload['smoke'])
    assert '=== Results: 0 failure(s) ===' in smoke and not re.search(r'^\s*FAIL ', smoke, re.MULTILINE), 'The actual baked toolchain smoke must pass'
    for driver in ('clang', 'clang++'):
        for arch in targets:
            label = f'{driver} ({arch} wrapper)'
            for suffix in ['cc1 compile-to-object smoke OK', 'link smoke OK']:
                assert smoke.count(f'  PASS {label}: {suffix}\n') == 1, 'Missing actual wrapper compiler assertion: ' + label
            assert re.search(r'^  PASS ' + re.escape(label) + r': object ELF machine=.+$', smoke, re.MULTILINE), 'Missing target object ELF assertion'
            if arch != 'amd64':
                assert re.search(r'^  PASS ' + re.escape(label) + r': static binary RUNS under \S+ \(exit 42\)$', smoke, re.MULTILINE), 'Actual foreign static execution is required'
    assert set(payload['native_programs']) == {'c', 'cxx'}, 'Both real native languages are required'
    for name, row in payload['native_programs'].items():
        output(row['build'])
        assert output(row['execution']) == '42', 'Native executable returned the wrong result: ' + name
        assert re.search(r'^\s*Machine:\s+Advanced Micro Devices X86-64\s*$', output(row['elf']), re.MULTILINE), 'Native executable has the wrong ELF machine'
    assert not payload['environment'].get('LD_PRELOAD'), 'Preload cannot qualify the ordinary image'
    status = 'passed-baked-cross-Clang-wrappers-and-CPU-smokes-only' if profile == 'compiler' else 'passed-baked-SDK-Clang-wrappers-and-CPU-smokes-only'
    return {'status':status, 'profile':profile, 'native_backends':sorted(BACKENDS),
            'cross_targets':list(targets), 'wrapper_count':2 * len(targets), 'native_languages':['c','cxx'], 'foreign_static_executions_required':2 * len(targets.keys() - {'amd64'}),
            'compiler_smoke_driver':'/opt/scripts/packaging/smoke-toolchain.sh', 'complete_Cxx_ABI_claimed':False,
            'SDK_acceptance_claimed':False, 'GPU_acceptance_claimed':False}


def collect_sdk(arch: str, helpers: Helpers) -> Json:
    alias = Path('/opt/llvm-target-' + arch)
    target = Path('/opt/llvm-target')
    drivers: dict[str, Json] = {
        name: {'alias_sha256':sha(alias / 'bin' / name), 'target_sha256':sha(target / 'bin' / name)}
        for name in ('clang', 'clang++')
    }
    for name, row in drivers.items():
        if arch != 'amd64':
            row['elf'] = helpers['command']('readelf', ['-h', str(target / 'bin' / name)])
    return {'alias_is_symlink':alias.is_symlink(), 'alias_target':os.readlink(alias),
            'architecture_prefixes':sorted(path.name for path in Path('/opt').glob('llvm-target-*')),
            'host_prefix_is_real':Path(PREFIX).is_dir() and not Path(PREFIX).is_symlink(), 'drivers':drivers}


def collect(evidence: Path, stem: str, gcc_pin: str, llvm_pin: str, helpers: Helpers, *, profile: str = 'compiler') -> Json:
    arch = profile.removeprefix('sdk-')
    targets = TARGETS if profile == 'compiler' else {arch: TARGETS[arch]}
    packaging = Path('/opt/scripts/packaging')
    command = helpers['command']
    payload = {'schema_version':1, 'profile':profile, 'gcc_pin':gcc_pin, 'llvm_pin':llvm_pin,
               'backends':command(PREFIX + '/bin/llvm-config', ['--targets-built']), 'wrappers':{},
               'baked_sha256':{name:sha(packaging / name) for name in BAKED_FILES},
               'environment':{name:os.environ.get(name) for name in ['PATH','LD_LIBRARY_PATH','LD_PRELOAD','CC','CXX']}}
    for driver in ('clang', 'clang++'):
        for arch in targets:
            name = driver + '-' + arch
            path = shutil.which(name)
            assert path is not None, 'Required architecture wrapper is absent: ' + name
            script = Path(path).read_text()
            payload['wrappers'][name] = {'selected':path, 'script':script, 'script_sha256':sha(Path(path)), 'version':command(path, ['--version'])}
    argv = ['bash', str(packaging / 'smoke-toolchain.sh'), ','.join(targets)]
    raw_log = evidence / (stem + 'cross-toolchain.log')
    with raw_log.open('x') as log:
        child = subprocess.run(argv, text=True, stdout=log, stderr=subprocess.STDOUT, timeout=180, check=False)
    payload['smoke'] = {'argv':argv, 'returncode':child.returncode, 'timed_out':False, 'stdout':raw_log.read_text(), 'stderr':''}
    programs = {}
    for language, driver, input_name in [('c','clang','native-wrapper-probe.c'), ('cxx','clang++','native-wrapper-probe.cc')]:
        source = Path('/inputs') / input_name
        binary = evidence / (stem + 'native-' + language)
        build = command('/usr/local/bin/' + driver + '-amd64', [str(source), '-o', str(binary)])
        programs[language] = {'source_sha256':sha(source), 'build':build, 'execution':command(str(binary), []),
                              'elf':command('readelf', ['-h', str(binary)])}
    payload['native_programs'] = programs
    if profile != 'compiler':
        payload['materialization'] = collect_sdk(profile.removeprefix('sdk-'), helpers)
    return payload


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--mode', choices=['default','login'], required=True)
    parser.add_argument('--gcc-pin', required=True)
    parser.add_argument('--llvm-pin', required=True)
    parser.add_argument('--profile', choices=PROFILES, default='compiler')
    args = parser.parse_args()
    assert all(re.fullmatch(r'\d+\.\d+\.\d+', value) for value in [args.gcc_pin,args.llvm_pin])
    stem = '' if args.mode == 'default' else 'login-'
    destination = args.evidence / (stem + 'cross-clang.json')
    assert not destination.exists()
    helpers = runpy.run_path('/opt/scripts/packaging/probe-compiler-defaults.py')
    payload = collect(args.evidence, stem, args.gcc_pin, args.llvm_pin, helpers, profile=args.profile)
    (args.evidence / (stem + 'cross-clang-raw.json')).write_text(json.dumps(payload,indent=2) + '\n')
    proof = validate(payload,args.gcc_pin,args.llvm_pin,helpers,profile=args.profile)
    proof.update(mode=args.mode, facts=payload, scope=__doc__)
    destination.write_text(json.dumps(proof,indent=2) + '\n')
    print(json.dumps({key:proof[key] for key in ['status','mode','native_backends','wrapper_count']}))


if __name__ == '__main__':
    main()
