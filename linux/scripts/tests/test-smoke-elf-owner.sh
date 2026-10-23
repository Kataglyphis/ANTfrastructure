#!/usr/bin/env bash
# Stubbed readelf receipts cover parser ownership, status and caller state, not executing compilers or foreign binaries.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SMOKE="${1:-${TESTS_DIR}/../06-packaging/smoke-common.sh}"
RECEIPT="${2:-}"
[ -z "$RECEIPT" ] || : > "$RECEIPT"
_smoke_elf_owner_case() {
  local mode="$1" fixture="$3" output status=0 expected expected_status=0 expected_trace expected_calls=0 actual_trace
  mkdir -p "$fixture/packaging" "$fixture/01-core" "$fixture/installed"
  sed "s|/opt/scripts/core|$fixture/installed|g" "$SMOKE" > "$fixture/packaging/smoke-common.sh"
  cp "$TESTS_DIR/../01-core/platform.sh" "$fixture/01-core/platform.sh"
  touch "$fixture/input with spaces"
  cat > "$fixture/worker.sh" <<'WORKER'
set -uo pipefail
fixture="$2"; mode="$3"
source "$fixture/packaging/smoke-common.sh"
set +e
readelf() {
  printf 'locale=%s args=%s\n' "${LC_ALL:-}" "$*" >> "$fixture/trace"
  case "$mode" in
    empty) printf 'other metadata\n' ;;
    multiple) printf ' Machine: First machine\n Machine: Second machine\n' ;;
    failed) printf ' Machine: AArch64  \n'; return 13 ;;
    *) printf ' Machine: AArch64  \n' ;;
  esac
}
command() {
  if [ "$mode" = absent ] && [ "$*" = '-v readelf' ]; then return 1; fi
  builtin command "$@"
}
calls=0
if [ "$mode" = override ]; then elf_machine_name() { calls=$((calls + 1)); printf 'override bytes'; return 7; }; fi
input="$fixture/input with spaces"
[ "$mode" != missing-file ] || input="$fixture/missing"
rc=0
smoke_elf_machine_of "$input" > "$fixture/output" 2> "$fixture/error" || rc=$?
printf 'STATUS=%s CALLS=%s PLATFORM=%s ARCH=%s\n' "$rc" "$calls" "${_PLATFORM_SH_LOADED:-absent}" "$(if command -v arch_normalize >/dev/null; then printf present; else printf absent; fi)"
WORKER
  t_case "ELF owner ${mode}"
  t_capture_command output status t_run_fixture_worker "$fixture/worker.sh" "$fixture" "$mode"
  expected='AArch64  '; expected_trace="locale=C args=-h $fixture/input with spaces"
  case "$mode" in
    empty) expected='' ;;
    multiple) expected='First machine' ;;
    failed) expected_status=13 ;;
    absent|missing-file) expected=''; expected_status=1; expected_trace='' ;;
    override) expected='override bytes'; expected_status=7; expected_trace=''; expected_calls=1 ;;
  esac
  t_assert_eq 0 "$status"
  t_assert_eq "STATUS=$expected_status CALLS=$expected_calls PLATFORM=absent ARCH=absent" "$output"
  t_assert_eq "$expected" "$(cat "$fixture/output")"
  t_assert_eq '' "$(cat "$fixture/error")"
  actual_trace=''; [ ! -f "$fixture/trace" ] || actual_trace="$(cat "$fixture/trace")"
  t_assert_eq "$expected_trace" "$actual_trace"
  t_record_fixture_receipt "$RECEIPT" "$mode" "$output" "$(cat "$fixture/output")" "${actual_trace//${fixture}/FIXTURE}"
}
for mode in normal empty multiple failed absent missing-file override; do _t_probe_file _smoke_elf_owner_case "$mode"; done

t_case 'toolchain smoke ships its platform parser companion'
t_assert_ok grep -qE '^COPY --chmod=755 linux/scripts/01-core/( /opt/scripts/core/|platform\.sh /opt/scripts/core/platform\.sh)$' "$TESTS_DIR/../../Dockerfile.toolchain"
t_summary
