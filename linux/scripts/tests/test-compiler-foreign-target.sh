#!/usr/bin/env bash
# Stubbed target probes cover libstdc++ guard policy; no real symlink or library is modified.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cross-toolchain-fixture.sh
source "${TESTS_DIR}/cross-toolchain-fixture.sh"
_work=''
cross_toolchain_fixture_init _work compiler-resolution.sh "${1:-}" || exit 1

default_target_arch() { printf '%s' "$1"; }
build_arch_oci() {
  printf 'build\n' >> "$_work/trace"
  if [[ "$_build_status" != 0 ]]; then printf 'host lookup failed\n' >&2; return "$_build_status"; fi
  printf '%s' "$_build_arch"
}
arch_deb_multiarch_triplet_for() {
  printf 'triplet:%s\n' "$1" >> "$_work/trace"
  printf '__ant_fixture_missing_triplet__'
  return 1
}
gcc_toolchain_prefix() { printf '%s' "$_work/missing-gcc"; }
_target_gcc_libstdcxx() { printf 'runtime:%s\n' "$*" >> "$_work/trace"; }
ln() { printf '%s\n' "$*" >> "$_work/links"; }

_run_guard_case() {
  _rc=0
  "$@" > "$_work/output" 2>&1 || _rc=$?
}

while IFS='|' read -r target _build_arch _build_status expected host_calls; do
  for fn in fix_libstdcxx_symlink pin_target_libstdcxx; do
    t_case "$fn target=[$target] host=$_build_arch status=$_build_status"
    : > "$_work/trace"
    : > "$_work/links"
    _run_guard_case "$fn" "$target"
    t_assert_eq 0 "$_rc"
    t_assert_eq "$expected" "$(grep '^triplet:' "$_work/trace" || true)"
    t_assert_eq "$host_calls" "$(grep -c '^build$' "$_work/trace" || true)"
    t_assert_eq '' "$(cat "$_work/links")" 'these guard fixtures must never request a symlink write'
    t_assert_eq '' "$(cat "$_work/output")" 'host probe diagnostics stay suppressed'
  done
done <<'CASES'
|amd64|0||0
amd64|amd64|0||1
arm64|amd64|0|triplet:arm64|1
arm64|arm64|0||1
amd64|arm64|0|triplet:amd64|1
aarch64|arm64|0|triplet:aarch64|1
amd64|ignored|4||1
arm64|ignored|4|triplet:arm64|1
CASES

for fn in fix_libstdcxx_symlink pin_target_libstdcxx; do
  t_case "$fn preserves an unconditional target-resolution failure under errexit"
  _run_guard_case bash -c 'set -e
source "$1"
default_target_arch() { return 19; }
ln() { exit 87; }
"$2" arm64
printf survived
' _ "$_CROSS_TOOLCHAIN_FIXTURE_MODULE" "$fn"
  t_assert_eq 19 "$_rc"
  t_assert_eq '' "$(cat "$_work/output")"
done

t_summary
