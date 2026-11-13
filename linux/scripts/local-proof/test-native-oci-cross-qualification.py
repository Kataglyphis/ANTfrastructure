#!/usr/bin/env python3
"""Check the new SDK-parent receipt boundary using declared synthetic fixtures; this does not authenticate or accept an actual image."""

import argparse
import copy
import json
import runpy
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--module',type=Path,default=Path(__file__).with_name('native-oci-handoff.py'))
args = parser.parse_args()
module = runpy.run_path(str(args.module))
mode = {'status':'passed-baked-cross-Clang-wrappers-and-CPU-smokes-only', 'mode':'default',
        'native_backends':['AArch64','RISCV','X86'], 'wrapper_count':6, 'foreign_static_executions_required':4, 'native_languages':['c','cxx']}
login = dict(mode,mode='login')
proof = {'status':'passed-fresh-image-baked-compiler-native-tool-and-loader-selection-only', 'source_revision':'synthetic-fixture',
         'owned_container_absent':True, 'independent_engine_query_exit_status':0, 'cleanup':{'exit_status':0},
         'container_environment_matches_baked_image':True, 'baked_script_bytes_match_source':True, 'login_shell_selection_passed':True,
         'native_facts':{'native_tool_count':157}, 'cross_wrapper_checks_required':True, 'cross_wrapper_CPU_checks_passed':True,
         'cross_wrapper_modes':{'default':mode,'login':login}}
plan = {'source_revision':'synthetic-fixture','launcher_contract':2}
controls = []
with tempfile.TemporaryDirectory(prefix='cross-oci-fixture-') as temporary:
    path = Path(temporary) / 'fixture.json'
    path.write_text(json.dumps(proof))
    assert module['qualification'](path,plan) == proof
    for name, edit in [
        ('missing-wrapper-proof', lambda p:p.pop('cross_wrapper_checks_required')),
        ('failed-wrapper-proof', lambda p:p.update(cross_wrapper_CPU_checks_passed=False)),
        ('missing-login-mode', lambda p:p['cross_wrapper_modes'].pop('login')),
        ('wrong-status', lambda p:p['cross_wrapper_modes']['default'].update(status='pending')),
        ('wrong-mode', lambda p:p['cross_wrapper_modes']['login'].update(mode='default')),
        ('wrong-backends', lambda p:p['cross_wrapper_modes']['default'].update(native_backends=['X86'])),
        ('missing-wrapper', lambda p:p['cross_wrapper_modes']['login'].update(wrapper_count=5)),
        ('missing-foreign-execution', lambda p:p['cross_wrapper_modes']['default'].update(foreign_static_executions_required=0)),
        ('missing-native-Cxx', lambda p:p['cross_wrapper_modes']['login'].update(native_languages=['c']))]:
        fixture = copy.deepcopy(proof)
        edit(fixture)
        path.write_text(json.dumps(fixture))
        try:
            module['qualification'](path,plan)
        except (AssertionError,KeyError):
            controls.append(name)
        else:
            raise AssertionError('Synthetic incomplete SDK-parent proof was accepted: ' + name)
print(json.dumps({'status':'passed-synthetic-SDK-parent-cross-boundary-controls-only','positive_controls':1,'refusal_controls':len(controls),'cases':controls}))
