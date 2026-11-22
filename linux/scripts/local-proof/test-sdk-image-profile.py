#!/usr/bin/env python3
"""Exercise independent SDK receipt fixtures; no actual SDK, compiler bytes or hardware is accepted here."""

from __future__ import annotations

import argparse
import copy
import io
import json
import runpy
import tempfile
from collections.abc import Callable
from contextlib import redirect_stdout
from pathlib import Path
from typing import TYPE_CHECKING

from sdk_profile_fixture import producer_fixture

if TYPE_CHECKING:
    from proof_types import Edit, Json

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--probe', type=Path, default=Path(__file__).with_name('probe-cross-clang-image.py'))
args = parser.parse_args()
with redirect_stdout(io.StringIO()):
    fixture = runpy.run_path(str(Path(__file__).with_name('test-probe-cross-clang-image.py')))
payload = copy.deepcopy(fixture['payload'])
payload.update(profile='sdk-amd64', wrappers={name:payload['wrappers'][name] for name in ['clang-amd64','clang++-amd64']},
               smoke=fixture['child'](''.join(line + '\n' for line in payload['smoke']['stdout'].splitlines() if 'arm64' not in line and 'riscv64' not in line)),
               materialization={'alias_is_symlink':True, 'alias_target':'/opt/llvm-target', 'architecture_prefixes':['llvm-target-amd64'],
                                'drivers':{name:{'alias_sha256':'a' * 64, 'target_sha256':'a' * 64} for name in ['clang','clang++']}})


def validate(data: Json) -> Json:
    return fixture['probe']['validate'](data, '16.2.0', '23.1.5', fixture['helpers'], profile='sdk-amd64')


baseline = validate(payload)
assert baseline['status'] == 'passed-baked-SDK-Clang-wrappers-and-CPU-smokes-only'
assert baseline['wrapper_count'] == 2 and baseline['cross_targets'] == ['amd64']
assert baseline['foreign_static_executions_required'] == 0 and baseline['native_languages'] == ['c','cxx']
cases = []


def reject(name: str, edit: Edit, *, check: Callable[[Json], object] = validate, facts: Json = payload) -> None:
    candidate = copy.deepcopy(facts)
    edit(candidate)
    try:
        check(candidate)
    except (AssertionError, ValueError):
        cases.append(name)
    else:
        raise AssertionError('Invalid synthetic SDK image facts were accepted: ' + name)


reject('missing-profile', lambda p:p.pop('profile'))
reject('missing-materialization', lambda p:p.pop('materialization'))
reject('non-symlink-alias', lambda p:p['materialization'].update(alias_is_symlink=False))
reject('wrong-alias-target', lambda p:p['materialization'].update(alias_target='/wrong'))
reject('foreign-prefix', lambda p:p['materialization']['architecture_prefixes'].append('llvm-target-arm64'))
reject('missing-driver-bytes', lambda p:p['materialization']['drivers'].pop('clang++'))
reject('changed-alias-bytes', lambda p:p['materialization']['drivers']['clang'].update(target_sha256='b' * 64))
reject('invalid-driver-hash', lambda p:p['materialization']['drivers']['clang++'].update(alias_sha256='invalid',target_sha256='invalid'))
reject('foreign-wrapper', lambda p:p['wrappers'].update({'clang-arm64':fixture['payload']['wrappers']['clang-arm64']}))
reject('missing-native-wrapper', lambda p:p['wrappers'].pop('clang++-amd64'))
reject('old-native-sysroot', lambda p:p['wrappers']['clang-amd64'].update(script=p['wrappers']['clang-amd64']['script'].replace('--sysroot=/','--sysroot=/usr/x86_64-linux-gnu')))
reject('missing-native-link', lambda p:p['smoke'].update(stdout=p['smoke']['stdout'].replace('  PASS clang++ (amd64 wrapper): link smoke OK\n','')))
reject('missing-native-Cxx', lambda p:p['native_programs'].pop('cxx'))
reject('failed-native-Cxx', lambda p:p['native_programs']['cxx']['execution'].update(returncode=47))
reject('preload', lambda p:p['environment'].update(LD_PRELOAD='/fixture-only.so'))


def validate_unknown_profile(data: Json) -> Json:
    return fixture['probe']['validate'](data,'16.2.0','23.1.5',fixture['helpers'],profile='invented-fixture')


reject('unknown-profile',lambda p:p.update(profile='invented-fixture'),check=validate_unknown_profile,facts=fixture['payload'])
sdk_cases = len(cases)


subject_module = runpy.run_path(str(Path(__file__).with_name('proof_subject.py')))


def validate_producer(data: Json) -> Json:
    return subject_module['image_subject'](data['plan'],data['invocation'],data['parent'],data['full'])


producer = producer_fixture()
assert validate_producer(producer)['kind'] == 'sdk-amd64'
assert subject_module['image_subject'](producer['plan'])['cross_required'] is True
for name, field, key, value in [
        ('target','invocation','target_arch','ppc64le'), ('source','invocation','source','/wrong'),
        ('revision','invocation','source_revision','wrong'), ('parent-source','invocation','parent_source_revision','wrong'),
        ('unit','invocation','unit','fixture-wrong.service'), ('launch','invocation','launch_status',47),
        ('publication','invocation','publication',True), ('source-proof','invocation','source_full_preflight_passed',False),
        ('source-changed','invocation','producer_source_unchanged',False), ('parent-status','parent','status','pending'),
        ('parent-incomplete','parent','SDK_parent_prerequisites_passed',False), ('parent-blobs','parent','all_native_blob_sizes_and_sha256_verified',False),
        ('parent-source-revision','parent','source_revision','wrong'), ('base-layers','parent','matched_base_layers_and_diffIDs',11),
        ('parent-manifest','invocation','parent_manifest','wrong'), ('parent-config','invocation','parent_config','wrong'),
        ('parent-index','invocation','parent_OCI_index_sha256','wrong'), ('parent-layer-count','parent','layers',25),
        ('full-status','full','status','partial'), ('full-revision','full','source_revision','wrong'),
        ('full-mutations','full','actual_full_registry_mutations',6), ('full-raw','full','command_exit_status',47),
        ('full-cleanup','full','cleanup_exit_status',47), ('full-query','full','independent_engine_query_exit_status',47),
        ('full-absence','full','owned_container_absent',False), ('full-stop','full','unit_stopped_after_seal',False)]:
    reject('producer-' + name, lambda p, field=field, key=key, value=value:p[field].update({key:value}), check=validate_producer, facts=producer)
reject('producer-parent-not-stopped', lambda p:p['parent']['stopped'].update(ActiveState='active'), check=validate_producer, facts=producer)
reject('producer-parent-live-PID', lambda p:p['parent']['stopped'].update(MainPID='1'), check=validate_producer, facts=producer)
reject('producer-stage', lambda p:p['invocation']['command'].__setitem__(-7,'media'), check=validate_producer, facts=producer)
reject('producer-unexpanded-unit-args', lambda p:p['invocation']['command'].remove('--expand-environment=no'), check=validate_producer, facts=producer)
reject('producer-base-image', lambda p:p['invocation']['command'].__setitem__(3,'CROSS_SDK_BASE_IMAGE=wrong'), check=validate_producer, facts=producer)
reject('producer-base-context', lambda p:p['invocation']['command'].__setitem__(4,'CROSS_SDK_BASE_CONTEXT=/wrong'), check=validate_producer, facts=producer)
reject('producer-push', lambda p:p['invocation']['command'].insert(3,'--push'), check=validate_producer, facts=producer)
reject('producer-candidate',lambda p:(p['invocation'].update(image='ghcr.io/fixture/published:cross-sdk-amd64'),p['invocation']['command'].__setitem__(-3,'ghcr.io/fixture/published')),check=validate_producer,facts=producer)
reject('producer-unreviewed-coherent-target',lambda p:None,check=validate_producer,facts=producer_fixture('ppc64le'))
producer_cases = len(cases) - sdk_cases

oci = runpy.run_path(str(Path(__file__).with_name('native-oci-handoff.py')))
with tempfile.TemporaryDirectory(prefix='sdk-profile-fixture-') as temporary:
    root = Path(temporary)
    for name in ['parent','full','invocation']:
        (root / (name + '.json')).write_text(json.dumps(producer[name]))
    invocation: Json = {**producer['invocation'], 'parent_OCI_proof':str(root / 'parent.json'), 'SDK_source_full_preflight_proof':str(root / 'full.json')}
    invocation['command'][-1] = str(root / 'logs')
    (root / 'invocation.json').write_text(json.dumps(invocation))
    subject = subject_module['load_subject'](producer['plan'],root / 'invocation.json')
    mode = {**baseline,'mode':'default'}
    sdk_proof = {'status':subject['qualification_status'], 'subject':subject, 'source_revision':'synthetic-fixture', 'owned_container_absent':True,
                 'independent_engine_query_exit_status':0, 'cleanup':{'exit_status':0}, 'container_environment_matches_baked_image':True,
                 'baked_script_bytes_match_source':True, 'login_shell_selection_passed':True, 'native_facts':{'native_tool_count':157},
                 'sdk_native_checks_required':True, 'sdk_native_CPU_checks_passed':True, 'cross_wrapper_checks_required':False,
                 'sdk_native_modes':{'default':mode,'login':{**mode,'mode':'login'}}}

    def validate_handoff(data: Json) -> Json:
        path = root / 'qualification.json'
        path.write_text(json.dumps(data))
        return oci['qualification'](path,producer['plan'],root / 'invocation.json')

    assert validate_handoff(sdk_proof) == sdk_proof
    for name, edit in [
            ('proof-status', lambda p:p.update(status='passed-fresh-image-baked-compiler-native-tool-and-loader-selection-only')),
            ('subject', lambda p:p['subject'].update(sdk_invocation_sha256='wrong')),
            ('required', lambda p:p.update(sdk_native_checks_required=False)),
            ('CPU', lambda p:p.update(sdk_native_CPU_checks_passed=False)),
            ('compiler-scope', lambda p:p.update(cross_wrapper_checks_required=True)),
            ('login', lambda p:p['sdk_native_modes'].pop('login')),
            ('status', lambda p:p['sdk_native_modes']['default'].update(status='pending')),
            ('profile', lambda p:p['sdk_native_modes']['login'].update(profile='compiler')),
            ('mode', lambda p:p['sdk_native_modes']['login'].update(mode='default')),
            ('backends', lambda p:p['sdk_native_modes']['default'].update(native_backends=['X86'])),
            ('wrappers', lambda p:p['sdk_native_modes']['default'].update(wrapper_count=6)),
            ('targets', lambda p:p['sdk_native_modes']['default'].update(cross_targets=['amd64','arm64'])),
            ('languages', lambda p:p['sdk_native_modes']['login'].update(native_languages=['c'])),
            ('foreign-execution', lambda p:p['sdk_native_modes']['login'].update(foreign_static_executions_required=4))]:
        reject('handoff-' + name,edit,check=validate_handoff,facts=sdk_proof)
    bound_record = {'record':copy.deepcopy(sdk_proof), 'subject':subject}

    def validate_binding(data: Json) -> None:
        subject_module['validate_subject_binding'](data['record'],data['subject'],cpu_checks=True)

    reject('binding-subject',lambda p:p['record']['subject'].update(image='wrong'),check=validate_binding,facts=bound_record)
    reject('binding-SDK',lambda p:p['record'].update(sdk_native_checks_required=False),check=validate_binding,facts=bound_record)
    reject('binding-cross',lambda p:p['record'].update(cross_wrapper_checks_required=True),check=validate_binding,facts=bound_record)
handoff_cases = len(cases) - sdk_cases - producer_cases
parent_layout = ('fixture-parent', {'layers':[{'fixture_layer':number} for number in range(26)]},
                 {'rootfs':{'diff_ids':['fixture-diff-' + str(number) for number in range(26)]}})
child_layout = copy.deepcopy(parent_layout)
child_layout[1]['layers'].append({'fixture_layer':26})
child_layout[2]['rootfs']['diff_ids'].append('fixture-diff-26')
ancestry = {'child':child_layout, 'parent':parent_layout, 'count':26}


def validate_ancestry(data: Json) -> int:
    return oci['layer_ancestry'](data['child'], data['parent'], data['count'])


assert validate_ancestry(ancestry) == 26
base_layout = copy.deepcopy(parent_layout)
base_layout[1]['layers'] = base_layout[1]['layers'][:12]
base_layout[2]['rootfs']['diff_ids'] = base_layout[2]['rootfs']['diff_ids'][:12]
assert oci['base_ancestry'](child_layout,base_layout) == 12
reject('ancestry-count',lambda p:p.update(count=25),check=validate_ancestry,facts=ancestry)
reject('ancestry-layer',lambda p:p['child'][1]['layers'][25].update(fixture_layer=-1),check=validate_ancestry,facts=ancestry)
reject('ancestry-diffID',lambda p:p['child'][2]['rootfs']['diff_ids'].__setitem__(25,'wrong'),check=validate_ancestry,facts=ancestry)


def target_fixture(arch: str, machine: str) -> Json:
    foreign = copy.deepcopy(fixture['payload'])
    native_facts = copy.deepcopy(payload['materialization'])
    native_facts.update(host_prefix_is_real=True, architecture_prefixes=['llvm-target-amd64', 'llvm-target-' + arch])
    for driver in native_facts['drivers'].values():
        driver['elf'] = fixture['child']('  Machine: ' + machine + '\n')
    foreign.update(profile='sdk-' + arch, materialization=native_facts,
                   wrappers={name: row for name,row in foreign['wrappers'].items() if name.endswith('-' + arch)})
    return foreign


foreign_start = len(cases)
for arch, machine in (('arm64','AArch64'), ('riscv64','RISC-V')):
    foreign = target_fixture(arch, machine)
    profile = 'sdk-' + arch
    def validate_target(data: Json, selected: str = profile) -> Json:
        return fixture['probe']['validate'](data, '16.2.0', '23.1.5', fixture['helpers'], profile=selected)
    foreign_result = validate_target(foreign)
    assert foreign_result['cross_targets'] == [arch] and foreign_result['foreign_static_executions_required'] == 2
    assert foreign_result['wrapper_count'] == 2
    reject(arch+'-wrong-ELF',lambda p:p['materialization']['drivers']['clang'].update(elf=fixture['child']('  Machine: Advanced Micro Devices X86-64\n')),check=validate_target,facts=foreign)
    reject(arch+'-host-alias',lambda p:p['materialization'].update(host_prefix_is_real=False),check=validate_target,facts=foreign)
    reject(arch+'-no-static',lambda p:p['smoke'].update(stdout='\n'.join(line for line in p['smoke']['stdout'].splitlines() if 'static binary RUNS' not in line)),check=validate_target,facts=foreign)
    subject = validate_producer(producer_fixture(arch))
    assert subject['kind'] == profile and subject['native_prefix'] == '/opt/llvm-target-amd64'
    image = {'Architecture':'amd64','Os':'linux','Config':{'Env':[f'TARGET_ARCH={arch}',f'TARGETARCH={arch}','BUILD_MODE=cross','BUILDPLATFORM=linux/amd64']}}
    def check_image(data: Json, sdk: Json = subject) -> None:
        subject_module['validate_foreign_sdk_image'](data, sdk)
    check_image(image)
    reject(arch+'-invalid-build-architecture',lambda p, wrong=arch:p.update(Architecture=wrong),check=check_image,facts=image)
    reject(arch+'-mismatched-image-target',lambda p:p['Config']['Env'].__setitem__(0,'TARGET_ARCH=amd64'),check=check_image,facts=image)
    reject(arch+'-duplicate-image-target',lambda p:p['Config']['Env'].append('TARGETARCH=amd64'),check=check_image,facts=image)
    foreign_proof = {**sdk_proof,'subject':subject,'sdk_native_modes':{mode:{**foreign_result,'mode':mode} for mode in ('default','login')}}

    def check_receipt(data: Json, sdk: Json = subject) -> None:
        oci['sdk_cpu_qualification'](data, sdk)

    check_receipt(foreign_proof)
    reject(arch+'-missing-target-executions',lambda p:p['sdk_native_modes']['login'].update(foreign_static_executions_required=0),check=check_receipt,facts=foreign_proof)

print(json.dumps({'status':'passed-independent-SDK-image-profile-fixtures-only', 'positive_controls':6,
                  'refusal_controls':len(cases), 'SDK_image_refusals':sdk_cases, 'producer_refusals':producer_cases,
                  'handoff_refusals':handoff_cases, 'foreign_refusals':len(cases)-foreign_start,
                  'cases':cases, 'actual_image_acceptance':False}))
