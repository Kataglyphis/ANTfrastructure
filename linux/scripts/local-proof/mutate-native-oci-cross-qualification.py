#!/usr/bin/env python3
"""Break the original multi-target compiler-parent guards with parse-valid mutations; this is not SDK-image or GPU acceptance."""

import argparse
import ast
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
assert not args.output.exists()
args.output.mkdir()
tools = Path(__file__).resolve().parent
module = tools / 'native-oci-handoff.py'
test = tools / 'test-native-oci-cross-qualification.py'
text = module.read_text()
tree = ast.parse(text)
function = next(node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name == 'qualification')
gate = next(node for node in ast.walk(function) if isinstance(node,ast.If) and "subject['cross_required']" in (ast.get_source_segment(text,node.test) or ''))
gate_text = ast.get_source_segment(text,gate.test)
assert gate_text is not None and 'cross_required' in gate_text
nodes = [gate, *[node for node in ast.walk(gate) if isinstance(node,ast.Assert)]]
lines = text.splitlines(keepends=True)
baseline = subprocess.run(['python3', str(test)], capture_output=True, text=True, timeout=30, check=False)
(args.output / 'baseline.stdout').write_text(baseline.stdout)
(args.output / 'baseline.stderr').write_text(baseline.stderr)
assert baseline.returncode == 0
cases = []
with tempfile.TemporaryDirectory(prefix='oci-cross-mutants-') as temporary:
    for index,node in enumerate(nodes,1):
        start,end = node.lineno-1,node.end_lineno
        indent = len(lines[start])-len(lines[start].lstrip())
        mutant = ''.join(lines[:start]) + ' '*indent + 'pass\n' + ''.join(lines[end:])
        ast.parse(mutant)
        path = Path(temporary) / 'mutant.py'
        path.write_text(mutant)
        child = subprocess.run(['python3', str(test), '--module', str(path)], capture_output=True, text=True, timeout=30, check=False)
        (args.output / f'{index:02d}.stdout').write_text(child.stdout)
        (args.output / f'{index:02d}.stderr').write_text(child.stderr)
        assert child.returncode != 0 and 'Synthetic incomplete SDK-parent proof was accepted:' in child.stderr, child.stderr
        cases.append({'line':node.lineno,'find':''.join(lines[start:end]),'replace':' '*indent+'pass\n',
                      'parse_valid':True,'test_returncode':child.returncode,'assertion_failed':True,
                      'mutant_sha256':hashlib.sha256(mutant.encode()).hexdigest()})
        print(f'BITES {index}/{len(nodes)} SDK-parent cross-proof assertion at line{node.lineno}')
receipt = {'status':'passed-SDK-parent-cross-proof-mutations-only','actual_mutations':len(cases),'baseline_returncode':0,
           'module_sha256':hashlib.sha256(text.encode()).hexdigest(),'test_sha256':hashlib.sha256(test.read_bytes()).hexdigest(),
           'cases':cases,'image_acceptance_claimed':False,'scope':__doc__}
(args.output / 'proof.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'status':receipt['status'],'mutations':len(cases)}))
