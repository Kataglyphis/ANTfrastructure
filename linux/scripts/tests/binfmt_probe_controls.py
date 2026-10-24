"""Exercise physical copied owners, side-effect-free imports and standalone installer paths with command stubs."""
import itertools
import subprocess
from collections.abc import Callable
from pathlib import Path
from typing import TypedDict


class OracleRow(TypedDict):
    scenario: str
    receipt: dict[str, int | str]


BASE: Path
OWNER: Path
MANIFEST: Path
ORACLE: list[OracleRow]
function: Callable[[str, str], str]
receipt: Callable[[subprocess.CompletedProcess[bytes], bytes, Path], dict[str, int | str]]


def configure(base, owner, manifest, oracle, extractor, recorder):
    global BASE, OWNER, MANIFEST, ORACLE, function, receipt
    BASE, OWNER, MANIFEST, ORACLE = base, owner, manifest, oracle
    function, receipt = extractor, recorder


STATE_WORKER = r'''
set -u
owner="$1" root="$2" strict="$3" context="$4" ifs_mode="$5"
shift 5
NERDCTL_INSTALL_CONFIRM=1 NERDCTL_VERSION=2 NERDCTL_ROOTLESS=1
NERDCTL_UNIT_DIR="$root/no-units" NERDCTL_PREFIX="$root/prefix"
NERDCTL_BACKUP_DIR="$root/backup" CROSS_CHAIN_PIDFILE="$root/no-pid"
BUILDKIT_HOST=fixture UNIT_DIR=sentinel ROOTLESS=sentinel PREFIX=sentinel
CONFIRM=sentinel REPO=sentinel BACKUP_DIR=sentinel
IFS=$' \t\n'
case "$ifs_mode" in unset) unset IFS ;; custom) IFS=':,' ;; esac
umask 027
trap ':' EXIT
trap ':' TERM
trap ':' INT
log() { printf 'preexisting logger'; }
_as_root() { printf 'preexisting root helper'; }
snapshot() {
  printf '%s\0' "$@" > "$root/$phase.args"
  set -o > "$root/$phase.options"
  shopt -p > "$root/$phase.shopt" || :
  trap -p > "$root/$phase.traps"
  umask > "$root/$phase.umask"
  pwd -P > "$root/$phase.cwd"
  declare -p UNIT_DIR ROOTLESS PREFIX CONFIRM REPO BACKUP_DIR BUILDKIT_HOST IFS NERDCTL_INSTALL_CONFIRM > "$root/$phase.vars" 2>/dev/null || :
  declare -f log _as_root > "$root/$phase.functions"
}
''' + '\n'.join(name + '() { printf "' + name + '\\n" >> "$root/actions"; return 99; }'
                for name in ('curl', 'wget', 'systemctl', 'sudo', 'nerdctl', 'buildctl', 'tar', 'mkdir', 'cp', 'mv', 'rm', 'pgrep', 'uname', 'id', 'sleep')) + r'''
[ "$strict" != strict ] || set -e
phase=before; snapshot "$@"
if [ "$context" = conditional ]; then
  if source "$owner" --source-binfmt-probe ignored; then status=0; else status=$?; fi
else
  source "$owner" --source-binfmt-probe ignored
  status=$?
fi
phase=after; snapshot "$@"
declare -F binfmt_handler_enabled >/dev/null || exit 31
exit "$status"
'''


def state_controls():
    worker = BASE / 'state-worker.sh'
    worker.write_text(STATE_WORKER)
    root = BASE / 'state'
    root.mkdir(exist_ok=True)
    count = 0
    for strict, context, ifs_mode in itertools.product(('strict', 'relaxed'), ('direct', 'conditional'), ('default', 'custom', 'unset')):
        for path in root.glob('*'):
            if path.is_file():
                path.unlink()
        result = subprocess.run(['bash', str(worker), str(OWNER), str(root), strict, context, ifs_mode, 'a b', '', '*.service'], check=False, capture_output=True, timeout=5)
        assert result.returncode == 0 and not result.stdout and not result.stderr, (strict, context, ifs_mode, result)
        assert not (root / 'actions').exists()
        for field in ('args', 'options', 'shopt', 'traps', 'umask', 'cwd', 'vars', 'functions'):
            assert (root / ('before.' + field)).read_bytes() == (root / ('after.' + field)).read_bytes(), (field, strict, context, ifs_mode)
        count += 1
    return count


REFUSAL_WORKER = r'''
set -u
root="$1" functions="$2" strict="$3" context="$4"
REPO_ROOT="$root"
NERDCTL_INSTALL_CONFIRM=1
NERDCTL_UNIT_DIR="$root/no-units" NERDCTL_PREFIX="$root/prefix" NERDCTL_BACKUP_DIR="$root/backup"
CROSS_CHAIN_PIDFILE="$root/no-pid" HOME="$root" BUILDKIT_HOST=fixture
source "$functions"
err() { printf 'ERR:%s\n' "$*" >&2; exit 1; }
log() { printf 'LOG:%s\n' "$*"; }
arch_list_to_words() { printf arm64; }
binfmt_handler_enabled() { printf 'probe\n' >> "$root/actions"; return 0; }
''' + '\n'.join(name + '() { printf "' + name + '\\n" >> "$root/actions"; return 99; }'
                for name in ('curl', 'wget', 'systemctl', 'sudo', 'nerdctl', 'buildctl', 'tar', 'mkdir', 'cp', 'mv', 'rm', 'pgrep', 'uname', 'id', 'sleep')) + r'''
invoke() { verify_foreign_binfmt arm64; }
[ "$strict" != strict ] || set -e
if [ "$context" = conditional ]; then if invoke; then status=0; else status=$?; fi
else invoke; status=$?; fi
printf 'continued\n'
exit "$status"
'''


def refusal_controls():
    root = BASE / 'refusal'
    owner = root / 'linux/host-config/install-nerdctl-full.sh'
    owner.parent.mkdir(parents=True, exist_ok=True)
    worker = BASE / 'refusal-worker.sh'
    worker.write_text(REFUSAL_WORKER)
    functions = BASE / 'refusal-functions.sh'
    functions.write_text(function(MANIFEST.read_text(), 'verify_foreign_binfmt'))
    old = 'printf "DANGEROUS\\n" >> "$REPO_ROOT/actions"\nreturn 0\n'
    cases = [('older-actions', 'UNIT_DIR=corrupted\ncurl forbidden\n' + old, 1), ('old', old, 1), ('missing', None, 1), ('wrong-api', '# ANT_BINFMT_PROBE_SOURCE_API=2\n' + old, 1),
             ('source-failed', '# ANT_BINFMT_PROBE_SOURCE_API=1\nreturn 31\n', 31),
             ('missing-export', '# ANT_BINFMT_PROBE_SOURCE_API=1\nunset -f binfmt_handler_enabled\nreturn 0\n', 1)]
    count = 0
    for (name, text, expected), strict, context in itertools.product(cases, ('strict', 'relaxed'), ('direct', 'conditional')):
        if text is None:
            owner.unlink(missing_ok=True)
        else:
            owner.write_text(text)
        (root / 'actions').unlink(missing_ok=True)
        result = subprocess.run(['bash', str(worker), str(root), str(functions), strict, context], check=False, capture_output=True, timeout=5)
        assert result.returncode == expected and not result.stdout, (name, strict, context, result)
        assert not (root / 'actions').exists(), (name, 'source side effect')
        if name in ('old', 'older-actions', 'missing', 'wrong-api'):
            assert result.stderr == ('ERROR: binfmt probe owner lacks source API 1: ' + str(owner) + '\n').encode(), result
        if name == 'missing-export':
            assert result.stderr == b'ERROR: binfmt probe owner does not provide binfmt_handler_enabled\n', result
        count += 1
    return count


FULL_WORKER = r'''
set -u
owner="$1" root="$2" scenario="$3"
HOME="$root" NERDCTL_UNIT_DIR="$root/units" NERDCTL_PREFIX="$root/prefix" NERDCTL_BACKUP_DIR="$root/backup"
CROSS_CHAIN_PIDFILE="$root/no-pid" NERDCTL_ROOTLESS=1 NERDCTL_INSTALL_CONFIRM=0 NERDCTL_VERSION=2.0.0 BUILDKIT_HOST=fixture
trace() { printf '%s ' "$@" >> "$root/actions"; printf '\n' >> "$root/actions"; }
pgrep() { trace pgrep "$@"; return 1; }
uname() { trace uname "$@"; printf x86_64; }
nerdctl() {
  trace nerdctl "$@"
  case "$1" in --version) if [ "$scenario" = normal ]; then printf 'nerdctl version 2.0.0\n'; else printf 'nerdctl version 1.0.0\n'; fi ;; info) printf 'Server Version: 1.0.0\n' ;; *) return 97 ;; esac
}
buildctl() {
  trace buildctl "$@"
  case "$1" in --version) printf 'buildctl v1.0.0\n' ;; debug) printf 'BuildKit: v 1.0.0\n' ;; du) printf 'HEADER\nCACHE\n' ;; *) return 97 ;; esac
}
systemctl() { trace systemctl "$@"; if [ "$1" = is-active ]; then return 1; fi; return 0; }
cp() { trace cp "$@"; return 0; }
curl() { trace FORBIDDEN-curl "$@"; return 97; }
wget() { trace FORBIDDEN-wget "$@"; return 97; }
tar() { trace FORBIDDEN-tar "$@"; return 97; }
sudo() { trace FORBIDDEN-sudo "$@"; return 97; }
if [ "$scenario" = rollback ]; then source "$owner" --rollback; else source "$owner"; fi
'''


def standalone_controls():
    root = BASE / 'standalone'
    (root / 'units').mkdir(parents=True, exist_ok=True)
    (root / 'prefix/bin').mkdir(parents=True, exist_ok=True)
    (root / 'backup/bin').mkdir(parents=True, exist_ok=True)
    (root / 'prefix/bin/nerdctl').write_text('fixture')
    (root / 'prefix/bin/nerdctl').chmod(0o755)
    (root / 'units/containerd.service').write_text('ExecStart=' + str(root / 'prefix/bin/containerd') + '\n')
    worker = BASE / 'full-worker.sh'
    worker.write_text(FULL_WORKER)
    for row in ORACLE:
        scenario = row['scenario']
        (root / 'actions').unlink(missing_ok=True)
        result = subprocess.run(['bash', str(worker), str(OWNER), str(root), scenario], check=False, capture_output=True, timeout=5)
        trace = (root / 'actions').read_bytes()
        assert result.returncode == 0 and b'FORBIDDEN' not in trace, (scenario, result, trace)
        actual = receipt(result, trace, BASE)
        assert actual == row['receipt'], (scenario, actual, row['receipt'])
    return len(ORACLE)


EXECUTED_WORKER = r'''
set -u
owner="$1" root="$2"
NERDCTL_INSTALL_CONFIRM=1 NERDCTL_VERSION=2 NERDCTL_ROOTLESS=1
NERDCTL_UNIT_DIR="$root/no-units" NERDCTL_PREFIX="$root/prefix" NERDCTL_BACKUP_DIR="$root/backup"
CROSS_CHAIN_PIDFILE="$root/no-pid" HOME="$root" BUILDKIT_HOST=fixture
export root NERDCTL_INSTALL_CONFIRM NERDCTL_VERSION NERDCTL_ROOTLESS NERDCTL_UNIT_DIR NERDCTL_PREFIX NERDCTL_BACKUP_DIR CROSS_CHAIN_PIDFILE HOME BUILDKIT_HOST
''' + '\n'.join(name + '() { printf "' + name + '\\n" >> "$root/actions"; return 99; }; export -f ' + name
                for name in ('curl', 'wget', 'systemctl', 'sudo', 'nerdctl', 'buildctl', 'tar', 'mkdir', 'cp', 'mv', 'rm', 'pgrep', 'uname', 'id', 'sleep')) + r'''
exec bash "$owner" --source-binfmt-probe
'''


def executed_control():
    root = BASE / 'executed'
    root.mkdir(exist_ok=True)
    (root / 'actions').unlink(missing_ok=True)
    worker = BASE / 'executed-worker.sh'
    worker.write_text(EXECUTED_WORKER)
    result = subprocess.run(['bash', str(worker), str(OWNER), str(root)], check=False, capture_output=True, timeout=5)
    assert result.returncode == 2 and not result.stdout, result
    assert result.stderr == b'ERROR: --source-binfmt-probe must be sourced\n', result
    assert not (root / 'actions').exists()
    return 1
