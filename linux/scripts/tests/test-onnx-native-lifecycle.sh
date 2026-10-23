#!/usr/bin/env bash
# Stubbed native build tails check retry, diagnostics and wheel fallback policy; no ORT compilation, network or wheel repair runs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
ORT="${TESTS_DIR}/../03-media/build/onnxruntime/build"
COMMON="${1:-${ORT}/lib/common.sh}"
CPU="${2:-${ORT}/30-build-native.sh}"
AMD="${3:-${ORT}/30-build-native-amd.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
for helper in run_onnx_native_build collect_onnx_native_wheels; do
  if grep -Eq "^${helper}\(\)" "${COMMON}"; then eval "$(t_fn_src "${COMMON}" "${helper}")"; fi
done
for backend in cpu amd; do
  script="${CPU}"
  [ "${backend}" != amd ] || script="${AMD}"
  python3 - "${script}" "${WORK}/${backend}.sh" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
starts = ['# Execute build (with retry', 'if ! "${BUILD_SH}"', 'run_onnx_native_build ']
start = min(text.index(marker) for marker in starts if marker in text)
end = text.index('copy_onnx_headers_to_output ', start)
Path(sys.argv[2]).write_text(text[start:end] + '\necho tail-complete\n')
PY
done
for helper in run_onnx_native_build collect_onnx_native_wheels; do
  if declare -F "${helper}" >/dev/null; then declare -f "${helper}"; fi
done > "${WORK}/runner.sh"
cat >> "${WORK}/runner.sh" <<'RUNNER'
WORK="$1"; backend="$2"; cross="$3"; build_rc="$4"; wheels="$5"; collect_rc="$6"
export NATIVE_CPU_BUILD_DIR="${WORK}/CPU build" NATIVE_GPU_BUILD_DIR="${WORK}/AMD build"
export NATIVE_CPU_OUTPUT_DIR="${WORK}/output" NATIVE_GPU_OUTPUT_DIR="${WORK}/output"
export NATIVE_CPU_CONFIG=RelWithDebInfo ORT_SRC_DIR="${WORK}/source tree" HOST_PYTHON='/fixture/python path'
export BUILD_SH=fixture_build
 BUILD_ARGS=('first option' '--second')
fixture_build() { printf 'build <%s> <%s>\n' "$1" "$2" >> "${WORK}/calls"; return "${build_rc}"; }
_ort_build_attempt() { fixture_build "${BUILD_ARGS[@]}"; }
retry() {
  local attempt
  printf 'retry <%s> <%s> <%s> <%s>\n' "$1" "$2" "$3" "$4" >> "${WORK}/calls"
  shift 3
  for attempt in 1 2 3; do
    if "$@"; then return 0; fi
    printf 'retry-attempt=%s\n' "${attempt}" >> "${WORK}/calls"
  done
  return 1
}
cross_build_is_active() { [ "${cross}" = cross ]; }
warn() { printf 'WARN:%s\n' "$*"; }
info() { printf 'INFO:%s\n' "$*"; }
cmake() { printf 'diagnostics <%s> <%s> <%s> <%s> <%s> <%s> <%s>\n' "$@" >> "${WORK}/calls"; return 19; }
collect_wheels_from_tree() {
  printf 'collect <%s> <%s> <%s>\n' "$1" "$2" "$3" >> "${WORK}/calls"
  if [ "${wheels}" = present ]; then : > "$2/wheels/built.whl"; fi
  return "${collect_rc}"
}
maybe_build_source_wheel() { printf 'fallback <%s> <%s> <%s> <%s>\n' "$@" >> "${WORK}/calls"; }
# shellcheck source=/dev/null
source "${WORK}/${backend}.sh"
RUNNER
run_tail() {
  local status=0
  rm -rf "${WORK}/output"; mkdir -p "${WORK}/output/wheels"
  : > "${WORK}/calls"
  bash -euo pipefail "${WORK}/runner.sh" "${WORK}" "$1" "$2" "$3" "$4" "${5:-0}" \
    > "${WORK}/output.txt" 2>&1 || status=$?
  printf '%s' "${status}"
}
for backend in cpu amd; do
  build_tree="${WORK}/CPU build"; wheel_label='ONNX Runtime wheel'; source_label='ONNX Runtime'
  if [ "${backend}" = amd ]; then build_tree="${WORK}/AMD build"; wheel_label='MIGraphX wheel'; source_label='ONNX Runtime MIGraphX'; fi
  for cross in native cross; do
    for result in success failure; do
      t_case "${backend} ${cross}: ${result} build"
      build_rc=0; [ "${result}" != failure ] || build_rc=7
      status="$(run_tail "${backend}" "${cross}" "${build_rc}" absent)"
      calls="$(cat "${WORK}/calls")"
      expected=0; [ "${result}" != failure ] || expected=1
      t_assert_eq "${expected}" "${status}"
      attempts=1; if [ "${backend}:${result}" = cpu:failure ]; then attempts=3; fi
      t_assert_eq "${attempts}" "$(grep -Ec '^build <first option> <--second>$' "${WORK}/calls")" 'arguments and retry count'
      if [ "${backend}" = cpu ]; then t_assert_contains "${calls}" 'retry <3> <10> <ONNX Runtime CPU build> <_ort_build_attempt>'; fi
      if [ "${result}" = failure ]; then
        t_assert_rc 1 grep -Eq '^collect|^fallback' "${WORK}/calls"
        if [ "${cross}" = cross ]; then
          t_assert_contains "${calls}" "diagnostics <--build> <${build_tree}/RelWithDebInfo> <--config> <RelWithDebInfo> <--parallel> <1> <--verbose>"
          t_assert_contains "$(cat "${WORK}/output.txt")" 'rerunning single-threaded verbose build for diagnostics'
        else
          t_assert_rc 1 grep -Eq '^diagnostics' "${WORK}/calls"
        fi
      else
        t_assert_contains "${calls}" "collect <${build_tree}> <${WORK}/output> <${wheel_label}>"
        if [ "${cross}" = native ]; then
          t_assert_contains "${calls}" "fallback <${WORK}/source tree> <${WORK}/output> </fixture/python path> <${source_label}>"
        else
          t_assert_rc 1 grep -Eq '^fallback' "${WORK}/calls"
        fi
        t_assert_contains "$(cat "${WORK}/output.txt")" tail-complete
      fi
    done
  done
  t_case "${backend}: an existing wheel prevents source fallback"
  t_assert_eq 0 "$(run_tail "${backend}" native 0 present)"
  t_assert_rc 1 grep -Eq '^fallback' "${WORK}/calls"
  t_case "${backend}: wheel collection failure remains fatal"
  t_assert_eq 17 "$(run_tail "${backend}" native 0 absent 17)"
  t_assert_rc 1 grep -Eq '^fallback' "${WORK}/calls"
done
t_summary
