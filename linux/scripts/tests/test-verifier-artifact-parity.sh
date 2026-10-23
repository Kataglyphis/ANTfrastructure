#!/usr/bin/env bash
# Local files and fake image probes check verifier policies; no container engine, compiler or network runs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
ARTIFACTS="${1:-${TESTS_DIR}/../03-media/runtime/verify-media-artifacts.sh}"
PARITY="${2:-${TESTS_DIR}/../06-packaging/verify-parity.sh}"
t_source_functions "${ARTIFACTS}" verify_file_exists verify_shared_lib fail_check pass_check || exit 1
t_source_functions "${PARITY}" check_versions check_imports || exit 1
for helper in verify_file_nonempty _parity_probe_pair _parity_result; do
  file="${PARITY}"; [ "${helper}" != verify_file_nonempty ] || file="${ARTIFACTS}"
  if grep -q "^${helper}()" "${file}"; then eval "$(t_fn_src "${file}" "${helper}")"; fi
done
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export STAGE=fixture
for probe in file shared; do
  for shape in valid empty link dangling directory missing; do
    t_case "${probe}: ${shape} artifact"
    rm -rf "${WORK}/artifacts"; mkdir -p "${WORK}/artifacts"
    artifact="${WORK}/artifacts/libfixture.so"
    case "${shape}" in
      valid) printf bytes > "${artifact}" ;;
      empty) : > "${artifact}" ;;
      link) printf bytes > "${WORK}/target"; ln -s "${WORK}/target" "${artifact}" ;;
      dangling) ln -s absent "${artifact}" ;;
      directory) mkdir "${artifact}" ;;
    esac
    FAILURES=0; status=0
    if [ "${probe}" = file ]; then
      verify_file_exists "${artifact}" fixture > "${WORK}/output" 2>&1 || status=$?
    else
      verify_shared_lib "${WORK}/artifacts" libfixture.so fixture > "${WORK}/output" 2>&1 || status=$?
    fi
    expected_status=1; expected="FAIL [fixture]: fixture not found: ${artifact}"
    if [ "${probe}" = shared ]; then expected="FAIL [fixture]: fixture (libfixture.so) not found in ${WORK}/artifacts"; fi
    case "${probe}:${shape}" in
      file:valid|file:link) expected_status=0; expected='' ;;
      shared:valid) expected_status=0; expected="OK   [fixture]: fixture: ${artifact}" ;;
      file:empty|file:dangling|shared:empty) expected="FAIL [fixture]: fixture is empty: ${artifact}" ;;
    esac
    t_assert_eq "${expected_status}" "${status}"
    t_assert_eq "${expected_status}" "${FAILURES}" 'exactly one failure is accounted'
    t_assert_eq "${expected}" "$(cat "${WORK}/output")"
  done
done
export WORKDIR="${WORK}" NATIVE_IMAGE='native image' CROSS_IMAGE='cross image'
export VERBOSE=0 PYTHON_MAJOR_MINOR=3.15 _VENV_ACTIVATE_PROLOGUE='activate fixture;'
echo_header() { :; }
pass() { printf 'PASS:%s\n' "$*"; }
fail() { printf 'FAIL:%s\n' "$*"; }
container_exec_strip() {
  printf '%s|%s\n' "$1" "$2" >> "${WORK}/calls"
  case "${fixture_mode}" in
    first-line) printf 'same first line\n%s second line\n' "$1"; return 17 ;;
    empty) return 19 ;;
    different) printf '%s version\n' "$1" ;;
    import-ok) printf 'FAILED-looking text\nloaded\n' ;;
    import-both-fail) printf 'traceback\nlast diagnostic\n'; return 23 ;;
    import-cross-fail) printf 'traceback\nlast diagnostic\n'; [ "$1" != 'cross image' ] || return 31 ;;
    import-native-fail) printf 'traceback\nlast diagnostic\n'; [ "$1" != 'native image' ] || return 29 ;;
  esac
}
for fixture_mode in first-line empty different import-ok import-both-fail import-native-fail import-cross-fail; do
  t_case "paired image policy: ${fixture_mode}"
  : > "${WORK}/calls"; status=0
  case "${fixture_mode}" in
    import-*) check_imports > "${WORK}/output" 2>&1 || status=$?; probes=6 ;;
    *) check_versions > "${WORK}/output" 2>&1 || status=$?; probes=17 ;;
  esac
  expected_status=1
  case "${fixture_mode}" in first-line|import-ok) expected_status=0 ;; esac
  t_assert_eq "${expected_status}" "${status}"
  t_assert_eq "$((probes * 2))" "$(wc -l < "${WORK}/calls")" 'both images are probed for every item'
  t_assert_eq 'native image' "$(head -1 "${WORK}/calls" | cut -d'|' -f1)"
  t_assert_eq 'cross image' "$(sed -n '2p' "${WORK}/calls" | cut -d'|' -f1)"
  expected_command='gcc --version 2>&1'
  case "${fixture_mode}" in import-*) expected_command="${_VENV_ACTIVATE_PROLOGUE} python3 -c 'import torch; print(\"torch ok:\", torch.__version__ if hasattr(torch, \"__version__\") else \"loaded\")' 2>&1" ;; esac
  t_assert_eq "${expected_command}" "$(head -1 "${WORK}/calls" | cut -d'|' -f2-)" 'the image shell receives the original command bytes'
  case "${fixture_mode}" in
    first-line) t_assert_contains "$(cat "${WORK}/output")" 'PASS:All 17/17 version checks match' ;;
    empty) t_assert_contains "$(cat "${WORK}/output")" 'version checks read NOTHING from either image' ;;
    different) t_assert_contains "$(cat "${WORK}/output")" 'FAIL:17/17 version checks differ' ;;
    import-ok) t_assert_contains "$(cat "${WORK}/output")" 'PASS:All 6 Python imports succeed in both images' ;;
    import-both-fail) t_assert_contains "$(cat "${WORK}/output")" 'FAIL:12 Python imports failed'; t_assert_contains "$(cat "${WORK}/output")" 'FAILED (rc=23): last diagnostic' ;;
    import-native-fail) t_assert_contains "$(cat "${WORK}/output")" 'FAIL:6 Python imports failed'; t_assert_contains "$(cat "${WORK}/output")" 'FAILED (rc=29): last diagnostic' ;;
    import-cross-fail) t_assert_contains "$(cat "${WORK}/output")" 'FAIL:6 Python imports failed'; t_assert_contains "$(cat "${WORK}/output")" 'FAILED (rc=31): last diagnostic' ;;
  esac
done
for function in check_versions check_imports container_exec_strip echo_header pass fail verify_file_exists verify_shared_lib fail_check pass_check; do
  declare -f "${function}"
done > "${WORK}/worker"
t_emit_optional_functions verify_file_nonempty _parity_probe_pair _parity_result >> "${WORK}/worker"
cat >> "${WORK}/worker" <<'WORKER'
FAILURES=0
trap 'printf "EXIT-FAILURES=%s\n" "${FAILURES}"' EXIT
case "$1" in
  file) verify_file_exists "$2" fixture ;;
  shared) verify_shared_lib "$2" libfixture.so fixture ;;
  *) "$1" ;;
esac
printf 'REACHED\n'
WORKER
for fixture_mode in first-line empty import-ok import-cross-fail; do
  t_case "standalone errexit parity: ${fixture_mode}"
  probe=check_versions; case "${fixture_mode}" in import-*) probe=check_imports ;; esac
  status=0
  env WORK="${WORK}" fixture_mode="${fixture_mode}" bash -euo pipefail "${WORK}/worker" "${probe}" > "${WORK}/output" 2>&1 || status=$?
  expected=0; case "${fixture_mode}" in empty|import-cross-fail) expected=1 ;; esac
  t_assert_eq "${expected}" "${status}"
  if [ "${expected}" = 0 ]; then t_assert_contains "$(cat "${WORK}/output")" REACHED; fi
  t_assert_contains "$(cat "${WORK}/output")" EXIT-FAILURES=0
done
for probe in file shared; do
  t_case "standalone errexit artifact: ${probe} empty"
  rm -rf "${WORK}/artifacts"; mkdir -p "${WORK}/artifacts"; : > "${WORK}/artifacts/libfixture.so"
  path="${WORK}/artifacts/libfixture.so"; [ "${probe}" != shared ] || path="${WORK}/artifacts"
  status=0
  bash -euo pipefail "${WORK}/worker" "${probe}" "${path}" > "${WORK}/output" 2>&1 || status=$?
  t_assert_eq 1 "${status}"
  t_assert_contains "$(cat "${WORK}/output")" 'fixture is empty:'
  t_assert_contains "$(cat "${WORK}/output")" EXIT-FAILURES=1
done
t_summary
