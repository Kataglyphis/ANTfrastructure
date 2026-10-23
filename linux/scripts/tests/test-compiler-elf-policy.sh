#!/usr/bin/env bash
# Stubbed compiler and readelf metadata cover header/status policy, not compiler execution, ABI validation or image contents.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
VALIDATOR="${1:-${TESTS_DIR}/../06-packaging/validate-compilers.sh}"
RECEIPT="${2:-}"
[ -z "$RECEIPT" ] || : > "$RECEIPT"
_compiler_elf_case() {
  local caller="$1" mode="$2" fixture="$4" output status=0 expected_errors=0 errors expected_machine
  mkdir -p "$fixture/gcc/bin"
  cat > "$fixture/gcc/bin/gcc" <<'GCC'
#!/bin/sh
case "$1/$MODE" in --version/version) printf 'fixture version\n' ;; -dumpmachine/triple) printf 'aarch64-linux-gnu\n' ;; *) printf 'different version\n' ;; esac
GCC
  chmod +x "$fixture/gcc/bin/gcc"
  cat > "$fixture/worker.sh" <<'WORKER'
set -euo pipefail
source "$1"
validator="$2"; fixture="$3"; caller="$4"; export MODE="$5"
t_source_functions "$validator" validate_fail _artifact_source_check_host_gcc _artifact_source_check_swapped_gcc _artifact_source_check_target_elf
for fn in _vc_elf_machine_header _vc_elf_header_matches; do
  if grep -q "^${fn}() {" "$validator"; then t_source_functions "$validator" "$fn"; fi
done
readelf() {
  printf '%s/%s\n' "${LC_ALL:-}" "$*" >> "$fixture/trace"
  case "$MODE" in
    empty|absent) : ;;
    mismatch) printf '  Machine: Wrong machine\n' ;;
    *) printf '  Machine: aArCh64\n' ;;
  esac
  case "$MODE" in failed) return 13 ;; absent) return 127 ;; esac
  return 0
}
arch_to_elf_machine() { if [ "$MODE" = unknown ]; then return 1; fi; printf AArch64; }
arch_deb_multiarch_triplet_for() { printf aarch64-linux-gnu; }
_VALIDATE_ERRORS=0
_VCS_TARGET_ARCH=arm64 _VCS_GCC_PREFIX="$fixture/gcc" GCC_VERSION=fixture
case "$caller" in
  host) _artifact_source_check_host_gcc ;;
  swapped) _artifact_source_check_swapped_gcc arm64 "$fixture/gcc" "$fixture/native" ;;
  target) _artifact_source_check_target_elf "$fixture/gcc/bin/gcc" 'target compiler' target 'wrong version' ;;
esac
printf 'ERRORS=%s\n' "$_VALIDATE_ERRORS"
WORKER
  t_case "$caller ELF policy $mode"
  t_capture_command output status t_run_fixture_worker "$fixture/worker.sh" "$VALIDATOR" "$fixture" "$caller" "$mode"
  case "$mode" in empty|mismatch|absent) expected_errors=1 ;; failed) [ "$caller" != host ] || expected_errors=1 ;; unknown) [ "$caller" = host ] || expected_errors=1 ;; esac
  errors="${output##*ERRORS=}"
  t_assert_eq 0 "$status"
  t_assert_eq "$expected_errors" "$errors"
  if [ "$expected_errors" = 1 ]; then t_assert_contains "$output" 'COMPILER FAIL ['; else t_assert_contains "$output" 'OK:'; fi
  case "$caller/$mode" in
    host/version|host/empty|host/absent|host/failed|swapped/empty|swapped/mismatch|swapped/unknown|swapped/absent|swapped/triple|target/empty|target/absent) : ;;
    *)
      expected_machine=aArCh64
      [ "$mode" != mismatch ] || expected_machine='Wrong machine'
      t_assert_contains "$output" "  Machine: $expected_machine" 'the raw header retains its label and indentation' ;;
  esac
  t_record_fixture_receipt "$RECEIPT" "$caller/$mode" "$status" "${output//${fixture}/FIXTURE}" "$(if [ -f "$fixture/trace" ]; then sed "s|$fixture|FIXTURE|g" "$fixture/trace"; fi)"
}
for caller in host swapped target; do
  for mode in version match mismatch empty failed unknown triple absent; do
    _t_probe_file _compiler_elf_case "$caller" "$mode"
  done
done
t_summary
