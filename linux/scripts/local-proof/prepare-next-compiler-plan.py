#!/usr/bin/env python3
"""Prepare the next ordinary compiler command and explicit changed-input boundary; this neither launches nor claims cache hits."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import re
import subprocess
from pathlib import Path
from typing import TYPE_CHECKING

from compiler_plan_profile import (
    PROFILES,
    reviewed_transport,
    storage_changes,
    validate_input_changes,
)

if TYPE_CHECKING:
    from proof_types import Json

parser = argparse.ArgumentParser(description=__doc__)
for name in ['template', 'source', 'targeted-proof', 'commit-proof', 'output']:
    parser.add_argument('--' + name, required=True, type=Path)
parser.add_argument('--unit', required=True)
parser.add_argument('--image-repo', required=True)
parser.add_argument('--profile', choices=PROFILES, default='clang-wrapper-repair')
args = parser.parse_args()
assert not args.output.exists()
source = args.source.resolve(strict=True)
work = args.output.resolve().parent
old = json.loads(args.template.read_text())
assert re.fullmatch(r'webgpu-normal-compiler-[A-Za-z0-9_.-]+\.service', args.unit)
assert re.fullmatch(r'ant-local/[A-Za-z0-9_.-]+', args.image_repo)

def run(command: list[str]) -> str:
    return subprocess.check_output(command, text=True, timeout=60)

def sha(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def save(path: Path, data: Json) -> None:
    assert not path.exists()
    path.write_text(json.dumps(data, indent=2) + '\n')

head = run(['git', '-C', str(source), 'rev-parse', 'HEAD']).strip()
assert not run(['git', '-C', str(source), 'status', '--porcelain']).strip()
targeted = json.loads(args.targeted_proof.read_text())
commit = json.loads(args.commit_proof.read_text())
assert targeted['status'] == 'passed-targeted-source-native-Clang-wrapper-and-backend-repair-only'
assert targeted['owner_source'] == str(source) and targeted['quality_group_count'] == 26
assert targeted['cleanup_exit_status'] == targeted['independent_engine_query_exit_status'] == 0 and targeted['owned_container_absent']
assert commit['head'] == head and commit['source'] == str(source)
assert commit['normal_hook_status'] == 0 and commit['actual_hook_mutations'] == 16 and commit['exact_committed_patch_match'] and commit['clean']
assert commit['patch_sha256'] == targeted['patch_sha256']
assert old['required_bytes'] == 193273528320
old_repo = old['local_image'].rsplit(':', 1)[0]
compiler_output = work / 'compiler-rebuild-1'
mapping = {old['source']: str(source), old['output']: str(compiler_output), old_repo: args.image_repo,
           old['unit'].removesuffix('.service'): args.unit.removesuffix('.service'), old['source_revision']: head}
pattern = re.compile('|'.join(re.escape(key) for key in sorted(mapping, key=len, reverse=True)))
command = [pattern.sub(lambda match: mapping[match[0]], value) for value in old['command']]
assert '--push' not in command and command[-1] == str(compiler_output / 'logs')
audit = json.loads((args.template.parent / old['storage_path_audit']).read_text())
transport_review = reviewed_transport(source, args.profile)
control_changes = storage_changes(source, audit['files_sha256'], transport_review)
manager = dict(line.split('=', 1) for line in run(['systemctl', '--user', 'show-environment']).splitlines() if '=' in line)
assert all(name not in manager for name in audit['manager_keys_unset'])
audit.update(observed_at=datetime.datetime.now(datetime.UTC).isoformat(), source_revision=head, plan=args.output.name,
             relevant_user_manager_env={}, source_control_files_equal_previous_audit=not control_changes,
             reviewed_control_changes=control_changes, compiler_plan_profile=args.profile)
audit['files_sha256'] = {name:sha(source / name) for name in audit['files_sha256']}
old_inputs = json.loads(Path(old['expensive_inputs_proof']).read_text())
differences = {}
unchanged = {}
for name, previous in old_inputs['unchanged_bind_files'].items():
    current = {'sha256': sha(source / name), 'size': (source / name).stat().st_size}
    if current == previous:
        unchanged[name] = current
    else:
        differences[name] = {'previous': previous, 'current': current}
materializer = 'linux/scripts/02-toolchain/materialize-llvm-target.sh'
validate_input_changes(differences, args.profile, transport_review)
accepted_materializer = subprocess.check_output(['git', '-C', str(source), 'show', 'e7ca4436dbb5e58d8f9e0fb49105b6d3b636e9e9:' + materializer], timeout=60)
assert (source / materializer).read_bytes() == accepted_materializer
dockerfile = (source / 'linux/Dockerfile.toolchain').read_text()
previous_dockerfile = (Path(old['source']) / 'linux/Dockerfile.toolchain').read_text()
assert dockerfile == previous_dockerfile
gnu_match = re.search(r'^RUN .*?(?=\n\n)', dockerfile, re.MULTILINE | re.DOTALL)
assert gnu_match is not None, 'Compiler Dockerfile has no first RUN block'
gnu_run = gnu_match.group(0)
gnu_mounts = re.findall(r'--mount=type=bind,source=([^,\s]+)', gnu_run)
assert gnu_mounts and set(gnu_mounts) <= unchanged.keys()
comparison = {'status':('reviewed-GNU-closure-equal-LLVM-closure-intentionally-changed-only' if args.profile == 'clang-wrapper-repair' else 'reviewed-GNU-closure-equal-LLVM-inputs-and-declared-transport-changes-only'),
              'compiler_plan_profile':args.profile, 'reviewed_OCI_transport':transport_review,
              'source_revision':head, 'reference_revision':old['source_revision'], 'unchanged_bound_files':unchanged,
              'changed_bound_files':differences, 'identical_Dockerfile_sha256':sha(source / 'linux/Dockerfile.toolchain'),
              'GNU_RUN_bind_files':gnu_mounts, 'GNU_mounts_unchanged':True, 'cache_hits_claimed':False,
              'scope':'Byte comparisons establish cache-key boundaries only. Actual cache results are required from the new canonical solve.'}
registry = json.loads((source / 'docs/scripts/mutations.json').read_text())
production = ['linux/scripts/02-toolchain/llvm.sh', 'linux/scripts/02-toolchain/llvm-cross.sh', 'linux/scripts/06-packaging/smoke-toolchain.sh']
plan = {'status':'prepared-awaiting-complete-source-preflight', 'prepared_at':datetime.datetime.now(datetime.UTC).isoformat(),
        'launcher_contract':2, 'planner_profile':args.profile, 'unit':args.unit, 'source':str(source), 'source_revision':head, 'code_revision':head,
        'local_image':args.image_repo + ':cross-compiler-amd64', 'output':str(compiler_output), 'command':command,
        'base_manifest':old['base_manifest'], 'base_config':old['base_config'], 'base_oci_index_sha256':old['base_oci_index_sha256'],
        'required_bytes':193273528320, 'expected_pins':old['expected_pins'], 'full_registry':len(registry),
        'full_source_preflight_proof':str(work / 'full-preflight-1/complete-preflight-proof.json'),
        'targeted_source_proof':str(args.targeted_proof.resolve()), 'source_commit_proof':str(args.commit_proof.resolve()),
        'production_sha256':{name:sha(source / name) for name in production},
        'storage_path_audit':'compiler-storage-path-audit.json', 'build_inputs_comparison':'build-inputs-comparison.json',
        'required_new_native_backends':['X86','AArch64','RISCV','AMDGPU'], 'required_cross_wrapper_targets':['amd64','arm64','riscv64'],
        'must_revalidate':[
            'Exact complete full-source proof, normal hook commit binding and clean source before launch.',
            'Both canonical180GiB and exact193273528320B reserve freshly pass; no floor override.',
            'Original12layer base/nativeOCI/index/config and all blobs rehash; all previous roots/images/receipts remain.',
            'No running producer; fresh unit/output/local alias and outside-Git TMPDIR; manager storage flags remain unset.',
            'Measure actual GNU/LLVM/Rust/Python cache behavior; input equality is not a cache hit and new LLVM backends intentionally rekey the LLVM RUN.',
            'Qualify baked native157tools/sixdefaults/loader plus source wrapper paths/three CPU backends plus AMDGPU and actual both-driver target smokes before nativeOCI and SDK handoff.'
        ], 'publication':False, 'scope':__doc__}
assert not (work / 'compiler-storage-path-audit.json').exists() and not (work / 'build-inputs-comparison.json').exists()
save(work / 'compiler-storage-path-audit.json', audit)
save(work / 'build-inputs-comparison.json', comparison)
save(args.output, plan)
print(json.dumps({'status':plan['status'], 'source_revision':head, 'full_registry':len(registry),
                  'GNU_bind_files_unchanged':len(gnu_mounts), 'unchanged_total_bind_files':len(unchanged), 'changed_bind_files':list(differences), 'launched':False}))
