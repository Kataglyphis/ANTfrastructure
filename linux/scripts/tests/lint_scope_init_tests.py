"""Characterize sourced scope handoffs without running linter tools or downloads."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DRIVERS = ('lint-shell.sh', 'lint-python.sh', 'lint-dockerfiles.sh')


class ScopeInitializationTests(unittest.TestCase):
    def test_original_driver_receipts(self):
        expected = json.loads(Path(__file__).with_name('lint-scope-init-receipts.json').read_text())
        with tempfile.TemporaryDirectory(prefix='ant lint init ') as td:
            work = Path(td)
            hub = work / 'hub'
            core = hub / 'linux/scripts/01-core'
            core.mkdir(parents=True)
            for leaf in ('lint-root.sh', 'lint-scope-init.sh'):
                (core / leaf).write_bytes((ROOT / 'linux/scripts/01-core' / leaf).read_bytes())
            consumer = work / 'consumer'
            consumer.mkdir()
            subprocess.run(['git', 'init', '-q', str(consumer)], check=True)
            plain = work / 'plain'
            plain.mkdir()
            cases = [[], ['a b.py', '', '\n', '--warning'],
                     ['--root', str(consumer), 'a b.py', ''],
                     ['--root=' + str(consumer), '--', 'x'],
                     ['--root', str(work / 'absent'), 'x', '--root', str(consumer)],
                     ['--root'], ['--root', str(work / 'absent')], ['--root', str(plain)]]
            actual = {}
            for driver in DRIVERS:
                lines = (ROOT / 'linux/scripts' / driver).read_text().splitlines()
                entry = next(line for line in lines
                             if line.startswith('. "') and 'lint-scope-init.sh' in line)
                for options in ('u', 'eu'):
                    script = ('set -' + options + '\n'
                              'REPO_ROOT=$1; CORE_DIR=$1/linux/scripts/01-core; _core=$CORE_DIR; shift\n'
                              + entry + '\n'
                              'printf "%s\\0" "$SCAN_ROOT" "$LINT_ROOT_GIVEN" "$#"; '
                              'printf "%s\\0" "$@"\n')
                    for index, args in enumerate(cases):
                        result = subprocess.run(['bash', '-c', script, 'lint-scope', str(hub), *args],
                                                check=False, capture_output=True)
                        actual[f'{driver}:{options}:{index}'] = [
                            result.returncode,
                            result.stdout.replace(str(work).encode(), b'@WORK@').hex(),
                            result.stderr.replace(str(work).encode(), b'@WORK@').decode()]
            self.assertEqual(expected, actual)

    def test_missing_companions_cannot_reuse_stale_functions(self):
        initializer = ROOT / 'linux/scripts/01-core/lint-scope-init.sh'
        with tempfile.TemporaryDirectory() as td:
            for driver in DRIVERS:
                entry = next(line for line in (ROOT / 'linux/scripts' / driver).read_text().splitlines()
                             if line.startswith('. "') and 'lint-scope-init.sh' in line)
                for missing in ('initializer', 'scope-owner'):
                    with self.subTest(driver=driver, missing=missing):
                        core = Path(td) / 'linux/scripts/01-core'
                        core.mkdir(parents=True, exist_ok=True)
                        target = core / 'lint-scope-init.sh'
                        if target.exists():
                            target.unlink()
                        if missing == 'scope-owner':
                            target.write_bytes(initializer.read_bytes())
                        script = ('set -u\nREPO_ROOT=$1; CORE_DIR=$1/linux/scripts/01-core; _core=$CORE_DIR; shift\n'
                                  'lint_scope_begin() { SCAN_ROOT=stale; return 0; }\n'
                                  'LINT_ROOT_REST=(stale)\n' + entry + '\nprintf AFTER\n')
                        result = subprocess.run(['bash', '-c', script, 'lint-scope', td], check=False, capture_output=True)
                        self.assertEqual(1, result.returncode)
                        self.assertEqual(b'', result.stdout)
                        self.assertIn(b'No such file or directory', result.stderr)


if __name__ == '__main__':
    unittest.main()
