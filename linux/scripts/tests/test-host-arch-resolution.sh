#!/usr/bin/env bash
# Stubbed platform probes cover precedence and failure handling, not host package configuration.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# shellcheck source=../01-core/platform.sh
source "${1:-${TESTS_DIR}/../01-core/platform.sh}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

_arch_resolution_case() {
  local action="$1" argument="$2" expected="$3" expected_calls="$4" actual
  local probe_log="$work/probes"
  : > "$probe_log"
  command() {
    if [ "$1" = -v ] && [ "$2" = dpkg ] && [ "$dpkg_available" = no ]; then return 1; fi
    builtin command "$@"
  }
  dpkg() { printf 'dpkg\n' >> "$probe_log"; printf '%s' "$dpkg_output"; return "$dpkg_status"; }
  uname() { printf 'uname\n' >> "$probe_log"; printf '%s' "$uname_output"; return "$uname_status"; }
  actual="$("$action" "$argument")"
  t_assert_eq "$expected" "$actual" "$action keeps its precedence and raw/normalized result"
  t_assert_eq "$expected_calls" "$(tr '\n' ',' < "$probe_log")" 'higher-priority values prevent host probing'
  unset -f command dpkg uname
}

while IFS='|' read -r scenario argument target build build_platform dpkg_available dpkg_status dpkg_output uname_status uname_output target_expected build_expected target_calls build_calls; do
  t_case "$scenario"
  unset TARGET_ARCH TARGETARCH BUILDARCH BUILDPLATFORM
  export TARGETARCH="$target" BUILDARCH="$build" BUILDPLATFORM="$build_platform"
  _arch_resolution_case canonical_resolve_arch "$argument" "$target_expected" "$target_calls"
  _arch_resolution_case _platform_raw_build_arch '' "$build_expected" "$build_calls"
done <<'CASES'
argument|custom|arm64|riscv64|linux/amd64|yes|0|amd64|0|x86_64|custom|riscv64||
target override||aarch64||linux/riscv64|yes|0|amd64|0|x86_64|aarch64|riscv64||
build override|||x86_64|linux/arm64|yes|0|amd64|0|aarch64|amd64|x86_64|dpkg,|
dpkg|||||yes|0|arm64|0|x86_64|arm64|arm64|dpkg,|dpkg,
missing dpkg|||||no|0|ignored|0|aarch64|aarch64|aarch64|uname,|uname,
failed dpkg|||||yes|1||0|riscv64|riscv64|riscv64|dpkg,uname,|dpkg,uname,
partial failed dpkg|||||yes|1|partial|0|ignored|partial|partial|dpkg,|dpkg,
empty dpkg|||||yes|0||0|x86_64|x86_64|x86_64|dpkg,uname,|dpkg,uname,
failed uname|||||no|0||1||unknown|unknown|uname,|uname,
empty uname|||||no|0||0||||uname,|uname,
trailing platform slash||||linux/|yes|0|arm64|0|x86_64|arm64|arm64|dpkg,|dpkg,
CASES

t_case 'public architecture wrappers normalize the selected raw values'
TARGETARCH=aarch64 BUILDARCH=x86_64
export TARGETARCH BUILDARCH
t_assert_eq arm64 "$(canonical_target_arch)"
t_assert_eq amd64 "$(build_arch_oci)"
t_summary
