#!/usr/bin/env bash
# Fake compiler APIs prove slot publication and raw failures, not compilation or cache hits.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_private_tmpdir
work="$(t_mktemp -d)"
mkdir "${work}/core with spaces"
cat > "${work}/core with spaces/compiler-cache-utils.sh" <<'SH'
if [[ "${SETUP_MODE}" == import ]]; then return 37; fi
if [[ "${SETUP_MODE}" != cache-api ]]; then
  compiler_cache_guarded_launcher() {
    [[ "$1" == *'core with spaces' ]] || return 45
    if [[ "${SETUP_MODE}" == launcher ]]; then return 39; fi
    printf '/cache wrapper\n'
  }
fi
SH
cat > "${work}/core with spaces/cross-gcc.sh" <<'SH'
if [[ "${SETUP_MODE}" != gcc-api ]]; then
  gcc_toolchain_resolve_prefix() {
    if [[ "${SETUP_MODE}" == gcc ]]; then return 41; fi
    printf '/gcc with spaces\n'
  }
fi
SH
cat > "${work}/child.sh" <<'SH'
set -euo pipefail
source "$1"
launcher=old gcc_root=old
toolchain=(stale duplicate)
native_cxx_probe_setup "$2" launcher gcc_root toolchain
printf '%s\n' "${launcher}" "${gcc_root}" "${#toolchain[@]}" "${toolchain[0]}" "$3"
SH
for mode in good import cache-api gcc-api launcher gcc; do
  t_case "${mode}: shared compiler setup retains boundaries and raw failure"
  expected=0
  case "${mode}" in import) expected=37 ;; cache-api|gcc-api) expected=1 ;; launcher) expected=39 ;; gcc) expected=41 ;; esac
  report='' raw=125
  t_capture_command report raw env SETUP_MODE="${mode}" bash "${work}/child.sh" \
    "${TESTS_DIR}/../lib/native-cxx-probe.sh" "${work}/core with spaces" 'outer argument'
  t_assert_eq "${expected}" "${raw}"
  if [[ "${mode}" == good ]]; then
    t_assert_eq $'/cache wrapper\n/gcc with spaces\n1\n--gcc-toolchain=/gcc with spaces\nouter argument' "${report}"
  else
    t_assert_rc 1 bash -c '[[ "$1" == *"outer argument"* ]]' _ "${report}"
  fi
done
t_summary
