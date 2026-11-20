#!/usr/bin/env bash
# Fake compilers verify scope and argv; this proves no native build, compiler cache hit, S3 service or package.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
MODULE="${SCRIPTS}/02-toolchain/python/ci-compiler-cache.sh"
t_source_functions "$MODULE" python_ci_cache_prepare python_ci_cached_command || exit 1
work="$(t_mktemp -d)" || exit 1
mkdir "$work/core"
_PYTHON_CI_CACHE_CORE="$work/core"
CACHE_RECORD="$work/record.json"
FAKE_CACHE_LAUNCHER="$work/launcher's cache"
CC="$work/compiler's cc"
CXX="$work/compiler cxx"
FAKE_ENV_STATUS=0
FAKE_RESOLVER_STATUS=''
export CACHE_RECORD FAKE_CACHE_LAUNCHER CC CXX FAKE_ENV_STATUS FAKE_RESOLVER_STATUS
for tool in "$FAKE_CACHE_LAUNCHER" "$CC" "$CXX"; do
  printf '#!/usr/bin/env bash\n:\n' > "$tool"
  chmod +x "$tool"
done
_setup_cache_stubs() {
  compiler_cache_launcher_env() { CACHE_ENV_PUBLISHED=yes; return "${FAKE_ENV_STATUS:-0}"; }
  compiler_cache_launcher() { [[ -z ${FAKE_RESOLVER_STATUS:-} ]] || return "$FAKE_RESOLVER_STATUS"; printf '%s\n' "$FAKE_CACHE_LAUNCHER"; }
}
_setup_cache_stubs
cache_callback() {
  python3 -c 'import json,os,shlex,sys; from pathlib import Path; Path(os.environ["CACHE_RECORD"]).write_text(json.dumps({"cc":shlex.split(os.environ["CC"]),"cxx":shlex.split(os.environ["CXX"]),"argv":sys.argv[1:]}))' "$@" || return $?
  CACHE_CALLBACK_PUBLISHED=yes
  return "${FAKE_CALLBACK_STATUS:-0}"
}
_assert_cached() {
  python3 - "$CACHE_RECORD" "$FAKE_CACHE_LAUNCHER" "$CC" "$CXX" <<'PYTHON'
import json
import sys
from pathlib import Path

actual=json.loads(Path(sys.argv[1]).read_text())
assert actual == {"cc":[sys.argv[2],sys.argv[3]],"cxx":[sys.argv[2],sys.argv[4]],"argv":["first argument","","last"]},actual
PYTHON
}
_status() {
  local result=0
  "$@" > "$work/call.stdout" 2> "$work/call.stderr" || result=$?
  printf '%s' "$result"
}

t_case "enabled callbacks retain quoted compiler paths and complete argv"
PYTHON_BUILD_COMPILER_CACHE=on python_ci_cached_command cache_callback 'first argument' '' last
result=$?
t_assert_eq 0 "$result"
t_assert_ok _assert_cached
t_assert_eq yes "${CACHE_ENV_PUBLISHED:-}"
t_assert_eq yes "${CACHE_CALLBACK_PUBLISHED:-}"
t_assert_eq "$work/compiler's cc" "$CC" "temporary CC was restored"
t_assert_eq "$work/compiler cxx" "$CXX" "temporary CXX was restored"

t_case "a failed callback preserves raw status, evidence and original compiler names"
result=0
PYTHON_BUILD_COMPILER_CACHE=on FAKE_CALLBACK_STATUS=37 python_ci_cached_command cache_callback 'first argument' '' last || result=$?
t_assert_eq 37 "$result"
t_assert_ok _assert_cached
t_assert_eq "$work/compiler's cc" "$CC"
t_assert_eq "$work/compiler cxx" "$CXX"

t_case "disabled mode preserves unset and empty compiler variables without loading core"
_plain_callback() { CACHE_CALLBACK_PUBLISHED=plain; return "${FAKE_CALLBACK_STATUS:-0}"; }
unset CC CXX
python_ci_cached_command _plain_callback
t_assert_eq plain "$CACHE_CALLBACK_PUBLISHED"
t_assert_eq 37 "$(FAKE_CALLBACK_STATUS=37 _status python_ci_cached_command _plain_callback)"
t_assert_eq '' "${CC+x}${CXX+x}"
CC='' CXX='' PYTHON_BUILD_COMPILER_CACHE=off python_ci_cached_command _plain_callback
t_assert_eq '' "${CC+x}${CXX+x}"
CC="$work/compiler's cc" CXX="$work/compiler cxx"
export CC CXX

t_case "enabled mode refuses missing compilers, command strings and unknown modes"
t_assert_eq 2 "$(PYTHON_BUILD_COMPILER_CACHE=bad _status python_ci_cached_command _plain_callback)"
t_assert_eq 2 "$(PYTHON_BUILD_COMPILER_CACHE=on CC='' _status python_ci_cached_command _plain_callback)"
t_assert_contains "$(cat "$work/call.stderr")" "require explicit CC and CXX"
t_assert_eq 2 "$(PYTHON_BUILD_COMPILER_CACHE=on CXX='' _status python_ci_cached_command _plain_callback)"
t_assert_eq 2 "$(PYTHON_BUILD_COMPILER_CACHE=on CC='clang -O2' _status python_ci_cached_command _plain_callback)"
t_assert_eq 2 "$(PYTHON_BUILD_COMPILER_CACHE=on CXX="$work/missing" _status python_ci_cached_command _plain_callback)"
t_assert_eq 2 "$(_status python_ci_cached_command)"

t_case "required environment and resolver failures stay raw"
t_assert_eq 43 "$(PYTHON_BUILD_COMPILER_CACHE=on FAKE_ENV_STATUS=43 _status python_ci_cached_command _plain_callback)"
t_assert_eq 29 "$(PYTHON_BUILD_COMPILER_CACHE=on FAKE_RESOLVER_STATUS=29 _status python_ci_cached_command _plain_callback)"
t_assert_eq 1 "$(PYTHON_BUILD_COMPILER_CACHE=on FAKE_CACHE_LAUNCHER='' _status python_ci_cached_command _plain_callback)"
t_assert_eq 1 "$(PYTHON_BUILD_COMPILER_CACHE=on FAKE_CACHE_LAUNCHER="$work/missing-launcher" _status python_ci_cached_command _plain_callback)"

t_case "missing core imports and missing API exports refuse before the callback"
unset -f compiler_cache_launcher_env compiler_cache_launcher
t_assert_eq 1 "$(PYTHON_BUILD_COMPILER_CACHE=on _status python_ci_cached_command _plain_callback)"
printf 'return 54\n' > "$work/core/common.sh"
t_assert_eq 54 "$(PYTHON_BUILD_COMPILER_CACHE=on _status python_ci_cached_command _plain_callback)"
printf 'compiler_cache_launcher_env() { :; }\n' > "$work/core/common.sh"
t_assert_eq 1 "$(PYTHON_BUILD_COMPILER_CACHE=on _status python_ci_cached_command _plain_callback)"

t_case "a freshly imported core publishes both cache APIs into the compiling shell"
_setup_cache_stubs
t_emit_optional_functions compiler_cache_launcher_env compiler_cache_launcher > "$work/core/common.sh" || exit 1
unset -f compiler_cache_launcher_env compiler_cache_launcher
unset CACHE_ENV_PUBLISHED CACHE_CALLBACK_PUBLISHED
result=0
PYTHON_BUILD_COMPILER_CACHE=on python_ci_cached_command cache_callback 'first argument' '' last || result=$?
t_assert_eq 0 "$result"
t_assert_ok declare -F compiler_cache_launcher_env compiler_cache_launcher
t_assert_eq yes "${CACHE_ENV_PUBLISHED:-}"
t_assert_eq yes "${CACHE_CALLBACK_PUBLISHED:-}"
t_assert_ok _assert_cached

# Real compiler-cache selection remains with common.sh; these stubs exercise the command scope only.
_setup_cache_stubs

t_case "an unconditional failing callback retains Bash errexit"
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  t_fn_src "$MODULE" python_ci_cache_prepare || exit 1
  t_fn_src "$MODULE" python_ci_cached_command || exit 1
  t_emit_optional_functions compiler_cache_launcher_env compiler_cache_launcher
  printf 'fail_inside() { false; printf reached > "$CACHE_RECORD"; }\nPYTHON_BUILD_COMPILER_CACHE=on python_ci_cached_command fail_inside\n'
} > "$work/strict-worker.sh"
rm -f "$CACHE_RECORD"
result=0
bash "$work/strict-worker.sh" > "$work/strict.stdout" 2> "$work/strict.stderr" || result=$?
t_assert_eq 1 "$result"
t_assert_fails test -e "$CACHE_RECORD"

t_summary
