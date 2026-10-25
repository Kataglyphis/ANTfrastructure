"""Captured bindings and physical cold source trees detect fallback regressions without apt, compilers or image builds."""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Sequence
from typing import Any

WORKER = r'''
set -u
root="$1" caller="$2" active="$3" enabled="$4" late="$5" after="$6" scope="$7" strict="$8" context="$9"
source "$root/context.sh"
PATH="$root/bin:$PATH"
trace="$root/trace"; : > "$trace"
LLVM_RELEASE=23 GCC_VERSION=16 BUILD_MODE=native TARGET_ARCH=arm64 BUILDARCH=amd64 provider_token=global profile=global LLVM_WANTED=23 CLANG_WANTED=23 GCC_WANTED=16 PYTHON_MAJOR_MINOR='' PYTHON_VERSION=''
export DEBIAN_FRONTEND=before TZ=before
if [ "$late" = preloaded ]; then
  if [ "$caller" = common ]; then _COMMON_SH_LOADED=1; else _INSTALL_DEPS_PREAMBLE_LOADED=1; fi
fi
command() {
  if [ "$1" = -v ]; then printf 'lookup:<%s>\n' "$2" >> "$trace"; fi
  builtin command "$@"
}
install_active() { cross_build_is_active() { printf 'active:%s\n' "$provider_token"; return 17; }; }
install_enabled() { cross_build_enabled() { printf 'enabled:%s\n' "$provider_token"; return 19; }; }
if [ "$active" = fn ]; then install_active; fi
if [ "$enabled" = fn ]; then install_enabled; fi
shopt -s expand_aliases
if [ "$enabled" = alias ]; then alias cross_build_enabled='printf alias-enabled; return 23'; fi
invoke() {
  if [ "$scope" = local ]; then local BUILD_MODE=cross provider_token=local profile=local; fi
  if [ "$caller" = common ]; then source "$root/core/common.sh" fixture 'a b'; else source "$root/core/install-deps-preamble.sh" fixture 'a b'; fi
}
trap 'printf "guards:%s:%s\n" "${_COMMON_SH_LOADED-unset}" "${_INSTALL_DEPS_PREAMBLE_LOADED-unset}" > "$root/exit"' EXIT
[ "$strict" != strict ] || set -e
shell_fixture_run_context "$context" status invoke
printf 'source:%s\n' "$status"
if [ "$after" = enabled ]; then cross_build_enabled() { printf 'later-enabled\n'; return 29; }; fi
for name in cross_build_is_active cross_build_enabled is_cross; do
  if declare -F "$name" >/dev/null; then declare -f "$name"; else printf 'FUNCTION-ABSENT:%s\n' "$name"; fi
  if builtin command -v "$name" >/dev/null; then
    if "$name"; then result=0; else result=$?; fi
    printf 'query:%s:%s\n' "$name" "$result"
  else printf 'query-absent:%s\n' "$name"; fi
 done
alias -p
printf 'scope:%s:%s:%s\n' "$BUILD_MODE" "$provider_token" "$profile"
printf 'argv'; printf '<%s>' "$@"; printf '\n'
printf 'guards:%s:%s\n' "${_COMMON_SH_LOADED-unset}" "${_INSTALL_DEPS_PREAMBLE_LOADED-unset}"
printf 'flags:%s\n' "$-"
declare -p DEBIAN_FRONTEND TZ
'''


def prepare(case: Sequence[str], base: pathlib.Path, core_sources: pathlib.Path) -> pathlib.Path:
    caller, active, enabled, late = case[:4]
    root = base / 'stage'
    core = root / 'core'
    core.mkdir(parents=True, exist_ok=True)
    for file in core.iterdir():
        file.unlink()
    installed = root / 'installed'
    installed.mkdir(exist_ok=True)
    for file in installed.iterdir():
        file.unlink()
    bin_dir = root / 'bin'
    bin_dir.mkdir(exist_ok=True)
    for file in bin_dir.iterdir():
        file.unlink()
    for name, mode, status in [('cross_build_is_active', active, 17), ('cross_build_enabled', enabled, 19)]:
        if mode == 'file':
            file = bin_dir / name
            file.write_text('#!/usr/bin/env bash\nprintf external-' + name + '\\n\nexit ' + str(status) + '\n')
            file.chmod(0o755)
    for name in ('common.sh', 'install-deps-preamble.sh', 'cross-active-fallback.sh'):
        text = (core_sources / name).read_text().replace('/opt/scripts/core', str(installed))
        (core / name).write_text(text)
    (core / 'compiler-cache-utils.sh').write_text(':\n')
    (core / 'load-versions-env.sh').write_text('load_versions_env() { :; }\nversion_major() { printf %s "${1%%.*}"; }\n')
    payloads = {'none': ':\n', 'enabled-fn': 'cross_build_enabled() { printf late-enabled; return 31; }\n',
                'active-fn': 'cross_build_is_active() { printf late-active; return 37; }\n',
                'enabled-alias': "alias cross_build_enabled='printf late-alias; return 41'\n",
                'false-alias': "alias false='printf late-false; return 43'\n"}
    payloads.update(preloaded=':\n', **{'repo-fail': "printf 'provider-failed\\n' >&2; return 17\n", 'installed': ':\n', 'installed-fail': ':\n'})
    (core / ('platform.sh' if caller == 'common' else 'cross-env.sh')).write_text(payloads[late])
    if late in ('installed', 'installed-fail'):
        text = 'cross_build_is_active() { printf installed-active; return 47; }\n'
        if late == 'installed-fail':
            text += "printf 'installed-failed\\n' >&2; return 17\n"
        (installed / 'cross-env.sh').write_text(text)
        (core / 'cross-env.sh').write_text('cross_build_is_active() { printf repository-active; return 53; }\n')
    (root / 'context.sh').write_bytes((pathlib.Path(__file__).resolve().parent / 'shell-context-fixture.sh').read_bytes())
    (root / 'worker.sh').write_text(WORKER)
    return root


def registration_cases(base: pathlib.Path, core_sources: pathlib.Path, oracle: list[dict[str, Any]]) -> int:
    for row in oracle:
        case = row['case']
        root = prepare(case, base, core_sources)
        result = subprocess.run(['bash', str(root / 'worker.sh'), str(root), *case], check=False, capture_output=True, timeout=5)
        actual = {'status': result.returncode, 'out': result.stdout.hex(), 'err': result.stderr.hex(),
                  'trace': (root / 'trace').read_bytes().hex(), 'exit': (root / 'exit').read_bytes().hex()}
        for key, value in actual.items():
            if isinstance(value, str):
                actual[key] = bytes.fromhex(value).replace(str(base).encode(), b'<fixture>').hex()
        assert actual == row['receipt'], (case, actual, row['receipt'])
    return len(oracle)


RETRY_WORKER = r'''
set -eu
LLVM_RELEASE=23 GCC_VERSION=16 LLVM_WANTED=23 CLANG_WANTED=23 GCC_WANTED=16 PYTHON_VERSION=''
if source "$1"; then exit 27; else status=$?; fi
[ "$status" -eq 1 ] || exit 28
[ -z "${_COMMON_SH_LOADED:-}${_INSTALL_DEPS_PREAMBLE_LOADED:-}" ] || exit 29
cp "$2" "${1%/*}/cross-active-fallback.sh"
source "$1"
declare -F cross_build_is_active >/dev/null
'''


def retry_controls(base: pathlib.Path, core_sources: pathlib.Path) -> int:
    failures = [None, '', 'return 31\n', 'register_cross_active_fallback() { :; }\nreturn 31\n',
                'other() { :; }\n', 'register_cross_active_fallback() { return 31; }\n', 'if ; then\n']
    count = 0
    for caller in ('common', 'native'):
        for payload in failures:
            root = prepare([caller, 'none', 'none', 'none', 'none', 'global', 'strict', 'conditional'], base, core_sources)
            leaf = root / 'core/cross-active-fallback.sh'
            if payload is None:
                leaf.unlink()
            else:
                leaf.write_text(payload)
            entry = root / 'core' / ('common.sh' if caller == 'common' else 'install-deps-preamble.sh')
            result = subprocess.run(['bash', '-c', RETRY_WORKER, '_', str(entry), str(core_sources / leaf.name)], check=False, capture_output=True, timeout=5)
            assert result.returncode == 0, (caller, payload, result)
            count += 1
    return count


def typed_controls(core_sources: pathlib.Path) -> int:
    worker = r'''
set -eu
profile=sentinel
cross_build_is_active() { printf PREEXISTING; return 17; }
before="$(declare -f cross_build_is_active)"
source "$1" ignored
for input in '' other 42; do
 if register_cross_active_fallback "$input"; then exit 27; else status=$?; fi
 [ "$status" -eq 2 ] || exit 28
 [ "$(declare -f cross_build_is_active)" = "$before" ] || exit 29
 [ "$profile" = sentinel ] || exit 30
done
'''
    result = subprocess.run(['bash', '-c', worker, '_', str(core_sources / 'cross-active-fallback.sh')], check=False, capture_output=True, timeout=5)
    assert result.returncode == 0 and not result.stdout, result
    assert result.stderr == b'ERROR: register_cross_active_fallback requires core or native\n' * 3, result
    return 3


def instruction_mapping(text: str) -> dict[str, str]:
    if text.startswith('RUN '):
        return {target: source for source, target in re.findall(r'--mount=type=bind,source=([^,\s]+),target=([^,\s]+)', text)}
    if text.startswith('COPY '):
        words = text.replace('\\', ' ').split()
        return {words[-1].rstrip('/') + '/' + pathlib.Path(source).name: source
                for source in words[1:-1] if not source.startswith('--')}
    return {}


def cold_closures(docker_root: pathlib.Path) -> list[tuple[str, int, str, dict[str, str]]]:
    sys.path.insert(0, str(docker_root / 'scripts'))
    from verify_dockerfile_env_order import instructions
    rows = []
    entries = {'linux/scripts/01-core/common.sh', 'linux/scripts/01-core/install-deps-preamble.sh'}
    leaf = 'linux/scripts/01-core/cross-active-fallback.sh'
    for docker in ('Dockerfile.base', 'Dockerfile.toolchain', 'Dockerfile.sdk', 'Dockerfile.media'):
        for line, text in instructions(docker_root / docker):
            mapping = instruction_mapping(text)
            matching = [target for target, source in mapping.items() if source in entries]
            if not matching:
                continue
            entry = matching[0]
            target_leaf = str(pathlib.PurePosixPath(entry).parent / 'cross-active-fallback.sh')
            assert mapping.get(target_leaf) == leaf, (docker, line, 'missing fresh adjacent registration owner')
            if text.startswith('RUN '):
                readonly = f'source={leaf},target={target_leaf},ro'
                assert readonly in text, (docker, line, 'owner mount must remain read-only')
            rows.append((docker, line, entry, mapping))
    assert len(rows) == 10, ('expected six base, two toolchain and two fresh-copy closures', rows)
    return rows


def stage_closure(base: pathlib.Path, row: tuple[str, int, str, dict[str, str]], core_sources: pathlib.Path,
                  docker_root: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    docker, line, target_entry, mapping = row
    stage = base / 'cold' / (docker + str(line))
    entry = stage / target_entry.lstrip('/')
    for target, source in mapping.items():
        if not target.startswith(str(pathlib.PurePosixPath(target_entry).parent) + '/'):
            continue
        dest = stage / target.lstrip('/')
        dest.parent.mkdir(parents=True, exist_ok=True)
        source_path = docker_root.parent / source
        if source_path.is_dir():
            shutil.copytree(source_path, dest, dirs_exist_ok=True)
        else:
            dest.write_bytes(source_path.read_bytes())
    if docker == 'Dockerfile.sdk':
        for inherited in ('compiler-cache-utils.sh', 'versions.env', 'platform.sh'):
            (entry.parent / inherited).write_bytes((core_sources / inherited).read_bytes())
    if entry.name == 'install-deps-preamble.sh':
        entry.write_text(entry.read_text().replace('/opt/scripts/core', str(stage / 'opt/scripts/core')))
    leaf = entry.parent / 'cross-active-fallback.sh'
    assert leaf.read_bytes() == (core_sources / leaf.name).read_bytes()
    return entry, leaf


def layer_controls(base: pathlib.Path, core_sources: pathlib.Path, docker_root: pathlib.Path) -> int:
    count = 0
    worker = 'set -eu; BUILD_MODE=native; source "$1"; if cross_build_is_active; then status=0; else status=$?; fi; printf "%s" "$status"'
    for row in cold_closures(docker_root):
        entry, leaf = stage_closure(base, row, core_sources, docker_root)
        result = subprocess.run(['bash', '-c', worker, '_', str(entry)], check=False, capture_output=True, timeout=5)
        assert result.returncode == 0 and result.stdout == b'1' and not result.stderr, (row, result)
        leaf.unlink()
        result = subprocess.run(['bash', '-c', RETRY_WORKER, '_', str(entry), str(core_sources / leaf.name)], check=False, capture_output=True, timeout=5)
        assert result.returncode == 0, (row, 'missing leaf must fail then retry', result)
        count += 2
    return count


def main() -> None:
    core_sources = pathlib.Path(sys.argv[1]).resolve()
    oracle = json.loads(pathlib.Path(sys.argv[2]).read_text())
    docker_root = pathlib.Path(sys.argv[3]).resolve()
    with tempfile.TemporaryDirectory() as temporary:
        base = pathlib.Path(temporary)
        count = registration_cases(base, core_sources, oracle)
        count += retry_controls(base, core_sources)
        count += typed_controls(core_sources)
        count += layer_controls(base, core_sources, docker_root)
    print(f'  {count} contract case(s) passed')


if __name__ == '__main__':
    main()
