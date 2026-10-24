"""Actual downloader initialization and COPY closures are offline; installer and network execution are excluded."""
import itertools
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
CONTEXT = ROOT / 'linux/scripts/tests/shell-context-fixture.sh'
sys.path.insert(0, str(ROOT / 'linux/scripts'))
from verify_dockerfile_context_paths import copy_sources
from verify_dockerfile_env_order import instructions


def scenarios():
    available = ('both', 'repo', 'installed', 'none', 'before-error', 'after-error', 'readonly', 'already-loaded')
    keys = ('caller', 'layout', 'available', 'preloaded', 'context', 'outer')
    values = itertools.product(('android-sdk.sh', 'vulkan.sh'), ('tree', 'flat'), available, (False, True),
                               ('direct', 'conditional'), ('relaxed', 'strict'))
    return [dict(zip(keys, row, strict=True)) for row in values]


def loader(text):
    old = 'if ! command -v download_file >/dev/null 2>&1; then'
    if old in text:
        start = text.index(old)
        return text[start:text.index('\nfi', start) + 3]
    start = text.index('# shellcheck source=bootstrap')
    last = 'source_toolchain_downloads "${BASH_SOURCE[0]}"'
    end = text.index(last, start) + len(last)
    return text[start:end]


def source_module(actual, label, available):
    trace = f'printf "source:{label}\\n" >> "$WORK/trace"\n'
    if label == 'repo' and available == 'before-error':
        return trace + 'return 7\n' + actual
    return trace + actual + ('\nreturn 7\n' if label == 'repo' and available == 'after-error' else '')


def prepare(work, row, blocks, bootstrap, actual):
    directory = work / 'scripts' / ('02-toolchain' if row['layout'] == 'tree' else '')
    directory.mkdir(parents=True)
    repository = directory.parent / '01-core'
    installed = work / 'installed'
    installed.mkdir()
    repository.mkdir(exist_ok=True)
    (work / 'trace').write_text('')
    caller = directory / row['caller']
    caller.write_text('set -euo pipefail\n' + blocks[row['caller']].replace('/opt/scripts/core', str(installed)) + '\n')
    companion = directory / 'bootstrap.sh'
    initializer = ROOT / 'linux/scripts/02-toolchain/bootstrap-import.sh'
    (directory / 'bootstrap-import.sh').write_text(initializer.read_text())
    if row.get('bootstrap') != 'missing':
        body = bootstrap.replace('/opt/scripts/core', str(installed))
        if row.get('bootstrap') == 'return-error':
            body += '\nreturn 7\n'
        companion.write_text(body)
    (directory / 'downloads.sh').write_text('printf "adjacent poison\\n" >&2; exit 99\n')
    if row['available'] not in ('installed', 'none'):
        (repository / 'downloads.sh').write_text(source_module(actual, 'repo', row['available']))
    if row['available'] not in ('repo', 'none'):
        (installed / 'downloads.sh').write_text(source_module(actual, 'installed', row['available']))
    return caller


WORKER = r'''
set -u
source "$1"
WORK="$2" caller="$3" available="$4" preloaded="$5" context="$6" outer="$7"
SCRIPT_DIR=/poison SCRIPTS_ROOT=/poison
if [ "$preloaded" = True ]; then download_file() { printf preloaded; }; fi
case "$available" in
  readonly) readonly _DOWNLOADS_SH_LOADED='' ;;
  already-loaded) _DOWNLOADS_SH_LOADED=1 ;;
esac
dirname() { builtin command /usr/bin/dirname "$@"; }
PATH=/no-external-commands
run_caller() { source "$caller"; }
if [ "$outer" = strict ]; then set -e; fi
shell_fixture_run_context "$context" result run_caller
printf 'RESULT:%s FLAGS:%s\n' "$result" "$-"
printf 'GUARD:%s\n' "${_DOWNLOADS_SH_LOADED-unset}"
printf 'DOWNLOAD:'; declare -F download_file >/dev/null && printf present || printf absent; printf '\n'
printf 'DIE:'; declare -F die >/dev/null && printf present || printf absent; printf '\n'
declare -f download_file die || true
'''


def capture(row, blocks, bootstrap, actual):
    with tempfile.TemporaryDirectory(prefix='ant downloads scope ') as directory:
        work = pathlib.Path(directory)
        caller = prepare(work, row, blocks, bootstrap, actual)
        args = ['/bin/bash', '-c', WORKER, '_', str(CONTEXT), directory, str(caller)]
        args.extend(str(row[key]) for key in ('available', 'preloaded', 'context', 'outer'))
        result = subprocess.run(args, cwd=work, capture_output=True, text=True, timeout=5, check=False)
        return {'rc': result.returncode, 'out': result.stdout.replace(directory, '[WORK]'),
                'err': result.stderr.replace(directory, '[WORK]'), 'trace': (work / 'trace').read_text()}


def receipts(toolchain, downloads):
    blocks = {leaf: loader((toolchain / leaf).read_text()) for leaf in ('android-sdk.sh', 'vulkan.sh')}
    bootstrap = (toolchain / 'bootstrap.sh').read_text()
    actual = downloads.read_text()
    return [{'case': row, 'receipt': capture(row, blocks, bootstrap, actual)} for row in scenarios()]


def bootstrap_failures(blocks, bootstrap, actual):
    failures = []
    assertions = 0
    for caller, layout, preloaded, context, failure in itertools.product(
        ('android-sdk.sh', 'vulkan.sh'), ('tree', 'flat'), (False, True),
        ('direct', 'conditional'), ('missing', 'return-error')
    ):
        row = {'caller': caller, 'layout': layout, 'preloaded': preloaded, 'context': context,
               'available': 'both', 'outer': 'relaxed', 'bootstrap': failure}
        result = capture(row, blocks, bootstrap, actual)
        status = 1 if failure == 'missing' else 7
        caught = caller == 'vulkan.sh' and context == 'conditional'
        checks = (result['rc'] == (0 if caught else status),
                  (f'RESULT:{status} ' in result['out']) if caught else result['out'] == '',
                  result['trace'] == '',
                  ('bootstrap.sh' in result['err']) if failure == 'missing' else result['err'] == '')
        assertions += len(checks)
        if not all(checks):
            failures.append(f'bootstrap failure {row}: {result}')
    return assertions, failures


def copy_mappings(stage):
    actual = {}
    for _, line in instructions(ROOT / 'linux' / f'Dockerfile.{stage}'):
        sources = copy_sources(line)
        if not sources:
            continue
        destination = line.split()[-1]
        for source in sources:
            if (ROOT / source).is_dir():
                for child in (ROOT / source).iterdir():
                    if child.is_file():
                        actual[destination.rstrip('/') + '/' + child.name] = (str(child.relative_to(ROOT)), '--chmod=755' in line.split())
                continue
            target = destination
            if len(sources) > 1 or destination.endswith('/'):
                target = destination.rstrip('/') + '/' + pathlib.PurePosixPath(source).name
            actual[target] = (source, '--chmod=755' in line.split())
    return actual


def copied_companions():
    expected = {
        'android': {'/opt/scripts/android-sdk.sh': 'android-sdk.sh', '/opt/scripts/bootstrap.sh': 'bootstrap.sh',
                    '/opt/scripts/bootstrap-import.sh': 'bootstrap-import.sh'},
        'package': {'/opt/scripts/android-sdk.sh': 'android-sdk.sh', '/opt/scripts/bootstrap.sh': 'bootstrap.sh',
                    '/opt/scripts/bootstrap-import.sh': 'bootstrap-import.sh'},
        'sdk': {'/opt/scripts/toolchain/vulkan.sh': 'vulkan.sh', '/opt/scripts/toolchain/bootstrap.sh': 'bootstrap.sh',
                '/opt/scripts/toolchain/bootstrap-import.sh': 'bootstrap-import.sh'},
        'torch': {'/usr/local/bin/vulkan.sh': 'vulkan.sh', '/usr/local/bin/bootstrap.sh': 'bootstrap.sh',
                  '/usr/local/bin/vulkan-install.sh': 'vulkan-install.sh', '/usr/local/bin/bootstrap-import.sh': 'bootstrap-import.sh'},
    }
    failures = []
    assertions = 0
    for stage, files in expected.items():
        actual = copy_mappings(stage)
        for target, leaf in files.items():
            assertions += 1
            wanted = (f'linux/scripts/02-toolchain/{leaf}', True)
            if actual.get(target) != wanted:
                failures.append(f'{stage}: {target} expected {wanted}, got {actual.get(target)}')
    return assertions, failures


def copied_vulkan_probe():
    mappings = copy_mappings('torch')
    with tempfile.TemporaryDirectory(prefix='ant copied Vulkan ') as directory:
        work = pathlib.Path(directory)
        for leaf in ('vulkan.sh', 'bootstrap.sh', 'bootstrap-import.sh', 'vulkan-install.sh'):
            source = mappings.get('/usr/local/bin/' + leaf)
            if source is not None:
                (work / leaf).write_bytes((ROOT / source[0]).read_bytes())
        core = work / 'core'
        core.mkdir()
        source = mappings.get('/opt/scripts/core/path-helpers.sh')
        if source is not None:
            (core / 'path-helpers.sh').write_bytes((ROOT / source[0]).read_bytes())
        bootstrap = work / 'bootstrap.sh'
        bootstrap.write_text(bootstrap.read_text().replace('/opt/scripts/core', str(core)))
        script = ('dirname() { builtin command /usr/bin/dirname "$@"; }; download_file() { :; }; '
                  'PATH=/no-external-commands; source "$1" || exit $?; '
                  'declare -F install_vulkan_sdk install_vulkan_prereqs >/dev/null')
        result = subprocess.run(['/bin/bash', '-c', script, '_', str(work / 'vulkan.sh')],
                                capture_output=True, text=True, timeout=5, check=False)
    checks = (result.returncode == 0, result.stdout == '', result.stderr == '')
    failures = [] if all(checks) else [f'actual copied Vulkan source closure failed: {result}']
    return len(checks), failures


def main():
    toolchain, downloads = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    expected = json.loads(pathlib.Path(__file__).with_name('toolchain-download-loader-receipts.json').read_text())
    current = receipts(toolchain, downloads)
    assertions = 1
    failures = []
    if [row['case'] for row in current] != [row['case'] for row in expected]:
        failures.append('frozen scenario inventory changed')
    for wanted, actual in zip(expected, current, strict=True):
        for field in ('rc', 'out', 'err', 'trace'):
            assertions += 1
            if wanted['receipt'][field] != actual['receipt'][field]:
                failures.append(f"{wanted['case']} {field}: expected {wanted['receipt'][field]!r}, got {actual['receipt'][field]!r}")
    blocks = {leaf: loader((toolchain / leaf).read_text()) for leaf in ('android-sdk.sh', 'vulkan.sh')}
    count, errors = bootstrap_failures(blocks, (toolchain / 'bootstrap.sh').read_text(), downloads.read_text())
    assertions += count
    failures.extend(errors)
    count, errors = copied_companions()
    assertions += count
    failures.extend(errors)
    count, errors = copied_vulkan_probe()
    assertions += count
    failures.extend(errors)
    for message in failures[:10]:
        print(f'FAIL: {message}', file=sys.stderr)
    if failures:
        print(f'  {len(failures)}/{assertions} assertion(s) FAILED', file=sys.stderr)
        return 1
    print(f'  {assertions} assertion(s) passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
