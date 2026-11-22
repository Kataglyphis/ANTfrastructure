#!/usr/bin/env bash
# Stubbed cache updates test publication and raw failures; actual ELF selection belongs to image replay.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_private_tmpdir
work="$(t_mktemp -d)"
helper="${TESTS_DIR}/../06-packaging/llvm-loader-path.sh"
before="$-"
# shellcheck source=../06-packaging/llvm-loader-path.sh
source "${helper}"
t_assert_eq "${before}" "$-" 'sourcing the publisher preserves shell options'
LLVM_CONF_FILE="${work}/loader conf"
LLVM_CONF_TRACE="${work}/trace"
ldconfig() {
  cat "${LLVM_CONF_FILE}" > "${LLVM_CONF_TRACE}"
  return "${loader_status}"
}
t_case "default runtime and explicit native prefixes retain exact bytes"
for prefix in '' "${work}/native LLVM"; do
  loader_status=0
  t_assert_ok publish_llvm_target_ld_path "${prefix}" "${LLVM_CONF_FILE}"
  t_assert_eq "${prefix:-/usr/local/llvm-target}/lib" "$(cat "${LLVM_CONF_FILE}")"
  t_assert_eq "$(cat "${LLVM_CONF_FILE}")" "$(cat "${LLVM_CONF_TRACE}")"
done
t_case "conditional callers retain ldconfig failure"
loader_status=47
status=0
publish_llvm_target_ld_path /fixture "${LLVM_CONF_FILE}" || status=$?
t_assert_eq 47 "${status}"
t_case "failed config writes never call ldconfig"
: > "${LLVM_CONF_TRACE}"
status=0
publish_llvm_target_ld_path /fixture "${work}/missing/config" 2>/dev/null || status=$?
t_assert_eq 1 "${status}"
t_assert_eq '' "$(cat "${LLVM_CONF_TRACE}")"

t_case "native and runtime consumers carry the shared owner"
while IFS='|' read -r relative needle; do
  t_assert_contains "$(cat "${TESTS_DIR}/${relative}")" "${needle}"
done <<'WIRING'
../../Dockerfile.toolchain|publish_llvm_target_ld_path "/opt/llvm-target-${TARGETARCH}" /etc/ld.so.conf.d/000-llvm-native.conf
../../Dockerfile.toolchain|linux/scripts/06-packaging/llvm-loader-path.sh
../../Dockerfile.package|linux/scripts/06-packaging/llvm-loader-path.sh
../06-packaging/copy-media-payloads.sh|/llvm-loader-path.sh"
../06-packaging/copy-media-payloads.sh|declare -F publish_llvm_target_ld_path
WIRING
t_summary
