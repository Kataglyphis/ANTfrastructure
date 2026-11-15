#!/usr/bin/env bash
# Stubbed phases prove ordering and raw/fatal/advisory policies, not media builds or interpreter imports.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
subject="${1:-${TESTS_DIR}/../03-media/runtime/finalize-media.sh}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
cat > "${work}/environment.sh" <<'ENVIRONMENT'
source() {
  [ "$1" = /opt/scripts/03-media/runtime/media-env.sh ] || return 31
  printf 'env\n' >> "${TRACE}"
  return "${FINAL_ENV_RC}"
}
bash() {
  local stage="${1##*/}${2:+ $2}"
  printf '%s\n' "${stage}" >> "${TRACE}"
  if [ "${stage}" = smoke-media.sh ]; then printf '%s' "${PYTHONPATH}" > "${TRACE}.pythonpath"; fi
  if [ "${stage}" = "${FINAL_FAIL_STAGE}" ]; then return 17; fi
  return 0
}
uv() { printf 'uv\n' >> "${TRACE}"; [ "$*" = 'pip install --no-deps /opt/wheels/*.whl' ] || return 32; return "${FINAL_UV_RC}"; }
echo() {
  case "${1:-}" in
    /opt/opencv5/lib/python*/site-packages) printf /fixture/opencv ;;
    *) builtin echo "$@" ;;
  esac
}
ENVIRONMENT
stages=(env collect-artifacts.sh install-deps.sh configure-runtime.sh repair-wheels.sh verify-wheels.sh
        'repair-wheels.sh --free-threaded' 'verify-wheels.sh --free-threaded' free-threaded-store.sh uv validate-media-runtime.sh smoke-media.sh)
_run() {
  : > "${work}/trace"
  status=0
  env BASH_ENV="${work}/environment.sh" TRACE="${work}/trace" TARGET_ARCH="$1" FINAL_FAIL_STAGE="$2" \
    FINAL_UV_RC="${3:-0}" FINAL_ENV_RC="${4:-0}" PYTHONPATH=/fixture/caller bash "${subject}" \
    > "${work}/output" 2>&1 || status=$?
}
t_case 'all phases run once in their original order, retaining the caller Python path'
_run amd64 ''
t_assert_eq 0 "${status}"
t_assert_eq "$(printf '%s\n' "${stages[@]}")" "$(cat "${work}/trace")"
t_assert_eq /fixture/opencv:/fixture/caller "$(cat "${work}/trace.pythonpath")"
t_case 'every selected Bash phase preserves failure and stops later phases'
for index in 1 2 3 4 5 6 7 8 10 11; do
  _run amd64 "${stages[index]}"
  t_assert_eq 17 "${status}" "${stages[index]} retains raw failure"
  t_assert_eq "$(printf '%s\n' "${stages[@]:0:index+1}")" "$(cat "${work}/trace")"
done
t_case 'failed environment setup stops before collection'
_run amd64 '' 0 19
t_assert_eq 19 "${status}"
t_assert_eq env "$(cat "${work}/trace")"
t_case 'native wheel installation failures remain fatal, including the default architecture'
for arch in '' amd64; do
  _run "${arch}" '' 23
  t_assert_eq 1 "${status}"
  t_assert_eq "$(printf '%s\n' "${stages[@]:0:10}")" "$(cat "${work}/trace")"
  t_assert_contains "$(cat "${work}/output")" 'native wheels must install'
done
t_case 'foreign wheel installation remains advisory and still reaches final validation'
for arch in arm64 riscv64; do
  _run "${arch}" '' 23
  t_assert_eq 0 "${status}"
  t_assert_eq "$(printf '%s\n' "${stages[@]}")" "$(cat "${work}/trace")"
  t_assert_contains "$(cat "${work}/output")" "tolerated for cross-arch ${arch} wheels"
done
t_assert_contains "$(cat "${TESTS_DIR}/../../Dockerfile.media")" 'bash /opt/scripts/03-media/runtime/finalize-media.sh'
t_summary
