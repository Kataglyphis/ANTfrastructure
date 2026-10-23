"""Exercise actual installer service sections with command stubs and a blocked external PATH."""
import itertools
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
CONTEXT = ROOT / 'linux/scripts/tests/shell-context-fixture.sh'


def cases():
    rows = []
    for section, units, splitting, include in itertools.product(
        ('stop', 'start'), ('', 'containerd.service buildkit.service', '*.service', 'missing*.service', 'unit with spaces'),
        ('default', 'narrow', 'noglob'), ('0', '1')
    ):
        rows.append({'section': section, 'units': units, 'splitting': splitting, 'include': include})
    for section, status, warning, context, strict in itertools.product(
        ('stop', 'start'), (7, 127), (0, 9), ('direct', 'conditional'), ('relaxed', 'strict')
    ):
        rows.append({'section': section, 'service': status, 'warning': warning, 'context': context, 'strict': strict})
    for active, rootless, status, warning, context, strict in itertools.product(
        ('none', 'containerd', 'both'), ('0', '1'), (0, 7), (0, 9), ('direct', 'conditional'), ('relaxed', 'strict')
    ):
        rows.append({'section': 'rollback', 'active': active, 'rootless': rootless, 'service': status,
                         'warning': warning, 'context': context, 'strict': strict})
    for status, context, strict in itertools.product((0, 7), ('direct', 'conditional'), ('relaxed', 'strict')):
        rows.append({'section': 'repoint', 'service': status, 'context': context, 'strict': strict})
    for rootless, context, strict in itertools.product(('0', '1'), ('direct', 'conditional'), ('relaxed', 'strict')):
        rows.append({'section': 'rollback', 'rootless': rootless, 'copy': 7, 'context': context, 'strict': strict})
    return rows


def sections(source):
    text = source.read_text()
    markers = {
        'rollback': ('# Rollback: bin/', '# Refuse while a build runs:'),
        'stop': ('log "stopping user services"', 'log "extracting into ${PREFIX}'),
        'start': ('log "starting services"', '# Prove it works'),
        'repoint': ('    log "already on v${TARGET#v}; repointing units', '    exit 0\n'),
    }
    result = {}
    for name, (start, end) in markers.items():
        at = text.index(start)
        until = text.index(end, at)
        result[name] = text[at:until] + ('exit 0\n' if name == 'repoint' else '')
    return result


def helpers(source):
    return source.read_text().split('# Rollback: bin/', 1)[0].replace('warn()', '_fixture_actual_warn()')


WORKER = r'''
set -u
functions="$1"
source "$2"
WORK="$3" SECTION="$4" ROOTLESS="$5" _rootful_active="$6" NERDCTL_INCLUDE_ROOTFUL="$7"
SERVICE_STATUS="$8" WARN_STATUS="$9"
shift 9
COPY_STATUS="$1" ROOT_ACTIVE="$2" splitting="$3" context="$4" strict="$5"
NERDCTL_BACKUP_DIR="$WORK/backup" NERDCTL_PREFIX="$WORK/prefix" NERDCTL_UNIT_DIR="$WORK/units" NERDCTL_ROOTLESS="$ROOTLESS"
TARGET=v1
_ok=1
trace() { printf '%q ' "$@" >> "$WORK/calls"; printf '\n' >> "$WORK/calls"; }
systemctl() {
  trace systemctl "$@"
  if [ "$1" = is-active ]; then
    case "$ROOT_ACTIVE:$3" in both:*|containerd:containerd.service) return 0 ;; *) return 1 ;; esac
  fi
  printf 'systemctl stdout\n'; printf 'systemctl stderr\n' >&2
  return "$SERVICE_STATUS"
}
sudo() {
  trace sudo "$@"
  printf 'sudo stdout\n'; printf 'sudo stderr\n' >&2
  case "$1" in systemctl) return "$SERVICE_STATUS" ;; cp) return "$COPY_STATUS" ;; *) return 97 ;; esac
}
cp() { trace cp "$@"; printf 'cp stdout\n'; printf 'cp stderr\n' >&2; return "$COPY_STATUS"; }
tr() { trace tr "$@"; printf 'fixture backup version'; }
nerdctl() { trace nerdctl "$@"; printf 'fixture nerdctl version\n'; }
sleep() { trace sleep "$@"; }
_repoint_user_units() { trace repoint; }
_check_dropin_prefix() { trace check-prefix; return 7; }
_wait_ready() { trace wait-ready "$@"; return "$SERVICE_STATUS"; }
warn() { _fixture_actual_warn "$@"; return "$WARN_STATUS"; }
id() { printf 1000; }
PATH=/no-real-commands
source "$functions"
DETECTED_PREFIX=old
run_section() { source "$SECTION" --rollback; }
case "$splitting" in narrow) IFS=$'\n\t' ;; noglob) set -f ;; esac
PATH=/no-real-commands
if [ "$strict" = relaxed ]; then set +e; else set -e; fi
shell_fixture_run_context "$context" result run_section
printf 'DONE:%s OK:%s\n' "$result" "$_ok"
'''


def capture(source, row, extracted, functions):
    defaults = {'rootless': '1', 'units': 'containerd.service buildkit.service', 'include': '1',
                    'service': 0, 'warning': 0, 'copy': 0, 'active': 'both', 'splitting': 'default', 'context': 'direct', 'strict': 'strict'}
    defaults.update(row)
    with tempfile.TemporaryDirectory(prefix='ant-service-oracle-') as directory:
        work = pathlib.Path(directory)
        for relative in ('backup/bin', 'backup/lib/systemd/system', 'backup/systemd-user', 'prefix/lib/systemd/system', 'units'):
            (work / relative).mkdir(parents=True, exist_ok=True)
        for relative in ('alpha.service', 'zeta.service', 'calls', 'backup/VERSION'):
            (work / relative).write_text('')
        (work / 'functions').write_text(functions)
        (work / 'section').write_text(extracted[row['section']])
        command = ['/bin/bash', '-c', WORKER, '_', str(work / 'functions'), str(CONTEXT), directory, str(work / 'section')]
        command.extend(str(defaults[key]) for key in ('rootless', 'units', 'include', 'service', 'warning', 'copy',
                                                      'active', 'splitting', 'context', 'strict'))
        result = subprocess.run(command, cwd=work, capture_output=True, text=True, timeout=5, check=False)
        return {'rc': result.returncode, 'out': result.stdout.replace(directory, '[WORK]'),
                    'err': result.stderr.replace(directory, '[WORK]'), 'calls': (work / 'calls').read_text().replace(directory, '[WORK]')}


def main():
    source = pathlib.Path(sys.argv[1]).resolve()
    expected = json.loads(pathlib.Path(sys.argv[2]).read_text())
    extracted, functions = sections(source), helpers(source)
    failures = []
    assertions = 1
    if [row['case'] for row in expected] != cases():
        failures.append('the frozen scenario inventory differs')
    for row in expected:
        actual = capture(source, row['case'], extracted, functions)
        for field in ('rc', 'out', 'err', 'calls'):
            assertions += 1
            if actual[field] != row['receipt'][field]:
                failures.append(f"{row['case']} {field}: expected {row['receipt'][field]!r}, got {actual[field]!r}")
    for message in failures[:10]:
        print(f'FAIL: {message}', file=sys.stderr)
    if failures:
        print(f'  {len(failures)}/{assertions} assertion(s) FAILED', file=sys.stderr)
        return 1
    print(f'  {assertions} assertion(s) passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
