"""Raw pin and import contracts use local files and stubbed sed failures, not installer downloads or execution."""
import itertools
import json
import pathlib
import subprocess
import sys
import tempfile
from collections.abc import Mapping
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[3]
CONTEXT = ROOT / 'linux/scripts/tests/shell-context-fixture.sh'
sys.path.insert(0, str(ROOT / 'linux/scripts'))
from verify_dockerfile_context_paths import copy_sources
from verify_dockerfile_env_order import instructions

KEYS = {'android-sdk.sh': 'ANDROID_CMDLINE_TOOLS_SHA256', 'install-rust.sh': 'RUSTUP_INIT_SHA256'}


def scenarios() -> list[dict[str, Any]]:
    result = []
    initial = ('unset', 'declared-unset', 'empty', 'preset', 'exported-unset', 'exported-empty', 'exported-preset')
    main = ('missing', 'empty', 'single', 'duplicate', 'quoted', 'raw-syntax')
    edges = ('directory', 'no-key', 'whitespace', 'crlf', 'leading-empty', 'no-final-newline', 'symlink', 'broken-symlink')
    modes = tuple(itertools.product(('direct', 'conditional'), ('relaxed', 'strict')))
    for caller, state, data, mode in itertools.product(KEYS, initial, main, modes):
        result.append({'caller': caller, 'initial': state, 'data': data, 'context': mode[0], 'strict': mode[1], 'failure': 0})
    for caller, state, data, mode in itertools.product(KEYS, ('unset', 'empty', 'preset'), edges, modes):
        result.append({'caller': caller, 'initial': state, 'data': data, 'context': mode[0], 'strict': mode[1], 'failure': 0})
    for caller, state, failure, mode in itertools.product(KEYS, ('unset', 'empty', 'preset'), (2, 7, 127), modes):
        result.append({'caller': caller, 'initial': state, 'data': 'duplicate', 'context': mode[0], 'strict': mode[1], 'failure': failure})
    return result


def block(source: pathlib.Path, key: str) -> str:
    text = source.read_text()
    old = f'if [ -z "${{{key}:-}}" ] && [ -f /opt/scripts/core/versions.env ]; then'
    if old in text:
        start = text.index(old)
        ending = '\n  fi' if source.name == 'android-sdk.sh' else '\nfi'
        end = text.index(ending, start) + len(ending)
        return text[start:end].replace('/opt/scripts/core/versions.env', '"$PIN_FILE"')
    calls = [line.strip() for line in text.splitlines() if line.strip().startswith('load_raw_pin_if_empty ')]
    if len(calls) != 1:
        raise ValueError(f'{source}: missing unique raw pin call')
    return calls[0].replace('/opt/scripts/core/versions.env', '"$PIN_FILE"')


def contents(kind: str, key: str) -> bytes:
    values = {'empty': '', 'single': '@PIN@= value \nUNRELATED_PIN=from-file\n',
              'duplicate': '@PIN@=first\n@PIN@=second\nUNRELATED_PIN=from-file\n',
              'quoted': '@PIN@="literal quoted value"\nUNRELATED_PIN=from-file\n',
              'raw-syntax': '@PIN@=$(printf SHOULD_NOT_RUN)\nprintf "PIN_FILE_EXECUTED\\n"\nUNRELATED_PIN=from-file\n',
              'no-key': 'OTHER_@PIN@=ignore\n@PIN@_EXTRA=ignore\n', 'whitespace': '@PIN@= \t value \t \n',
              'crlf': '@PIN@=first\r\n@PIN@=second\r\n', 'leading-empty': '@PIN@=\n@PIN@=value\n@PIN@=\n',
              'no-final-newline': '@PIN@=last', 'symlink': '@PIN@=linked\n'}
    return values[kind].replace('@PIN@', key).encode()


def prepare(work: pathlib.Path, row: Mapping[str, Any], key: str, snippet: str) -> pathlib.Path:
    pin = work / 'versions [pin].env'
    kind = row['data']
    if kind == 'directory':
        pin.mkdir()
    elif kind in ('symlink', 'broken-symlink'):
        target = work / 'target'
        if kind == 'symlink':
            target.write_bytes(contents(kind, key))
        pin.symlink_to(target)
    elif kind != 'missing':
        pin.write_bytes(contents(kind, key))
    (work / 'block').write_text(snippet + '\n')
    (work / 'trace').write_text('')
    return pin


WORKER = r'''
set -u
source "$1"
source "$2"
WORK="$3" TARGET="$4" initial="$5" context="$6" strict="$7" failure="$8" PIN_FILE="$9"
unset "$TARGET" UNRELATED_PIN
case "$initial" in
  declared-unset) declare "$TARGET" ;;
  empty|exported-empty) printf -v "$TARGET" '%s' '' ;;
  preset|exported-preset) printf -v "$TARGET" '%s' $'operator value\nkept ' ;;
esac
case "$initial" in exported-*) export "$TARGET" ;; esac
sed() {
  printf '%s\0' "$@" >> "$WORK/trace"; printf '\0' >> "$WORK/trace"
  builtin command /usr/bin/sed "$@"
  if [ "$failure" != 0 ]; then printf 'SED_READ_FAILED:%s\n' "$failure" >&2; return "$failure"; fi
  return 0
}
finish() {
  local status=$?
  { declare -p "$TARGET" 2>/dev/null || printf 'TARGET_UNSET\n';
    declare -p UNRELATED_PIN 2>/dev/null || printf 'UNRELATED_UNSET\n'; } > "$WORK/state"
  exit "$status"
}
trap finish EXIT
operation() { source "$WORK/block"; }
PATH=/no-external-commands
if [ "$strict" = strict ]; then set -e; fi
shell_fixture_run_context "$context" status operation
printf 'RESULT:%s\n' "$status"
'''


def capture(row: Mapping[str, Any], snippets: Mapping[str, str], owner: pathlib.Path) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix='ant raw pin [] ') as directory:
        work = pathlib.Path(directory)
        key = KEYS[row['caller']]
        pin = prepare(work, row, key, snippets[row['caller']])
        command = ['/bin/bash', '-c', WORKER, '_', str(CONTEXT), str(owner), directory, key]
        command.extend(str(row[field]) for field in ('initial', 'context', 'strict', 'failure'))
        command.append(str(pin))
        process = subprocess.run(command, cwd=work, capture_output=True, text=True, timeout=5, check=False)
        return {'rc': process.returncode, 'out': process.stdout.replace(directory, '[WORK]'),
                'err': process.stderr.replace(directory, '[WORK]'), 'trace': (work / 'trace').read_text().replace(directory, '[WORK]'),
                'state': (work / 'state').read_text()}


def imports(toolchain: pathlib.Path) -> dict[str, str]:
    android = (toolchain / 'android-sdk.sh').read_text()
    required = next(line for line in android.splitlines() if line.startswith('source_toolchain_required ') and 'load-versions-env.sh' in line)
    initializer = next(line for line in android.splitlines() if line.startswith('source ') and '/bootstrap-import.sh' in line)
    rust = (toolchain / 'install-rust.sh').read_text()
    end = rust.index('# Also rerun on foreign-arch runtime images.')
    return {'android-sdk.sh': 'set -euo pipefail\n' + initializer + '\n' + required + '\n',
            'install-rust.sh': rust[:end]}


IMPORT_WORKER = r'''
set -u
source "$1"
WORK="$2" context="$3" mode="$4"
if [ "$mode" = guarded ]; then _LOAD_VERSIONS_ENV_SH_LOADED=1; fi
dirname() { builtin command /usr/bin/dirname "$@"; }
PATH=/no-external-commands
operation() { source "$WORK/toolchain/entry"; }
shell_fixture_run_context "$context" result operation
printf 'RESULT:%s\n' "$result"
'''


def import_case(work: pathlib.Path, snippet: str, bootstrap: str, owner: str, mode: str) -> None:
    (work / 'core').mkdir()
    if mode == 'old-bootstrap':
        bootstrap = 'source_toolchain_downloads() { :; }\n'
    (work / 'bootstrap.sh').write_text(bootstrap.replace('/opt/scripts/core', str(work / 'core')))
    initializer = ROOT / 'linux/scripts/02-toolchain/bootstrap-import.sh'
    (work / 'toolchain').mkdir()
    (work / 'toolchain/bootstrap-import.sh').write_text(initializer.read_text())
    (work / 'toolchain/bootstrap.sh').write_text(bootstrap.replace('/opt/scripts/core', str(work / 'core')))
    entry = snippet.replace('source /opt/scripts/core/load-versions-env.sh', 'source "$WORK/core/load-versions-env.sh"')
    (work / 'toolchain/entry').write_text(entry + "printf 'VALID_IMPORT\\n'\n")
    if mode != 'missing':
        body = '' if mode == 'empty' else owner
        if mode == 'stale-api':
            body = owner[:owner.index('load_raw_pin_if_empty() {')]
        if mode == 'failed-source':
            body += "\nprintf 'MODULE_RETURNED_FAILURE\\n' >&2; return 23\n"
        (work / 'core/load-versions-env.sh').write_text(body)


def import_contract(toolchain: pathlib.Path, owner: pathlib.Path) -> tuple[int, list[str]]:
    prefixes = imports(toolchain)
    bootstrap = (toolchain / 'bootstrap.sh').read_text()
    assertions = 0
    failures = []
    for caller, context, mode in itertools.product(KEYS, ('direct', 'conditional'),
                                                  ('healthy', 'missing', 'guarded', 'empty', 'stale-api', 'failed-source', 'old-bootstrap')):
        if mode == 'old-bootstrap' and caller != 'android-sdk.sh':
            continue
        with tempfile.TemporaryDirectory(prefix='ant raw pin import ') as directory:
            work = pathlib.Path(directory)
            import_case(work, prefixes[caller], bootstrap, owner.read_text(), mode)
            command = ['/bin/bash', '-c', IMPORT_WORKER, '_', str(CONTEXT), directory, context, mode]
            result = subprocess.run(command, cwd=work, capture_output=True, text=True, timeout=5, check=False)
        status = 0 if mode == 'healthy' else (23 if mode == 'failed-source' else 1)
        output = 'VALID_IMPORT\nRESULT:0\n' if mode == 'healthy' else ''
        diagnostic = {'missing': 'load-versions-env.sh', 'guarded': 'load_raw_pin_if_empty',
                      'empty': 'load_raw_pin_if_empty', 'stale-api': 'load_raw_pin_if_empty', 'failed-source': 'MODULE_RETURNED_FAILURE'}.get(mode)
        checks = (result.returncode == status, result.stdout == output,
                  result.stderr == '' if diagnostic is None else diagnostic in result.stderr)
        if mode == 'old-bootstrap':
            checks = (result.returncode == 1, result.stdout == '',
                      result.stderr == 'ERROR: bootstrap.sh does not provide source_toolchain_required\n')
        assertions += len(checks)
        if not all(checks):
            failures.append(f'import {caller}/{context}/{mode}: {result}')
    return assertions, failures


def image_contract() -> tuple[int, list[str]]:
    android = {}
    for _, line in instructions(ROOT / 'linux/Dockerfile.android'):
        sources = copy_sources(line)
        if not sources:
            continue
        destination = line.split()[-1]
        for source in sources:
            target = destination
            if len(sources) > 1 or destination.endswith('/'):
                target = destination.rstrip('/') + '/' + pathlib.PurePosixPath(source).name
            android[target] = (source, '--chmod=755' in line.split())
    owner = 'linux/scripts/01-core/load-versions-env.sh'
    mapping = android.get('/opt/scripts/core/load-versions-env.sh') == (owner, True)
    rust_runs = [line for _, line in instructions(ROOT / 'linux/Dockerfile.toolchain')
                 if line.startswith('RUN ') and 'bash /opt/scripts/toolchain/install-rust.sh' in line]
    mount = '--mount=type=bind,source=' + owner + ',target=/opt/scripts/core/load-versions-env.sh,ro'
    fresh = len(rust_runs) == 1 and mount in rust_runs[0].split()
    failures = []
    if not mapping:
        failures.append('Android image lacks the fresh canonical raw pin API COPY')
    if not fresh:
        failures.append('Rust RUN lacks the fresh read-only raw pin API bind')
    return 2, failures


def main() -> int:
    toolchain, owner = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    expected = json.loads(pathlib.Path(__file__).with_name('raw-pin-receipts.json').read_text())
    snippets = {leaf: block(toolchain / leaf, key) for leaf, key in KEYS.items()}
    failures = []
    assertions = 1
    if [row['case'] for row in expected] != scenarios():
        failures.append('frozen raw pin scenario inventory changed')
    for row in expected:
        actual = capture(row['case'], snippets, owner)
        for field in ('rc', 'out', 'err', 'trace', 'state'):
            assertions += 1
            if row['receipt'][field] != actual[field]:
                failures.append(f"{row['case']} {field}: expected {row['receipt'][field]!r}, got {actual[field]!r}")
    count, errors = import_contract(toolchain, owner)
    assertions += count
    failures.extend(errors)
    count, errors = image_contract()
    assertions += count
    failures.extend(errors)
    for error in failures[:10]:
        print(f'FAIL: {error}', file=sys.stderr)
    if failures:
        print(f'  {len(failures)}/{assertions} assertion(s) FAILED', file=sys.stderr)
        return 1
    print(f'  {assertions} assertion(s) passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
