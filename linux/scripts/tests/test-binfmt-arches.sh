#!/usr/bin/env bash
# Isolated CSV and caller fixtures cover state and failure policies, not real namespaces, services, downloads or emulator execution.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/stream-receipt-fixture.sh"
receipt=''
t_stream_workspace WORK receipt "${2:-}"
subject="${1:-$TESTS_DIR/../setup-rootless-binfmt.sh}"
mode="${3:-current}"
if [ "$mode" = original ]; then
  printf '_binfmt_read_arches() {\n' > "$WORK/functions.sh"
  awk '/^  IFS=.*,.*read -ra _arr/ { print; exit }' "$subject" >> "$WORK/functions.sh"
  printf '}\n' >> "$WORK/functions.sh"
else
  t_fn_src "$subject" _binfmt_read_arches > "$WORK/functions.sh" || exit 1
fi
for name in extract_emulators register verify elf_magic_for; do t_fn_src "$subject" "$name"; done >> "$WORK/functions.sh"
awk '/^qemu_bin_for\(\)|^elf_mask\(\)/ {print}' "$subject" >> "$WORK/functions.sh"

cat > "$WORK/worker.sh" <<'WORKER'
set -u
harness="$1" root="$2" operation="$3" ARCHES="$4" ifs_mode="$5" scope="$6" strict="$7" context="$8" ns_status="$9"
source "${harness%/*}/shell-context-fixture.sh"
source "${harness%/*}/stream-receipt-fixture.sh"
source "$root/functions.sh"
cd "$root" || exit 1
QDIR='emulators with spaces'
FORCE=0
_arr=(global seed)
case "$ifs_mode" in unset) unset IFS ;; custom) IFS=':;' ;; default) IFS=$' \t\n' ;; esac
dump_state() {
  if [ "${IFS+x}" = x ]; then printf 'set:%s' "$IFS" > ifs; else printf unset > ifs; fi
  printf '%s\n' "${#_arr[@]}" > count
  : > array
  if [ "${#_arr[@]}" -gt 0 ]; then printf '%s\0' "${_arr[@]}" > array; fi
}
trap dump_state EXIT
_qemu_usable() { printf 'usable:<%s>\n' "$1" >> trace; return 0; }
containerd-rootless-setuptool.sh() {
  printf 'namespace' >> trace
  printf '<%s>' "$@" >> trace
  printf '\n' >> trace
  return "$ns_status"
}
_binfmt_parse() {
  if [ "$scope" = local ]; then local -a _arr=(local seed); fi
  if [ "$scope" = readonly ]; then readonly -a _arr; fi
  _binfmt_read_arches
  parse_status=$?
  dump_state
  cp array parsed-array
  cp count parsed-count
  return "$parse_status"
}
_binfmt_extract() { extract_emulators; }
_binfmt_register() { register; }
_binfmt_verify() { verify; }
t_stream_run_worker "$context" "$strict" status "_binfmt_${operation}" returned
exit "$status"
WORKER

_binfmt_parse_case() {
  local csv="$1" ifs_mode="$2" scope="$3" strict="$4" context="$5" status=0
  shift 5
  local -a expected_items=("$@")
  t_case "CSV $csv $ifs_mode $scope $strict $context"
  t_stream_capture status "$WORK" "$WORK/worker.sh" "$WORK" parse "$csv" "$ifs_mode" "$scope" "$strict" "$context" 0
  t_assert_eq 0 "$status"
  : > "$WORK/expected.array"
  if [ "${#expected_items[@]}" -gt 0 ]; then printf '%s\0' "${expected_items[@]}" > "$WORK/expected.array"; fi
  t_assert_eq "${#expected_items[@]}" "$(cat "$WORK/parsed-count")"
  t_assert_eq "$(t_stream_hex "$WORK/expected.array")" "$(t_stream_hex "$WORK/parsed-array")"
  case "$ifs_mode" in unset) printf unset ;; custom) printf 'set::;' ;; default) printf 'set: \t\n' ;; esac > "$WORK/expected.ifs"
  t_stream_assert_files "$WORK" ifs
  if [ "$scope" = local ]; then
    printf 'global\0seed\0' > "$WORK/expected.array"
  fi
  t_stream_assert_files "$WORK" array
  t_stream_assert_return "$WORK" 0
  t_stream_record "$receipt" "$WORK" 'array ifs parsed-array parsed-count' parse "$csv" "$ifs_mode" "$scope" "$strict" "$context" "$status"
}

_binfmt_csv_rows() {
  _binfmt_parse_case '' "$@"
  _binfmt_parse_case arm64 "$@" arm64
  _binfmt_parse_case 'arm64,riscv64,arm64,' "$@" arm64 riscv64 arm64
  _binfmt_parse_case ',arm64,,riscv64,,' "$@" '' arm64 '' riscv64 ''
  _binfmt_parse_case ' arm64 ,ris cv64' "$@" ' arm64 ' 'ris cv64'
  _binfmt_parse_case $'arm64\nriscv64,amd64' "$@" arm64
  _binfmt_parse_case $'\narm64' "$@"
  _binfmt_parse_case 'arm\64,*.so' "$@" 'arm\64' '*.so'
}

_binfmt_read_failure() {
  local strict="$1" context="$2" status=0 fatal=0
  t_case "readonly output $*"
  rm -f "$WORK/parsed-array" "$WORK/parsed-count"
  t_stream_capture status "$WORK" "$WORK/worker.sh" "$WORK" parse arm64 custom readonly "$strict" "$context" 0
  t_assert_eq 1 "$status"
  t_assert_contains "$(cat "$WORK/err")" '_arr: readonly variable'
  printf 'global\0seed\0' > "$WORK/expected.array"
  if [ "$strict" = strict ]; then fatal=1; printf 'set:,'; else printf 'set::;'; fi > "$WORK/expected.ifs"
  t_stream_assert_files "$WORK" array ifs
  t_stream_assert_return "$WORK" "$(t_stream_expected_return 1 "$context" "$strict" "$fatal")"
  t_stream_record "$receipt" "$WORK" 'array ifs' readonly "$@" "$status"
}

_binfmt_caller_row() {
  case "$1" in
    empty) csv=''; names=() ;;
    known) csv='arm64,riscv64'; names=(qemu-aarch64 qemu-riscv64) ;;
    duplicate) csv='arm64,arm64,'; names=(qemu-aarch64 qemu-aarch64) ;;
    newline) csv=$'riscv64\narm64'; names=(qemu-riscv64) ;;
    unknown) csv=mystery; names=('') ;;
    arm) csv=arm; names=(qemu-arm) ;;
  esac
}

_binfmt_caller_expected() {
  local operation="$1" scenario="$2" strict="$3" context="$4" ns_status="$5" qb
  expected=0 fatal=0
  : > "$WORK/expected.out"; : > "$WORK/expected.err"
  if [ "$operation:$scenario" = extract:unknown ]; then
    expected=2 fatal=1
    printf 'unsupported arch: mystery\n' > "$WORK/expected.err"
  elif [ "$strict:$context" = strict:direct ] && { [ "$scenario" = unknown ] || [ "$operation:$scenario" = register:arm ]; }; then
    expected=1
  elif [ "$operation" = extract ]; then
    printf '[extract] emulators already present in emulators with spaces (use --force to refresh)\n' > "$WORK/expected.out"
  elif [ "$operation" = register ]; then
    expected="$ns_status"
  else
    if [ "$ns_status" -ne 0 ] && [ "${#names[@]}" -gt 0 ]; then expected=1; fi
    for qb in "${names[@]}"; do
      if [ "$ns_status" -eq 0 ]; then printf '[verify] %s: enabled\n' "$qb" >> "$WORK/expected.out"
      else printf '[verify] %s: NOT registered\n' "$qb" >> "$WORK/expected.err"; fi
    done
  fi
}

_binfmt_namespace_assertions() {
  local count
  count="$(awk '/^namespace/ {n++} END {print n+0}' "$WORK/trace")"
  if [ "$operation" = register ] && { [ "$expected" -eq 0 ] || [ "$expected" -eq "$ns_status" ]; }; then
    t_assert_eq 1 "$count"
    t_assert_contains "$(cat "$WORK/trace")" 'namespace<nsenter><--><bash><-c><set -e'
  elif [ "$operation" = verify ] && { [ "$expected" != 1 ] || [ "$ns_status" != 0 ]; }; then
    t_assert_eq "${#names[@]}" "$count"
  else
    t_assert_eq 0 "$count"
  fi
}

_binfmt_caller_case() {
  local operation="$1" scenario="$2" strict="$3" context="$4" ns_status="$5" status=0 csv expected fatal
  local -a names
  _binfmt_caller_row "$scenario"
  _binfmt_caller_expected "$@"
  t_case "caller $*"
  t_stream_capture status "$WORK" "$WORK/worker.sh" "$WORK" "$operation" "$csv" custom global "$strict" "$context" "$ns_status"
  t_assert_eq "$expected" "$status"
  t_stream_assert_files "$WORK" out err
  t_stream_assert_return "$WORK" "$(t_stream_expected_return "$expected" "$context" "$strict" "$fatal")"
  _binfmt_namespace_assertions
  t_stream_record "$receipt" "$WORK" 'out err trace array ifs' "$@" "$status"
}

for strict in strict relaxed; do
  for context in direct conditional; do
    _binfmt_csv_rows custom global "$strict" "$context"
    _binfmt_parse_case 'arm64,,riscv64,' unset global "$strict" "$context" arm64 '' riscv64
    _binfmt_parse_case 'arm64,,riscv64,' default global "$strict" "$context" arm64 '' riscv64
    _binfmt_parse_case 'arm64,,riscv64,' custom local "$strict" "$context" arm64 '' riscv64
    _binfmt_read_failure "$strict" "$context"
    for operation in extract register verify; do
      for scenario in empty known duplicate newline unknown arm; do _binfmt_caller_case "$operation" "$scenario" "$strict" "$context" 0; done
    done
    _binfmt_caller_case register known "$strict" "$context" 17
    _binfmt_caller_case verify known "$strict" "$context" 17
  done
done
t_summary
