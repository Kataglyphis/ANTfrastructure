"""Freeze host/namespace probe receipts and safe imports without services, networking or emulator execution."""
import json
import pathlib
import shlex
import subprocess
import sys
import tempfile

import binfmt_probe_controls as controls


def function(text, name):
    start = text.index(name + '() {')
    end = text.index('\n}', start) + 2
    return text[start:end]


def body(caller, owner, manifest):
    if caller == 'installer':
        text = owner.read_text()
        start = text.index('_binfmt_missing=""')
        end = text.index('\nlog "done.', start)
        return 'source ' + shlex.quote(str(owner)) + ' --source-binfmt-probe\n' + text[start:end]
    text = manifest.read_text()
    return function(text, '_binfmt_qemu_name') + '\n' + function(text, 'verify_foreign_binfmt') + '\nverify_foreign_binfmt arm64,riscv64'


WORKER = r'''
set -u
root="$1" body="$2" caller="$3" host="$4" lookup="$5" override="$6" ns_status="$7" strict="$8" context="$9"
REPO_ROOT="$root/copied repo with spaces"
trace="$root/trace"
: > "$trace"
printf '0\n' > "$root/lookups"
log() { printf 'LOG:%s\n' "$*"; }
warn() { printf 'WARN:%s\n' "$*" >&2; }
err() { printf 'ERR:%s\n' "$*" >&2; exit 1; }
arch_list_to_words() { printf 'arm64 riscv64'; }
grep() {
  case "${!#}" in /proc/sys/fs/binfmt_misc/*) ;; *) builtin command grep "$@"; return "$?" ;; esac
  printf 'host' >> "$trace"; printf '<%s>' "$@" >> "$trace"; printf '\n' >> "$trace"
  case "$host:${!#}" in yes:*|first:*/qemu-aarch64) return 0 ;; error:*) return 2 ;; *) return 1 ;; esac
}
command() {
  if [ "$1" = -v ] && [ "$2" = containerd-rootless-setuptool.sh ]; then
    printf 'lookup\n' >> "$trace"
    if [ "$lookup" = flip ]; then
      IFS= read -r count < "$root/lookups"
      count=$((count + 1)); printf '%s\n' "$count" > "$root/lookups"
      if [ "$count" -gt 1 ]; then printf resolved-tool; return 0; else return 1; fi
    fi
    if [ "$lookup" = space ]; then printf '%s' "$root/tool with spaces"; return 0; fi
    if [ "$lookup" = found ]; then printf resolved-tool; return 0; else return 1; fi
  fi
  builtin command "$@"
}
namespace() {
  printf 'tool:<%s>' "$1" >> "$trace"; shift
  printf '<%s>' "$@" >> "$trace"; printf '\n' >> "$trace"
  printf 'namespace-out\n'; printf 'namespace-err\n' >&2
  return "$ns_status"
}
containerd-rootless-setuptool.sh() { namespace default "$@"; }
resolved-tool() { namespace resolved "$@"; }
custom-tool() { namespace custom "$@"; }
case "$override" in unset) unset _SETUPTOOL ;; empty) _SETUPTOOL='' ;; custom) _SETUPTOOL=custom-tool ;; space) _SETUPTOOL="$root/tool with spaces" ;; esac
NERDCTL_INSTALL_CONFIRM=1 NERDCTL_VERSION=2 NERDCTL_ROOTLESS=1
NERDCTL_UNIT_DIR="$root/no-units" NERDCTL_PREFIX="$root/prefix" NERDCTL_BACKUP_DIR="$root/backup"
CROSS_CHAIN_PIDFILE="$root/no-pid" HOME="$root" BUILDKIT_HOST=fixture
curl() { printf "FORBIDDEN:curl\n" >> "$trace"; return 99; }
wget() { printf "FORBIDDEN:wget\n" >> "$trace"; return 99; }
systemctl() { printf "FORBIDDEN:systemctl\n" >> "$trace"; return 99; }
sudo() { printf "FORBIDDEN:sudo\n" >> "$trace"; return 99; }
nerdctl() { printf "FORBIDDEN:nerdctl\n" >> "$trace"; return 99; }
buildctl() { printf "FORBIDDEN:buildctl\n" >> "$trace"; return 99; }
tar() { printf "FORBIDDEN:tar\n" >> "$trace"; return 99; }
mkdir() { printf "FORBIDDEN:mkdir\n" >> "$trace"; return 99; }
cp() { printf "FORBIDDEN:cp\n" >> "$trace"; return 99; }
mv() { printf "FORBIDDEN:mv\n" >> "$trace"; return 99; }
rm() { printf "FORBIDDEN:rm\n" >> "$trace"; return 99; }
pgrep() { printf "FORBIDDEN:pgrep\n" >> "$trace"; return 99; }
uname() { printf "FORBIDDEN:uname\n" >> "$trace"; return 99; }
id() { printf "FORBIDDEN:id\n" >> "$trace"; return 99; }
sleep() { printf "FORBIDDEN:sleep\n" >> "$trace"; return 99; }
invoke() { source "$body"; }
[ "$strict" != strict ] || set -e
if [ "$context" = conditional ]; then
  if invoke; then status=0; else status=$?; fi
else
  invoke
  status=$?
fi
printf 'returned:%s\n' "$status"
exit "$status"
'''


def receipt(result, trace, base):
    return {'status': result.returncode, 'out': result.stdout.replace(str(base).encode(), b'<fixture>').hex(),
            'err': result.stderr.replace(str(base).encode(), b'<fixture>').hex(),
            'trace': trace.replace(str(base).encode(), b'<fixture>').hex()}


def probe_cases(base, owner, manifest, oracle):
    worker = base / 'probe-worker.sh'
    worker.write_text(WORKER)
    tool = base / 'tool with spaces'
    trace = shlex.quote(str(base / 'trace'))
    status = shlex.quote(str(base / 'ns-status'))
    tool.write_text('#!/usr/bin/env bash\nprintf \'tool:<space>\' >> ' + trace + '\nprintf \'<%s>\' "$@" >> ' + trace
                    + '\nprintf \'\\n\' >> ' + trace + '\nprintf \'namespace-out\\n\'\nprintf \'namespace-err\\n\' >&2\n'
                    + 'IFS= read -r status < ' + status + '\nexit "$status"\n')
    tool.chmod(0o755)
    for row in oracle:
        caller, host, lookup, override, status, strict, context = row['case']
        (base / 'ns-status').write_text(str(status) + '\n')
        script = base / 'body.sh'
        script.write_text(body(caller, owner, manifest))
        result = subprocess.run(['bash', str(worker), str(base), str(script), caller, host, lookup,
                                 override, str(status), strict, context], check=False, capture_output=True, timeout=5)
        actual = receipt(result, (base / 'trace').read_bytes(), base)
        assert actual == row['receipt'], (row['case'], actual, row['receipt'])
    return len(oracle)


def main():
    owner = pathlib.Path(sys.argv[1])
    manifest = pathlib.Path(sys.argv[2])
    oracle = json.loads(pathlib.Path(sys.argv[3]).read_text())
    with tempfile.TemporaryDirectory() as temporary:
        base = pathlib.Path(temporary)
        copied = base / 'copied repo with spaces/linux/host-config/install-nerdctl-full.sh'
        copied.parent.mkdir(parents=True)
        copied.write_bytes(owner.read_bytes())
        assert copied.read_bytes() == owner.read_bytes()
        controls.configure(base, copied, manifest, oracle['standalone'], function, receipt)
        count = probe_cases(base, copied, manifest, oracle['probes'])
        count += controls.state_controls()
        count += controls.refusal_controls()
        count += controls.standalone_controls()
        count += controls.executed_control()
        flat = base / 'flat owner with spaces.sh'
        flat.write_bytes(owner.read_bytes())
        controls.OWNER = flat
        count += controls.state_controls()
        count += controls.standalone_controls()
        count += controls.executed_control()
    print(f'  {count} contract case(s) passed')


if __name__ == '__main__':
    main()
