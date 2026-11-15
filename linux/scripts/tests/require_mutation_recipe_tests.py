"""Recipe generation controls do not prove that real mutations bite or that every source gate is covered."""

from __future__ import annotations

import ast
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

PATH = Path(__file__).resolve().parents[3] / 'docs/scripts/generate_require_mutations.py'
SPEC = importlib.util.spec_from_file_location('require_recipe_generator', PATH)
assert SPEC is not None and SPEC.loader is not None
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


class RecipeTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='require-recipes-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.target = self.root / 'source.py'

    def test_only_named_require_expressions_are_selected_and_each_mutant_parses(self) -> None:
        source = 'require(True, "module outside scope")\ndef gate():\n    other()\n    require(\n        True, "one"\n    )\n    obj.require(True)\ndef second():\n    require(False, "two"); other()\n'
        self.target.write_text(source)
        rows = M.recipes(self.root, 'source.py', 'test-command', 'gate.bounded', 'why')
        self.assertEqual([row['id'] for row in rows], ['gate.bounded.gate-1', 'gate.bounded.second-1'])
        self.assertEqual([row['find'] for row in rows], ['require(\n        True, "one"\n    )', 'require(False, "two")'])
        for row in rows:
            self.assertEqual(row['target'], 'source.py')
            self.assertEqual(row['test'], 'test-command')
            self.assertEqual(row['why'], 'why')
            self.assertEqual(row['replace'], 'pass')
            ast.parse(source.replace(row['find'], row['replace'], 1))

    def test_empty_scope_and_syntax_errors_fail(self) -> None:
        self.target.write_text('require(True, "outside")\ndef gate():\n    obj.require(True)\n')
        with self.assertRaises(ValueError):
            M.recipes(self.root, 'source.py', 'test', 'gate', 'why')
        self.target.write_text('def broken(:\n')
        with self.assertRaises(SyntaxError):
            M.recipes(self.root, 'source.py', 'test', 'gate', 'why')

    def test_cli_preserves_existing_recipe_output(self) -> None:
        self.target.write_text('def gate():\n    require(True, "one")\n')
        output = self.root / 'recipes.json'
        argv = ['generator', '--root', str(self.root), '--target', 'source.py', '--test', 'test',
                '--prefix', 'gate', '--why', 'why', '--output', str(output)]
        with mock.patch.object(sys, 'argv', argv):
            M.main()
            expected = output.read_bytes()
            self.assertEqual(len(json.loads(expected)), 1)
            with self.assertRaises(FileExistsError):
                M.main()
            self.assertEqual(output.read_bytes(), expected)


if __name__ == '__main__':
    unittest.main()
