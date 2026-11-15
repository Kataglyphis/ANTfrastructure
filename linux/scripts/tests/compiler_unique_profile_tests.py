"""Real files and explicit Git/proof doubles grade GNU_UNIQUE planning, not authenticated receipts or actual builds."""

import ast
import copy
import hashlib
import importlib
import json
import unittest
from typing import Any
from unittest import mock

from compiler_plan_profile_tests import TOOLS, CompilerPlanFixture

UNIQUE = importlib.import_module('compiler_unique_profile')
FILES = (
    'linux/scripts/01-core/runtime-build-fns.sh', 'linux/scripts/02-toolchain/build-clang.sh',
    'linux/scripts/02-toolchain/llvm-validate.sh', 'linux/scripts/02-toolchain/llvm-cross.sh',
    'linux/scripts/02-toolchain/llvm.sh', 'linux/scripts/02-toolchain/materialize-llvm-target.sh',
    'linux/scripts/02-toolchain/llvm-gnu-unique.sh',
)
CHANGES = {
    'AGENTS.md', 'BACKLOG.md', 'CHANGELOG.md', 'README.md', 'docs/code-quality-tooling.md',
    'docs/failure-modes.md', 'docs/local-proof-workflows.md', 'docs/scripts/mutations.json',
    'linux/scripts/tests/gpu_source_profile_tests.py',
}


class CompilerUniqueProfileTests(CompilerPlanFixture):
    def setUp(self) -> None:
        super().setUp()
        self.head = UNIQUE.SOURCE_REVISION
        self.paths = CHANGES.copy()
        self.previous_head = UNIQUE.REFERENCE_REVISION
        self.previous_status = b''
        self.template.update(source_revision=UNIQUE.REFERENCE_REVISION, build_inputs_comparison='comparison.json')
        self.audit['files_sha256']['linux/scripts/01-core/context-management.sh'] = self.fingerprint('linux/scripts/01-core/context-management.sh')['sha256']
        for name in FILES:
            self.write(name, ('reviewed compiler fixture ' + name).encode())
        self.prior_dockerfile = ('FROM fixture\n'
            'RUN --mount=type=bind,source=linux/scripts/01-core/chain-storage.sh,target=/core true\n\n'
            'RUN --mount=type=cache,target=/llvm \\\n'
            '    --mount=type=bind,source=linux/scripts/02-toolchain/llvm-validate.sh,target=/opt/scripts/toolchain/llvm-validate.sh,ro \\\n'
            '    bash /opt/setup-dependencies.sh dockerfile-llvm\n\n')
        (self.previous / 'linux/Dockerfile.toolchain').write_text(self.prior_dockerfile)
        anchor = '    --mount=type=bind,source=linux/scripts/02-toolchain/llvm-validate.sh,target=/opt/scripts/toolchain/llvm-validate.sh,ro \\\n'
        mount = '    --mount=type=bind,source=linux/scripts/02-toolchain/llvm-gnu-unique.sh,target=/opt/scripts/toolchain/llvm-gnu-unique.sh,ro \\\n'
        self.write('linux/Dockerfile.toolchain', self.prior_dockerfile.replace(anchor,anchor + mount).encode())
        self.reviewed_bytes = {name:(self.source / name).read_bytes() for name in (*FILES, 'linux/Dockerfile.toolchain')}
        self.old_inputs = {}
        for name in (*self.audit['files_sha256'], *FILES[:-1]):
            path = self.previous / name
            path.parent.mkdir(parents=True,exist_ok=True)
            raw = (self.source / name).read_bytes() if name not in FILES else ('prior compiler fixture ' + name).encode()
            path.write_bytes(raw)
            self.old_inputs[name] = {'sha256':hashlib.sha256(raw).hexdigest(),'size':len(raw)}
        self.reference_report = {'source_revision':UNIQUE.REFERENCE_REVISION,
            'unchanged_bound_files':copy.deepcopy(self.old_inputs), 'changed_bound_files':{}}
        self.targeted['status'] = 'passed-targeted-source-operational-tool-preservation-only'
        self.commit.update(head=self.head,actual_hook_mutations=2)
        self.write('docs/scripts/mutations.json', json.dumps([
            {'id':'fixture.first','target':'docs/failure-modes.md'},
            {'id':'fixture.second','target':'linux/scripts/tests/gpu_source_profile_tests.py'},
        ]).encode())

    def git_and_manager(self, command: list[str], **kwargs: object) -> str | bytes:
        source = command[2] if command[:2] == ['git','-C'] else None
        arguments = command[3:]
        if source == str(self.previous):
            if arguments == ['rev-parse','HEAD']:
                value = (self.previous_head + '\n').encode()
            elif arguments == ['status','--porcelain']:
                value = self.previous_status
            else:
                raise AssertionError(command)
        elif source == str(self.source) and arguments[:2] == ['diff','--name-only']:
            value = '\n'.join(sorted(self.paths)).encode()
        elif source == str(self.source) and arguments[:1] == ['show'] and arguments[1].startswith(UNIQUE.REPAIR_REVISION + ':'):
            value = self.reviewed_bytes[arguments[1].split(':',1)[1]]
        else:
            return super().git_and_manager(command,**kwargs)
        return value.decode() if kwargs.get('text') else value

    def plan(self, profile: str | None = 'llvm-gnu-unique') -> tuple[dict[str, Any], Any]:
        (self.inputs / 'comparison.json').write_text(json.dumps(self.reference_report))
        return super().plan(profile)

    def invoke(self, name: str, *arguments: Any) -> Any:
        with mock.patch('subprocess.check_output',side_effect=self.git_and_manager):
            return getattr(UNIQUE,name)(*arguments)

    def test_profile_prepares_all_seven_deltas_and_retains_original_reference(self) -> None:
        original = copy.deepcopy(self.reference_report)
        plan, output = self.plan()
        comparison = json.loads((output / 'build-inputs-comparison.json').read_text())
        self.assertEqual(plan['planner_profile'],'llvm-gnu-unique')
        self.assertEqual(comparison['status'],'reviewed-GNU-closure-equal-exact-GNU-UNIQUE-lineage-only')
        self.assertNotIn('identical_Dockerfile_sha256',comparison)
        self.assertEqual(set(plan['production_sha256']),set(FILES) | {'linux/scripts/06-packaging/smoke-toolchain.sh'})
        self.assertEqual(set(comparison['changed_bound_files']),set(FILES))
        self.assertIsNone(comparison['changed_bound_files'][FILES[-1]]['previous'])
        self.assertTrue(comparison['GNU_mounts_unchanged'])
        self.assertFalse(comparison['cache_hits_claimed'])
        self.assertEqual(self.reference_report,original)
        self.assertEqual(plan['source_revision'],UNIQUE.SOURCE_REVISION)
        self.assertEqual(plan['required_bytes'],193273528320)

    def test_source_requires_exact_revision_changes_and_all_reviewed_compiler_bytes(self) -> None:
        with self.assertRaises(AssertionError):
            self.invoke('require_source',self.source,'c' * 40)
        for paths in (CHANGES | {'unreviewed.sh'}, CHANGES - {'AGENTS.md'}):
            self.paths = paths
            with self.assertRaises(AssertionError):
                self.invoke('require_source',self.source,self.head)
        self.paths = CHANGES.copy()
        for name in (*FILES,'linux/Dockerfile.toolchain'):
            path = self.source / name
            raw = path.read_bytes()
            path.write_bytes(raw + b'drift')
            with self.subTest(name=name),self.assertRaises(AssertionError):
                self.invoke('require_source',self.source,self.head)
            path.write_bytes(raw)

    def test_reference_requires_original_source_report_and_file_fingerprints(self) -> None:
        template = self.inputs / 'template.json'
        self.plan()
        for key, value in [('source_revision','c' * 40)]:
            changed = {**self.template,key:value}
            with self.assertRaises(AssertionError):
                self.invoke('reference_inputs',template,changed)
        self.previous_head = 'c' * 40
        with self.assertRaises(AssertionError):
            self.invoke('reference_inputs',template,self.template)
        self.previous_head = UNIQUE.REFERENCE_REVISION
        self.previous_status = b' M input\n'
        with self.assertRaises(AssertionError):
            self.invoke('reference_inputs',template,self.template)
        self.previous_status = b''
        path = self.previous / FILES[0]
        path.write_bytes(path.read_bytes() + b'drift')
        with self.assertRaises(AssertionError):
            self.invoke('reference_inputs',template,self.template)

    def test_delta_scope_distinguishes_new_and_existing_files(self) -> None:
        original = {name:{'previous':None if name == FILES[-1] else {},'current':{}} for name in FILES}
        for modify in [lambda d:d.pop(FILES[0]), lambda d:d.update(extra={}),
                       lambda d:d[FILES[-1]].update(previous={}),lambda d:d[FILES[0]].update(previous=None)]:
            value = copy.deepcopy(original)
            modify(value)
            with self.assertRaises(AssertionError):
                UNIQUE.validate_changes(value)

    def test_current_targeted_scope_and_all_matching_normal_hooks_remain_required(self) -> None:
        for count in (0,1,16):
            self.commit['actual_hook_mutations'] = count
            with self.subTest(count=count),self.assertRaises(AssertionError):
                self.plan()
        self.commit['actual_hook_mutations'] = 2
        self.targeted['status'] = 'passed-targeted-source-native-Clang-wrapper-and-backend-repair-only'
        with self.assertRaises(AssertionError):
            self.plan()

    def test_only_one_precise_companion_mount_is_permitted(self) -> None:
        self.write('linux/Dockerfile.toolchain', (self.reviewed_bytes['linux/Dockerfile.toolchain'] + b'RUN unreviewed\n'))
        with self.assertRaises(AssertionError):
            self.plan()
        previous = self.previous / 'linux/Dockerfile.toolchain'
        previous.write_text('FROM fixture\nRUN true\n')
        with self.assertRaises(AssertionError):
            UNIQUE.expected_dockerfile(self.previous)


    def test_reference_report_groups_and_new_companion_cannot_be_rewritten(self) -> None:
        original = copy.deepcopy(self.reference_report)
        cases = [
            {**original,'source_revision':'c' * 40},
            {**original,'unchanged_bound_files':{}},
            {**original,'changed_bound_files':{FILES[0]:{'current':self.old_inputs[FILES[0]]}}},
            {**original,'unchanged_bound_files':{**original['unchanged_bound_files'],FILES[-1]:{}}},
        ]
        self.plan()
        template = self.inputs / 'template.json'
        for report in cases:
            (self.inputs / 'comparison.json').write_text(json.dumps(report))
            with self.subTest(report=report),self.assertRaises(AssertionError):
                self.invoke('reference_inputs',template,self.template)
        (self.inputs / 'comparison.json').write_text(json.dumps(original))
        path = self.previous / FILES[-1]
        path.write_bytes(b'unexpected companion')
        with self.assertRaises(AssertionError):
            self.invoke('reference_inputs',template,self.template)

    def test_patch_binding_rejects_every_failed_or_mismatched_receipt_fact(self) -> None:
        cases = [
            ('targeted','owner_source','wrong'),('targeted','quality_group_count',25),
            ('targeted','cleanup_exit_status',47),('targeted','independent_engine_query_exit_status',47),
            ('targeted','owned_container_absent',False),('targeted','patch_sha256','5' * 64),
            ('commit','head','c' * 40),('commit','source','wrong'),('commit','status','failed'),
            ('commit','normal_hook_status',47),('commit','clean',False),('commit','exact_committed_patch_match',False),
        ]
        for record, key, changed in cases:
            data = getattr(self,record)
            original = data[key]
            data[key] = changed
            with self.subTest(record=record,key=key),self.assertRaises(AssertionError):
                self.plan()
            data[key] = original

    def test_normal_hook_count_retains_empty_refusal_and_standard_sixteen_cap(self) -> None:
        path = self.source / 'docs/scripts/mutations.json'
        self.assertEqual(self.invoke('hook_count',self.source),2)
        path.write_text('[]')
        with self.assertRaises(AssertionError):
            self.invoke('hook_count',self.source)
        path.write_text(json.dumps([{'id':str(i),'target':'docs/failure-modes.md'} for i in range(17)]))
        self.assertEqual(self.invoke('hook_count',self.source),16)

    def test_reference_paths_cannot_escape_the_frozen_source(self) -> None:
        outside = self.root / 'outside'
        outside.write_bytes(b'actual foreign input')
        for name in ('../outside',str(outside)):
            with self.subTest(name=name),self.assertRaises(AssertionError):
                UNIQUE.fingerprint(self.previous,name)


    def test_shared_helpers_refuse_an_unknown_profile_before_any_legacy_fallback(self) -> None:
        self.plan()
        plans = importlib.import_module('compiler_plan_profile')
        template = self.inputs / 'template.json'
        targeted = {**self.targeted,'status':'passed-targeted-source-native-Clang-wrapper-and-backend-repair-only'}
        commit = {**self.commit,'actual_hook_mutations':16}
        self.accepted_materializer = self.reviewed_bytes['linux/scripts/02-toolchain/materialize-llvm-target.sh']
        (self.previous / 'linux/Dockerfile.toolchain').write_bytes((self.source / 'linux/Dockerfile.toolchain').read_bytes())
        calls = [
            ('input_reference',(self.source,self.head,template,self.template,'unknown')),
            ('reviewed_dockerfile',(self.source,self.previous,'unknown')),
            ('validate_patch_binding',(self.source,self.head,'unknown',targeted,commit)),
        ]
        with mock.patch('subprocess.check_output',side_effect=self.git_and_manager):
            for name, arguments in calls:
                with self.subTest(name=name),self.assertRaises(AssertionError):
                    getattr(plans,name)(*arguments)


    def test_pins_match_the_independently_reviewed_source_lineage(self) -> None:
        self.assertEqual(UNIQUE.SOURCE_REVISION,'a4741df72654abd91008f75ced01f57e7b4a1461')
        self.assertEqual(UNIQUE.REFERENCE_REVISION,'652e5440c9cbbecee486ff86dab873b9ace967ec')
        self.assertEqual(UNIQUE.REPAIR_REVISION,'60ce0c91e8831fbf1e2886b887a75dafbf4c2910')

    def test_both_entrypoints_unconditionally_call_the_shared_patch_validator(self) -> None:
        for name in ('prepare-next-compiler-plan.py','launch-normal-compiler-plan.py'):
            tree = ast.parse((TOOLS / name).read_text())
            calls = [node.value for node in tree.body if isinstance(node,ast.Expr)
                     and isinstance(node.value,ast.Call) and isinstance(node.value.func,ast.Name)
                     and node.value.func.id == 'validate_patch_binding']
            self.assertEqual(len(calls),1,name)

    def test_source_pin_review_is_wired_into_both_shared_entrypoint_helpers(self) -> None:
        self.plan()
        plans = importlib.import_module('compiler_plan_profile')
        bad = 'c' * 40
        commit = {**self.commit,'head':bad}
        calls = [
            ('input_reference',(self.source,bad,self.inputs / 'template.json',self.template,'llvm-gnu-unique')),
            ('validate_patch_binding',(self.source,bad,'llvm-gnu-unique',self.targeted,commit)),
        ]
        with mock.patch('subprocess.check_output',side_effect=self.git_and_manager):
            for name, arguments in calls:
                with self.subTest(name=name),self.assertRaises(AssertionError):
                    getattr(plans,name)(*arguments)


if __name__ == '__main__':
    unittest.main()
