#!/usr/bin/env bash
# probe-hailo-nested-cache.sh — does a nested build spawned through HailoRT's clean-env channel reach
# the compiler cache in THIS image? Three passes: HAILO_NESTED_CACHE=off, then carry cold and warm.
# Seconds, no network, writes only under TMPDIR. Exit 0 when the warm pass hit on every object.
# docs/hailo-support.md#the-nested-build-cache-and-pyhailort-two-switches
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../core/common.sh"
media_common_init "${SCRIPT_DIR}"
# shellcheck source=linux/scripts/03-media/build/hailo/hailo-build-lib.sh
source "${SCRIPT_DIR}/hailo-build-lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hailo-nested-probe.XXXXXX")"
LAUNCHER="${CMAKE_CXX_COMPILER_LAUNCHER:-}"

# 24 TUs whose text is new on every run, so the carry cold pass really is cold.
write_projects() {
  local salt i
  salt="$(date +%s%N)$$"
  mkdir -p "${WORK}/child" "${WORK}/parent"
  {
    printf 'cmake_minimum_required(VERSION 3.16)\nproject(hailo_probe_child CXX)\nadd_library(probe STATIC'
    for i in $(seq 1 24); do
      printf 'int probe_%s_%d() { return %d; }\n' "${salt}" "${i}" "${i}" > "${WORK}/child/t${i}.cc"
      printf ' t%d.cc' "${i}"
    done
    printf ')\n'
  } > "${WORK}/child/CMakeLists.txt"
  {
    printf 'cmake_minimum_required(VERSION 3.16)\nproject(hailo_probe_parent NONE)\n'
    printf 'execute_process(COMMAND %s "%s" RESULT_VARIABLE rc)\n' "${_HAILO_CLEAN_ENV_CHANNEL}" \
      "'\${CMAKE_COMMAND}' -S '\${CHILD_SRC}' -B '\${CHILD_BUILD}' -G Ninja && '\${CMAKE_COMMAND}' --build '\${CHILD_BUILD}'"
    printf 'if(rc)\n  message(FATAL_ERROR "the nested build failed: ${rc}")\nendif()\n'
  } > "${WORK}/parent/CMakeLists.txt"
}

# probe_pass <mode> <label> -> "objects|hits" of the nested build, after the library's own gate.
probe_pass() {
  local before hits0 hits1 objs
  rm -rf "${WORK}/child-build" "${WORK}/parent-build"
  before="$(hailo_cache_counters "${LAUNCHER}")"
  IFS='|' read -r _ hits0 _ <<<"${before}"
  HAILO_NESTED_CACHE="$1" hailo_nested_configure "probe-$2" "${WORK}/child-build" \
    "${WORK}/parent/CMakeLists.txt" -S "${WORK}/parent" -B "${WORK}/parent-build" -G Ninja \
    -DCHILD_SRC="${WORK}/child" -DCHILD_BUILD="${WORK}/child-build" >/dev/null || return 1
  IFS='|' read -r _ hits1 _ <<<"$(hailo_cache_counters "${LAUNCHER}")"
  objs="$(hailo_ninja_objects "${WORK}/child-build/.ninja_log")"
  [ "${before}" != "-|-|-|-" ] || { printf '%s|-\n' "${objs}"; return 0; }
  printf '%s|%s\n' "${objs}" "$((hits1 - hits0))"
}

write_projects
rc=0 result=""
for pass in off:off carry:carry-cold carry:carry-warm; do
  result="$(probe_pass "${pass%%:*}" "${pass#*:}")" || { rc=1; break; }
  printf '[probe] %-10s objects=%s hits=%s\n' "${pass#*:}" "${result%%|*}" "${result#*|}"
done
# hits may exceed objects: the nested configure's own compiler checks go through the cache too.
if [ "${rc}" -eq 0 ] && [ "${result%%|*}" -gt 0 ] 2>/dev/null && [ "${result#*|}" -ge "${result%%|*}" ] 2>/dev/null; then
  printf '[probe] CACHED: the nested build reaches %s, and the warm pass hit on every object\n' "${LAUNCHER}"
else
  printf '[probe] NOT CACHED: see the [hailo]/[CACHE] lines above (launcher=%s)\n' "${LAUNCHER:-none}"
  rc=1
fi
rm -rf "${WORK}"
exit "${rc}"
