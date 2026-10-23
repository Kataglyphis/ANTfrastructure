#!/usr/bin/env bash
# Stubbed cache commands cover flag, stats and missing-companion policies without starting a server, compiler or network request.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CACHE="${1:-${TESTS_DIR}/../01-core/compiler-cache.sh}"
CMAKE="${2:-${TESTS_DIR}/../01-core/cmake-cache-linker.sh}"
GCC="${3:-${TESTS_DIR}/../02-toolchain/build-gcc.sh}"
UTILS="${4:-${TESTS_DIR}/../01-core/compiler-cache-utils.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
awk '/^# Cache stats for this compile phase/ { printing=1 } /^echo "Installing to/ { exit } printing { print }' "${GCC}" > "${WORK}/gcc-stats.sh"
cat > "${WORK}/stats.sh" <<'BASH'
set -euo pipefail
cache="$1" utils="$2" gcc="$3" directory="$4" kind="$5" launcher="$6" status="$7"
source "$utils"
source "$cache"
USE_CCACHE=1 USE_SCCACHE=true CCACHE_DIR="$directory" CCACHE_MAXSIZE=1G
CC_LAUNCHER="$launcher"
_cc_info() { :; }
_cc_warn() { printf 'WARN %s\n' "$*" >&2; }
_ccache_available() { return 0; }
_sccache_available() { return 1; }
_resolve_compiler_cache_launcher() { printf '%s' "$launcher"; }
command() {
  if [ "$kind" = dump ] && [ "$launcher" = ccache ] && [ "${2:-}" = sccache ]; then return 1; fi
  builtin command "$@"
}
sccache() {
  printf 'sccache %s\n' "$*" >> "$directory/calls"
  printf '%s\n' 'raw tool diagnostic' >&2
  printf '%s\n' 'noise' 'Compile requests 12' 'Compile requests executed 11' 'Cache hits 3' 'Cache hits (C/C++) 3' 'Cache misses 9' 'Cache read errors 2' 'Cache write errors 1' 'Cache timeouts 4' 'Forced recaches 5' 'Non-cacheable 6' 'Unsupported 7' 'Errors 8' 'Cache location Local disk' 'Max cache size 1 GiB'
  return "$status"
}
ccache() {
  printf 'ccache %s\n' "$*" >> "$directory/calls"
  if [ "$1" = -M ]; then return 0; fi
  printf '%s\n' 'raw ccache diagnostic' >&2
  printf '%s\n' 'row 1' 'row 2' 'row 3' 'row 4' 'row 5' 'row 6'
  return "$status"
}
case "$kind" in
  setup) setup_ccache ;;
  gcc) source "$gcc" ;;
  dump) dump_compiler_cache_stats ;;
esac
BASH

full=$'Compile requests 12\nCompile requests executed 11\nCache hits 3\nCache hits (C/C++) 3\nCache misses 9\nCache read errors 2\nCache write errors 1\nCache timeouts 4\nForced recaches 5\nNon-cacheable 6\nUnsupported 7\nErrors 8\nCache location Local disk\nMax cache size 1 GiB'
narrow=$'Compile requests 12\nCompile requests executed 11\nCache hits 3\nCache hits (C/C++) 3\nCache misses 9\nNon-cacheable 6\nUnsupported 7\nErrors 8'
for kind in setup gcc dump; do
  for launcher in /guarded/sccache-launcher.sh ccache; do
    for status in 0 7; do
      t_case "${kind}/${launcher} stats status ${status}"
      directory="$(mktemp -d "${WORK}/stats.XXXXXX")"
      rc=0
      timeout 5 bash "${WORK}/stats.sh" "${CACHE}" "${UTILS}" "${WORK}/gcc-stats.sh" "${directory}" "${kind}" "${launcher}" "${status}" > "${directory}/out" 2> "${directory}/err" || rc=$?
      expected_rc=0
      if [ "${kind}" = dump ] && [ "${launcher}" != ccache ] && [ "${status}" = 7 ]; then expected_rc=7; fi
      t_assert_eq "${expected_rc}" "${rc}"
      expected="${full}"
      if [ "${kind}" = gcc ]; then expected="${narrow}"; fi
      if [ "${launcher}" = ccache ]; then expected=$'row 1\nrow 2\nrow 3\nrow 4\nrow 5'; fi
      if [ "${expected_rc}" != 0 ]; then expected=''; fi
      if [ "${kind}" = dump ]; then
        t_assert_eq '' "$(cat "${directory}/out")" 'media diagnostic dumps remain on stderr'
        t_assert_eq "${expected}" "$(cat "${directory}/err")"
      else
        t_assert_eq "${expected}" "$(cat "${directory}/out")" 'phase stats retain their original selected rows on stdout'
        expected_err=''
        if [ "${kind}" = setup ] && [ "${launcher}" = ccache ]; then expected_err='WARN sccache unusable (absent or server not answering) -- using ccache for C/C++'; fi
        t_assert_eq "${expected_err}" "$(cat "${directory}/err")" 'tool diagnostics stay suppressed while the ccache fallback warning remains'
      fi
      tool=sccache
      if [ "${launcher}" = ccache ]; then tool=ccache; fi
      expected_calls="${tool} --show-stats"
      if [ "${kind}" = setup ]; then expected_calls="ccache -M 1G"$'\n'"${expected_calls}"; fi
      if [ "${kind}" = dump ] && [ "${launcher}" != ccache ] && [ "${status}" = 0 ]; then expected_calls="${expected_calls}"$'\n'"${expected_calls}"$'\n'"${expected_calls}"; fi
      t_assert_eq "${expected_calls}" "$(cat "${directory}/calls")" 'stats do not start a server or alter cache command arguments'
    done
  done
done

for module in "${CACHE}" "${CMAKE}"; do
  for value in '' 0 false FALSE False no NO off OFF true 1 yes on Falsee No Off; do
    t_case "${module##*/} disable spelling '${value}'"
    expected=1
    case "${value}" in 0|false|FALSE|False|no|NO|off|OFF) expected=0 ;; esac
    rc=0
    bash -c 'source "$1"; _flag_disabled "$2"' _ "${module}" "${value}" || rc=$?
    t_assert_eq "${expected}" "${rc}"
  done
done

t_case 'standalone CMake cache policy does not initialize or export cache defaults'
state="$(env -u USE_CCACHE -u USE_SCCACHE -u CCACHE_DIR -u SCCACHE_DIR bash -c 'source "$1"; printf "%s|%s|%s|%s" "${USE_CCACHE-unset}" "${USE_SCCACHE-unset}" "${CCACHE_DIR-unset}" "${SCCACHE_DIR-unset}"' _ "${CMAKE}")"
t_assert_eq 'unset|unset|unset|unset' "${state}"

for command_status in 0 1 7 127; do
  for tool_flag in true false False; do
    t_case "optional compiler tool preserves raw availability status $command_status with flag '$tool_flag'"
    expected_status="$command_status"
    if [ "$command_status" = 0 ] && [ "$tool_flag" = false ]; then expected_status=1; fi
    actual_status=0
    actual_output="$(bash -c '
      source "$1"
      TOOL_COMMAND_STATUS="$2"
      command() { printf "lookup stdout\n"; printf "lookup stderr\n" >&2; return "$TOOL_COMMAND_STATUS"; }
      compiler_tool_enabled compiler "$3"
    ' _ "$UTILS" "$command_status" "$tool_flag" 2> "$WORK/tool-err")" || actual_status=$?
    t_assert_eq "$expected_status" "$actual_status"
    t_assert_eq '' "$actual_output"
    t_assert_eq '' "$(cat "$WORK/tool-err")"
  done
done

t_summary
