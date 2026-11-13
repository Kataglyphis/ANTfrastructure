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

TARGETS = {'amd64': ('x86_64-linux-gnu', '/'), 'arm64': ('aarch64-linux-gnu', '/usr/aarch64-linux-gnu'),
           'riscv64': ('riscv64-linux-gnu', '/usr/riscv64-linux-gnu')}
BACKENDS = {'X86', 'AArch64', 'RISCV'}
BAKED_FILES = ('smoke-toolchain.sh', 'smoke-common.sh', 'probe-compiler-defaults.py', 'llvm-loader-path.sh')
PREFIX = '/opt/llvm-target-amd64'


def sha(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def validate(payload: Json, gcc_pin: str, llvm_pin: str, helpers: Helpers) -> Json:
    output = helpers['output']
    assert payload['schema_version'] == 1 and payload['gcc_pin'] == gcc_pin and payload['llvm_pin'] == llvm_pin
    backends = output(payload['backends']).split()
    assert len(backends) == 3 and set(backends) == BACKENDS, 'Native LLVM must carry exactly all three configured backends'
    expected = {f'{driver}-{arch}' for driver in ('clang', 'clang++') for arch in TARGETS}
    assert set(payload['wrappers']) == expected, 'Every actual architecture wrapper is required'
    for name, row in payload['wrappers'].items():
        driver, arch = name.rsplit('-', 1)
        triplet, sysroot = TARGETS[arch]
        assert row['selected'] == '/usr/local/bin/' + name, 'PATH selected another architecture wrapper'
        lines = row['script'].splitlines()
        assert len(lines) == 2 and lines[0] == '#!/usr/bin/env bash', 'Unexpected generated wrapper layout'
        assert shlex.split(lines[1]) == ['exec', f'{PREFIX}/bin/{driver}', '--target=' + triplet,
                                        '--sysroot=' + sysroot, f'--gcc-toolchain=/opt/gcc-{gcc_pin}', '$@'], 'Wrapper does not bind the source driver and target contract'
        helpers['llvm_facts']({'version':row['version']}, llvm_pin)
    smoke = output(payload['smoke'])
    assert '=== Results: 0 failure(s) ===' in smoke and not re.search(r'^\s*FAIL ', smoke, re.MULTILINE), 'The actual baked toolchain smoke must pass'
    for driver in ('clang', 'clang++'):
        for arch in TARGETS:
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
    return {'status':'passed-baked-cross-Clang-wrappers-and-CPU-smokes-only', 'native_backends':sorted(BACKENDS),
            'cross_targets':list(TARGETS), 'wrapper_count':6, 'native_languages':['c','cxx'], 'foreign_static_executions_required':4,
            'compiler_smoke_driver':'/opt/scripts/packaging/smoke-toolchain.sh', 'complete_Cxx_ABI_claimed':False,
            'SDK_acceptance_claimed':False, 'GPU_acceptance_claimed':False}


def collect(evidence: Path, stem: str, gcc_pin: str, llvm_pin: str, helpers: Helpers) -> Json:
    packaging = Path('/opt/scripts/packaging')
    command = helpers['command']
    payload = {'schema_version':1, 'gcc_pin':gcc_pin, 'llvm_pin':llvm_pin,
               'backends':command(PREFIX + '/bin/llvm-config', ['--targets-built']), 'wrappers':{},
               'baked_sha256':{name:sha(packaging / name) for name in BAKED_FILES},
               'environment':{name:os.environ.get(name) for name in ['PATH','LD_LIBRARY_PATH','LD_PRELOAD','CC','CXX']}}
    for driver in ('clang', 'clang++'):
        for arch in TARGETS:
            name = driver + '-' + arch
            path = shutil.which(name)
            assert path is not None, 'Required architecture wrapper is absent: ' + name
            script = Path(path).read_text()
            payload['wrappers'][name] = {'selected':path, 'script':script, 'script_sha256':sha(Path(path)), 'version':command(path, ['--version'])}
    argv = ['bash', str(packaging / 'smoke-toolchain.sh'), ','.join(TARGETS)]
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
    return payload


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--mode', choices=['default','login'], required=True)
    parser.add_argument('--gcc-pin', required=True)
    parser.add_argument('--llvm-pin', required=True)
    args = parser.parse_args()
    assert all(re.fullmatch(r'\d+\.\d+\.\d+', value) for value in [args.gcc_pin,args.llvm_pin])
    stem = '' if args.mode == 'default' else 'login-'
    destination = args.evidence / (stem + 'cross-clang.json')
    assert not destination.exists()
    helpers = runpy.run_path('/opt/scripts/packaging/probe-compiler-defaults.py')
    payload = collect(args.evidence, stem, args.gcc_pin, args.llvm_pin, helpers)
    (args.evidence / (stem + 'cross-clang-raw.json')).write_text(json.dumps(payload,indent=2) + '\n')
    proof = validate(payload,args.gcc_pin,args.llvm_pin,helpers)
    proof.update(mode=args.mode, facts=payload, scope=__doc__)
    destination.write_text(json.dumps(proof,indent=2) + '\n')
    print(json.dumps({key:proof[key] for key in ['status','mode','native_backends','wrapper_count']}))


if __name__ == '__main__':
    main()
