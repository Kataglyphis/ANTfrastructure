#!/usr/bin/env python3
"""Compare the GPU-only follow-up with its frozen compiler parent and selected bundle; no cache hit or compiled image acceptance is implied."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
for name in ['source','parent','reference-inputs','output']:
    parser.add_argument('--'+name,type=Path,required=True)
args = parser.parse_args()
assert not args.output.exists()
source,parent = args.source.resolve(),args.parent.resolve()

def run(command: list[str]) -> str:
    return subprocess.check_output(command,text=True,timeout=60)

def sha(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()

heads = {}
for name,root in [('source',source),('parent',parent)]:
    heads[name] = run(['git','-C',str(root),'rev-parse','HEAD']).strip()
    assert not run(['git','-C',str(root),'status','--porcelain']).strip()
assert run(['git','-C',str(source),'rev-parse','HEAD^']).strip() == heads['parent']
changed = run(['git','-C',str(source),'diff','--name-only',heads['parent'],heads['source']]).splitlines()
production = [name for name in changed if name.startswith('linux/') and not name.startswith('linux/scripts/tests/')]
assert production == ['linux/Dockerfile.amd']
reference = json.loads(args.reference_inputs.read_text())
assert reference['source_revision'] == heads['parent']
names = sorted(set(reference['unchanged_bound_files']) | set(reference['changed_bound_files']))
assert len(names) == 150
assert all((source / name).read_bytes() == (parent / name).read_bytes() for name in names)
for name in ['linux/Dockerfile.toolchain','linux/Dockerfile.sdk']:
    assert (source / name).read_bytes() == (parent / name).read_bytes()
old = (parent / 'linux/Dockerfile.amd').read_text()
new = (source / 'linux/Dockerfile.amd').read_text()
needle = 'ENV PATH="/opt/rocm/migraphx/bin:/usr/lib/llvm-${LLVM_RELEASE%%.*}/bin:/opt/rocm/bin:${PATH}"'
replacement = 'ENV PATH="/opt/rocm/migraphx/bin:${PATH}:/opt/rocm/bin"'
assert old.count(needle) == 1 and old.replace(needle,replacement,1) == new
temporary_root = Path.home() / '.cache/webgpu-amd-parent-identity'
temporary_root.mkdir(exist_ok=True)
assert all(not (p / '.git').exists() for p in [temporary_root,*temporary_root.parents])
commands = []
with tempfile.TemporaryDirectory(prefix='selected-bundles-',dir=temporary_root) as temporary:
    bundles = {}
    for name,root in [('parent',parent),('gpu',source)]:
        destination = Path(temporary) / name
        command = ['python3','-B',str(root / 'linux/scripts/stage-script-closure.py'),'migraphx-image','--output',str(destination)]
        result = subprocess.run(command,env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1'),capture_output=True,text=True,timeout=30,check=True)
        commands.append({'command':command,'returncode':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
        bundles[name] = destination
    records = {}
    for name,root in bundles.items():
        records[name] = {path.relative_to(root).as_posix():{'sha256':sha(path),'mode':format(path.stat().st_mode & 0o777,'o')}
                         for path in root.rglob('*') if path.is_file()}
        receipt = root / 'SCRIPT-CLOSURE.json'
        (args.output.parent / (name+'-script-closure.json')).write_bytes(receipt.read_bytes())
    assert records['parent'] == records['gpu'] and len(records['parent']) == 77
proof = {'status':'passed-compiler-input-and-selected-AMD-bundle-identity-only','compiler_source_revision':heads['parent'],
         'GPU_source_revision':heads['source'],'production_delta':production,'single_late_ENV_change':True,
         'compiler_bind_inputs_compared':150,'compiler_and_SDK_Dockerfiles_equal':True,'selected_AMD_files':76,
         'selected_bundle_and_receipt_bytes_modes_equal':True,'selected_bundle':records['parent'],'staging_commands':commands,
         'compiler_bind_sha256':{name:sha(source / name) for name in names},'cache_hit_claimed':False,
         'actual_GPU_image_acceptance_claimed':False,'scope':__doc__}
args.output.write_text(json.dumps(proof,indent=2)+'\n')
print(json.dumps({key:proof[key] for key in ['status','compiler_bind_inputs_compared','selected_AMD_files','single_late_ENV_change','cache_hit_claimed']}))
