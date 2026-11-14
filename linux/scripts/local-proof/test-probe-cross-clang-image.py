#!/usr/bin/env python3
"""Exercise receipt refusals with independent fixture data; this does not establish a real compiler or SDK success."""

from __future__ import annotations

import argparse
import copy
import json
import runpy
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from proof_types import Edit, Json

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--probe', type=Path, default=Path(__file__).with_name('probe-cross-clang-image.py'))
parser.add_argument('--source', type=Path, required=True)
args = parser.parse_args()
probe = runpy.run_path(str(args.probe))
helpers = runpy.run_path(str(args.source / 'linux/scripts/06-packaging/probe-compiler-defaults.py'))

def child(text: str) -> Json:
    return {'argv':['fixture-only'], 'returncode':0, 'timed_out':False, 'stdout':text, 'stderr':''}

wrappers = {}
smoke = ['=== Toolchain Smoke Test ===\n']
for arch, triplet, sysroot, machine, qemu in [
        ('amd64','x86_64-linux-gnu','/','Advanced Micro Devices X86-64',None),
        ('arm64','aarch64-linux-gnu','/','AArch64','qemu-aarch64'),
        ('riscv64','riscv64-linux-gnu','/','RISC-V','qemu-riscv64')]:
    for driver in ['clang','clang++']:
        name = driver + '-' + arch
        wrappers[name] = {'selected':'/usr/local/bin/' + name,
                          'script':f'#!/usr/bin/env bash\nexec "/opt/llvm-target-amd64/bin/{driver}" --target={triplet} --sysroot={sysroot} --gcc-toolchain=/opt/gcc-16.2.0 "$@"\n',
                          'version':child('clang version 23.1.5 (fixture-only)\n')}
        label = f'{driver} ({arch} wrapper)'
        smoke += [f'  PASS {label}: cc1 compile-to-object smoke OK\n',
                  f'  PASS {label}: object ELF machine={machine}\n', f'  PASS {label}: link smoke OK\n']
        if qemu:
            smoke += [f'  PASS {label}: static binary RUNS under {qemu} (exit 42)\n']
smoke += ['=== Results: 0 failure(s) ===\n']
payload = {'schema_version':1, 'gcc_pin':'16.2.0', 'llvm_pin':'23.1.5', 'backends':child('X86 AArch64 RISCV AMDGPU\n'),
           'wrappers':wrappers, 'smoke':child(''.join(smoke)), 'environment':{'LD_PRELOAD':None},
           'native_programs':{language:{'build':child(''), 'execution':child('42\n'), 'elf':child('  Machine: Advanced Micro Devices X86-64\n')}
                              for language in ['c','cxx']}}

def validate(data: Json) -> Json:
    return probe['validate'](data,'16.2.0','23.1.5',helpers)

assert validate(payload)['wrapper_count'] == 6
cases = []
def reject(name: str, edit: Edit) -> None:
    case = copy.deepcopy(payload)
    edit(case)
    try:
        validate(case)
    except (AssertionError, ValueError):
        cases.append(name)
    else:
        raise AssertionError('Expected guarded failure was accepted: ' + name)

reject('missing-backend', lambda p:p['backends'].update(stdout='X86\n'))
reject('missing-AMDGPU', lambda p:p['backends'].update(stdout='X86 AArch64 RISCV\n'))
reject('duplicate-backend', lambda p:p['backends'].update(stdout='X86 AArch64 RISCV RISCV\n'))
reject('failed-backend-probe', lambda p:p['backends'].update(returncode=47))
reject('missing-wrapper', lambda p:p['wrappers'].pop('clang++-arm64'))
reject('shadowed-wrapper', lambda p:p['wrappers']['clang-amd64'].update(selected='/shadow/clang-amd64'))
reject('apt-driver-path', lambda p:p['wrappers']['clang-arm64'].update(script=p['wrappers']['clang-arm64']['script'].replace('/opt/llvm-target-amd64/bin/clang','/usr/bin/clang-23')))
reject('wrong-sysroot', lambda p:p['wrappers']['clang-riscv64'].update(script=p['wrappers']['clang-riscv64']['script'].replace('--sysroot=/','--sysroot=/wrong')))
for arch, triplet in [('arm64','aarch64-linux-gnu'), ('riscv64','riscv64-linux-gnu')]:
    for driver in ['clang','clang++']:
        name = driver + '-' + arch
        reject('double-root-' + name, lambda p, name=name, triplet=triplet:p['wrappers'][name].update(script=p['wrappers'][name]['script'].replace('--sysroot=/','--sysroot=/usr/' + triplet)))
reject('stale-full-pin', lambda p:p['wrappers']['clang++-amd64']['version'].update(stdout='clang version 23.1.6\n'))
reject('failed-version-child', lambda p:p['wrappers']['clang++-riscv64']['version'].update(returncode=47))
reject('failed-smoke', lambda p:p['smoke'].update(returncode=47))
reject('missing-summary', lambda p:p['smoke'].update(stdout=p['smoke']['stdout'].replace('=== Results: 0 failure(s) ===\n','')))
reject('hidden-smoke-failure', lambda p:p['smoke'].update(stdout=p['smoke']['stdout']+'  FAIL fixture\n'))
reject('missing-link-assertion', lambda p:p['smoke'].update(stdout=p['smoke']['stdout'].replace('  PASS clang (amd64 wrapper): link smoke OK\n','')))
reject('missing-object-assertion', lambda p:p['smoke'].update(stdout=p['smoke']['stdout'].replace('  PASS clang++ (arm64 wrapper): object ELF machine=AArch64\n','')))
reject('missing-foreign-execution', lambda p:p['smoke'].update(stdout=p['smoke']['stdout'].replace('  PASS clang (arm64 wrapper): static binary RUNS under qemu-aarch64 (exit 42)\n','')))
reject('missing-native-language', lambda p:p['native_programs'].pop('cxx'))
reject('failed-native-build', lambda p:p['native_programs']['cxx']['build'].update(returncode=47))
reject('wrong-native-result', lambda p:p['native_programs']['c']['execution'].update(stdout='41\n'))
reject('wrong-native-ELF', lambda p:p['native_programs']['cxx']['elf'].update(stdout='  Machine: AArch64\n'))
reject('preload', lambda p:p['environment'].update(LD_PRELOAD='/diagnostic.so'))
reject('schema', lambda p:p.update(schema_version=0))
reject('receipt-pin-drift', lambda p:p.update(llvm_pin='23.1.6'))
print(json.dumps({'status':'passed-independent-qualification-receipt-fixtures-only','positive_controls':1,'refusal_controls':len(cases),'cases':cases}))
