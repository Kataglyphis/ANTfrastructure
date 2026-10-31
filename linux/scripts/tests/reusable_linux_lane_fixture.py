from __future__ import annotations

import importlib
import pathlib
import sys
import textwrap
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from verify_workflow_conventions import YamlNode

sys.path.insert(0, sys.argv[1])
V = importlib.import_module("verify_workflow_conventions")
path = pathlib.Path(sys.argv[2])
lane = V.load_yaml(path)
lines = path.read_text(encoding='utf-8').splitlines()

def cut(at: int) -> list[str]:
    # The block scalar whose key sits on line `at`, cut by indentation.
    key_indent = len(lines[at]) - len(lines[at].lstrip())
    body = []
    for line in lines[at + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) <= key_indent:
            break
        body.append(line)
    return body

def write_step(step: YamlNode, output: str) -> None:
    body = '\n'.join(cut(V.line_of(step, 'run') - 1))
    pathlib.Path(output).write_text(textwrap.dedent(body).strip() + '\n', encoding='utf-8')


def steps(job: YamlNode) -> list[YamlNode]:
    result = V.value(job, 'steps')
    if not isinstance(result, list):
        raise TypeError('workflow job must have a steps list')
    return result


plan = next(s for s in steps(V.value(V.value(lane, 'jobs'), 'plan')) if V.value(s, 'id') == 'rows')
write_step(plan, sys.argv[3])

build = V.value(V.value(lane, 'jobs'), 'build')
pin_step = next(s for s in steps(build) if V.value(s, 'name') == 'Check pinned host GPU packaging contract')
write_step(pin_step, sys.argv[6])
format_step = next(s for s in steps(build) if V.value(s, 'name') == 'Check GPU candidate formats')
write_step(format_step, sys.argv[7])
with open(sys.argv[4], 'w', encoding='utf-8') as extra, open(sys.argv[5], 'w', encoding='utf-8') as conds:
    for step in steps(build):
        name = V.value(step, 'name')
        conds.write(f"{name}|{V.value(step, 'if') or '-'}\n")
        if name not in ('Run Python tests', 'Packaging application'):
            continue
        with_at = V.line_of(step, 'with') - 1
        with_indent = len(lines[with_at]) - len(lines[with_at].lstrip())
        j = with_at + 1
        while j < len(lines) and (not lines[j].strip() or len(lines[j]) - len(lines[j].lstrip()) > with_indent):
            if lines[j].strip().startswith('extra-args:'):
                break
            j += 1
        extra.write(f"{name}|{' '.join(x.strip() for x in cut(j))}\n")
