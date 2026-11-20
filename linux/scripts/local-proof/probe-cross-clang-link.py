#!/usr/bin/env python3
"""Retain real compiler/linker diagnostics and optional GNU-sysroot controls; no final-image or SDK acceptance."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import runpy
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from proof_types import Json

TARGETS = {'amd64': ('x86_64-linux-gnu', None), 'arm64': ('aarch64-linux-gnu', 'qemu-aarch64'),
           'riscv64': ('riscv64-linux-gnu', 'qemu-riscv64')}


def command(argv: list[str]) -> Json:
    helpers = runpy.run_path('/opt/scripts/packaging/probe-compiler-defaults.py')
    return helpers['command'](argv[0], argv[1:])


def sha(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def gnu_sysroot(arch: str, result: Json) -> str:
    assert result['returncode'] == 0
    root = result['stdout'].strip()
    assert root in ({'', '/'} if arch == 'amd64' else {'/'})
    return root


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mode', choices=['baseline', 'gcc-sysroot'], required=True)
    args = parser.parse_args()
    assert args.output.is_dir() and not (args.output / 'results.json').exists()
    native = Path('/opt/llvm-target-amd64/bin/clang')
    before = sha(native)
    gcc_facts = {arch: command(['/opt/gcc-16.2.0/bin/' + ('gcc' if arch == 'amd64' else triplet + '-gcc'), '-print-sysroot'])
                 for arch, (triplet, _) in TARGETS.items()}
    (args.output / 'gnu-sysroots.json').write_text(json.dumps(gcc_facts, indent=2) + '\n')
    records = []
    for arch, (_, qemu) in TARGETS.items():
        gcc = gcc_facts[arch]
        root = gnu_sysroot(arch, gcc)
        for language, driver, filename in [('c', 'clang', 'native-wrapper-probe.c'), ('cxx', 'clang++', 'native-wrapper-probe.cc')]:
            wrapper = Path('/usr/local/bin') / (driver + '-' + arch)
            binary = args.output / (arch + '-' + language)
            source = Path('/inputs') / filename
            options = ['--sysroot=' + root] if args.mode == 'gcc-sysroot' and arch != 'amd64' else []
            argv = [str(wrapper), *options]
            minimal = command([*argv, '-v', '-x', 'c', '/inputs/cross-clang-link-minimal.c', '-o', str(binary) + '-minimal'])
            dynamic = command([*argv, '-v', str(source), '-o', str(binary)])
            static = command([*argv, '-static', str(source), '-o', str(binary) + '-static'])
            execution = None
            if static['returncode'] == 0:
                execution = command(([qemu] if qemu else []) + [str(binary) + '-static'])
            record = {'arch': arch, 'language': language, 'wrapper': wrapper.read_text(), 'wrapper_sha256': sha(wrapper),
                      'source_sha256': sha(source), 'gcc_sysroot': gcc, 'minimal_link': minimal, 'dynamic_link': dynamic, 'static_link': static,
                      'execution': execution, 'search_dirs': command([*argv, '-print-search-dirs']),
                      'crtbegin': command([*argv, '-print-file-name=crtbeginS.o'])}
            records.append(record)
            print(json.dumps({'arch': arch, 'language': language, 'dynamic_status': dynamic['returncode'],
                              'static_status': static['returncode'], 'run_status': execution['returncode'] if execution else None}), flush=True)
    after = sha(native)
    assert before == after
    report = {'status': 'observed-cross-Clang-link-diagnostics-only', 'mode': args.mode, 'records': records,
              'native_clang_sha256_before': before, 'native_clang_sha256_after': after,
              'actual_backends': command(['/opt/llvm-target-amd64/bin/llvm-config', '--targets-built']),
              'environment': {key: os.environ.get(key) for key in ['PATH', 'LD_LIBRARY_PATH', 'LD_PRELOAD', 'CC', 'CXX']},
              'scope': __doc__, 'SDK_parent_qualified': False}
    (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
