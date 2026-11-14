#!/usr/bin/env python3
"""Break the original multi-target receipt guards and require assertion-bearing failures; SDK recipes and actual image acceptance remain separate."""

import argparse
import ast
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
assert not args.output.exists()
args.output.mkdir()
tools = Path(__file__).resolve().parent
probe = tools / 'probe-cross-clang-image.py'
test = tools / 'test-probe-cross-clang-image.py'
text = probe.read_text()
tree = ast.parse(text)
validate = next(node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name == 'validate')
messages = ['Native LLVM must carry exactly all three configured backends', 'Every actual architecture wrapper is required',
            'PATH selected another architecture wrapper', 'Wrapper does not bind the source driver and target contract',
            'The actual baked toolchain smoke must pass', 'Missing actual wrapper compiler assertion: ',
            'Missing target object ELF assertion', 'Actual foreign static execution is required',
            'Both real native languages are required', 'Native executable returned the wrong result: ',
            'Native executable has the wrong ELF machine', 'Preload cannot qualify the ordinary image']
lines = text.splitlines(keepends=True)
cases = []
for message in messages:
    matches = [node for node in ast.walk(validate) if isinstance(node,ast.Assert) and node.msg is not None
               and any(isinstance(part,ast.Constant) and part.value == message for part in ast.walk(node.msg))]
    assert len(matches) == 1, message
    node = matches[0]
    start, end = node.lineno - 1, node.end_lineno
    before = ''.join(lines[start:end])
    indent = len(lines[start]) - len(lines[start].lstrip())
    replacement = ' ' * indent + 'pass\n'
    mutant = ''.join(lines[:start]) + replacement + ''.join(lines[end:])
    ast.parse(mutant)
    cases.append((message,before,replacement,mutant))
needle = "        helpers['llvm_facts']({'version':row['version']}, llvm_pin)"
assert text.count(needle) == 1
cases.append(('exact wrapper version',needle,'        pass',text.replace(needle,'        pass',1)))
temporary_root = Path.home() / '.cache/webgpu-cross-image-probe-controls'
temporary_root.mkdir(exist_ok=True)
assert all(not (p / '.git').exists() for p in [temporary_root,*temporary_root.parents])
baseline = subprocess.run(['python3', str(test), '--source', str(args.source)], capture_output=True, text=True, timeout=30, check=False)
(args.output / 'baseline.stdout').write_text(baseline.stdout)
(args.output / 'baseline.stderr').write_text(baseline.stderr)
assert baseline.returncode == 0
records = []
with tempfile.TemporaryDirectory(prefix='cross-probe-',dir=temporary_root) as temporary:
    for index,(name,before,replacement,mutant) in enumerate(cases,1):
        path = Path(temporary) / 'probe.py'
        path.write_text(mutant)
        ast.parse(mutant)
        child = subprocess.run(['python3', str(test), '--source', str(args.source), '--probe', str(path)], capture_output=True, text=True, timeout=30, check=False)
        (args.output / f'{index:02d}.stdout').write_text(child.stdout)
        (args.output / f'{index:02d}.stderr').write_text(child.stderr)
        assert child.returncode != 0 and 'Expected guarded failure was accepted:' in child.stderr, (name,child.returncode,child.stderr)
        records.append({'case':name,'find':before,'replace':replacement,'parse_valid':True,'test_returncode':child.returncode,
                        'assertion_failed':True,'mutant_sha256':hashlib.sha256(mutant.encode()).hexdigest()})
        print(f'BITES {index}/{len(cases)} {name}')
receipt = {'status':'passed-real-receipt-guard-mutations-only','baseline_returncode':0,'actual_mutations':len(records),
           'probe_sha256':hashlib.sha256(text.encode()).hexdigest(),'test_sha256':hashlib.sha256(test.read_bytes()).hexdigest(),
           'cases':records,'image_acceptance_claimed':False,'scope':__doc__}
(args.output / 'proof.json').write_text(json.dumps(receipt,indent=2) + '\n')
print(json.dumps({'status':receipt['status'],'mutations':len(records)}))
