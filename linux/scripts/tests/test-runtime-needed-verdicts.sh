#!/usr/bin/env bash
# Extracted scans and reports cover selection, bytes, counters and resolver status, not live ELF lookup, apt repair or image contents.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test-harness.sh"
subject="${1:-${_T_SCRIPTS}/03-media/runtime/validate-media-runtime.sh}"
receipt="${2:-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for function_name in _vmr_collect_missing _vmr_report_missing; do
  if grep -q "^${function_name}()" "$subject"; then t_source_functions "$subject" "$function_name"; fi
done
t_source_functions "$subject" find_missing_needed scan_plugin_directory
mkdir -p "$work/plugins" "$work/empty" "$work/bin" "$work/plugins/directory.so"
printf binary > "$work/bin/tool"
printf library > "$work/plugins/a.so"
printf library > "$work/plugins/ignored.so.1"
ln -s a.so "$work/plugins/link.so"
ln -s missing "$work/plugins/dangling.so"
ln -s missing "$work/bin/dangling"
LIB_DIRS=('/first dir' /second /second)
elf_unresolved_needed() {
  printf '<%s>\n' "$@" >> "$work/trace"
  case "$resolver_mode" in
    full|partial) printf 'libfirst.so\n\nlibdup.so\nlibdup.so\n' ;;
    unterminated) printf 'libfirst.so\nlast.so' ;;
    whitespace) printf ' \nlib\\literal.so\n' ;;
  esac
  case "$resolver_mode" in partial|empty-failure) return 7 ;; esac
  return 0
}
vmr_bytes() { sed "s|$work|@ROOT@|g" "$1" | od -An -v -tx1 | tr -d ' \n'; }
for scan in binary plugins; do
  for resolver_mode in full partial empty empty-failure unterminated whitespace; do
    t_case "$scan $resolver_mode preserves selected paths, names and both streams"
    : > "$work/trace"; : > "$work/expected-out"; : > "$work/expected-err"; : > "$work/expected-trace"
    names=()
    case "$resolver_mode" in
      full|partial) names=(libfirst.so libdup.so libdup.so) ;;
      unterminated) names=(libfirst.so) ;;
      whitespace) names=(' ' 'lib\literal.so') ;;
    esac
    paths=("$work/bin/tool")
    if [ "$scan" = plugins ]; then paths=("$work/plugins/a.so" "$work/plugins/link.so"); fi
    for path in "${paths[@]}"; do
      printf '<%s>\n' "$path" "${LIB_DIRS[@]}" >> "$work/expected-trace"
      if [ "${#names[@]}" -gt 0 ]; then printf '%s\n' "${names[@]}" >> "$work/expected-out"; fi
    done
    if [ "$scan" = binary ]; then
      printf 'Checking: %s\n' "${paths[0]}" > "$work/expected-err"
      for name in "${names[@]}"; do printf '  MISSING: %s\n' "$name" >> "$work/expected-err"; done
      status=0; find_missing_needed "${paths[0]}" > "$work/out" 2> "$work/err" || status=$?
    else
      printf 'Scanning plugins in: %s\n' "$work/plugins" > "$work/expected-err"
      if [ "${#names[@]}" -gt 0 ]; then printf '%s\n' 'Some plugins have missing deps:' "${names[@]}" "${names[@]}" >> "$work/expected-err"; fi
      status=0; scan_plugin_directory "$work/plugins" > "$work/out" 2> "$work/err" || status=$?
    fi
    t_assert_eq 0 "$status"
    t_assert_rc 0 cmp "$work/expected-out" "$work/out"
    t_assert_rc 0 cmp "$work/expected-err" "$work/err"
    t_assert_rc 0 cmp "$work/expected-trace" "$work/trace"
    t_record_fixture_receipt "$receipt" scan "$scan" "$resolver_mode" "$status" "$(vmr_bytes "$work/out")" "$(vmr_bytes "$work/err")" "$(vmr_bytes "$work/trace")"
  done
done
for shape in missing directory dangling; do
  t_case "$shape binary retains the original -f or -L policy"
  : > "$work/trace"; resolver_mode=full
  path="$work/bin/missing"; [ "$shape" != directory ] || path="$work/bin"
  [ "$shape" != dangling ] || path="$work/bin/dangling"
  status=0; find_missing_needed "$path" > "$work/out" 2> "$work/err" || status=$?
  t_assert_eq 0 "$status"
  if [ "$shape" = dangling ]; then
    t_assert_eq 4 "$(wc -l < "$work/trace" | tr -d ' ')"
    t_assert_eq $'libfirst.so\nlibdup.so\nlibdup.so' "$(cat "$work/out")"
  else
    t_assert_eq '' "$(cat "$work/trace")"
    t_assert_eq "WARNING: $path not found, skipping" "$(cat "$work/err")"
  fi
  t_record_fixture_receipt "$receipt" shape "$shape" "$status" "$(vmr_bytes "$work/out")" "$(vmr_bytes "$work/err")" "$(vmr_bytes "$work/trace")"
done
t_case 'an absent or empty plugin directory never invokes the resolver'
: > "$work/trace"
scan_plugin_directory "$work/missing" > "$work/out" 2> "$work/err"
t_assert_eq '' "$(cat "$work/out")$(cat "$work/err")"
scan_plugin_directory "$work/empty" > "$work/out" 2> "$work/err"
t_assert_eq '' "$(cat "$work/out")$(cat "$work/trace")"
t_assert_eq "Scanning plugins in: $work/empty" "$(cat "$work/err")"
t_case 'failed resolver status remains advisory under active errexit'
{
  printf 'set -euo pipefail\nwork=$1\nresolver_mode=partial\nLIB_DIRS=("/first dir" /second /second)\n'
  t_emit_optional_functions _vmr_collect_missing find_missing_needed scan_plugin_directory elf_unresolved_needed
  printf 'find_missing_needed "$work/bin/tool"\nscan_plugin_directory "$work/plugins"\n'
} > "$work/direct.sh"
status=0; bash "$work/direct.sh" "$work" > "$work/out" 2> "$work/err" || status=$?
t_assert_eq 0 "$status"
printf '%s\n' libfirst.so libdup.so libdup.so libfirst.so libdup.so libdup.so libfirst.so libdup.so libdup.so > "$work/expected-direct"
t_assert_rc 0 cmp "$work/expected-direct" "$work/out"
t_record_fixture_receipt "$receipt" direct "$status" "$(vmr_bytes "$work/out")" "$(vmr_bytes "$work/err")"
python3 - "$subject" "$work/reports.sh" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
blocks=[]
for name, marker, end in (
    ('remaining_report', '  if [ ${#UNIQ_REMAINING[@]}', '\n  fi'),
    ('unmapped_report', 'if [ ${#STILL_MISSING[@]}', '\nfi'),
    ('denied_report', 'if [ ${#DENIED_MISSING[@]}', '\nfi')):
    start=source.index(marker)
    stop=source.index(end,start)+len(end)
    blocks.append(name+'() {\n'+source[start:stop]+'\n}\n')
blocks.append('final_verdict() {\n'+source[source.index('ort_dpkg_gate || exit 1'):]+ '\n}\n')
Path(sys.argv[2]).write_text(''.join(blocks))
PY
source "$work/reports.sh"
for kind in remaining unmapped denied; do
  for state in empty present; do
    t_case "$kind $state retains complete summary bytes and denial counter publication"
    UNIQ_REMAINING=(); STILL_MISSING=(); DENIED_MISSING=(); _VMR_DENIED_FAILURES=42
    names=(libone.so libtwo.so libone.so)
    if [ "$state" = present ]; then UNIQ_REMAINING=("${names[@]}"); STILL_MISSING=("${names[@]}"); DENIED_MISSING=("${names[@]}"); fi
    expected=''
    case "$kind:$state" in
      remaining:empty) expected='All dependencies resolved after package install.' ;;
      remaining:present) expected=$'\n=== WARNING: 3 dependencies still unresolved ===\n  libone.so\n  libtwo.so\n  libone.so\n\nThese libraries could not be found in any apt package. The artifacts\nthat depend on them (and the plugins that load them) will fail at\nruntime. Review the build configuration or add package mappings\nto so-package-map.txt (next to validate-media-runtime.sh).' ;;
      unmapped:present) expected=$'\n=== WARNING: 3 dependencies have no known apt package ===\n  libone.so\n  libtwo.so\n  libone.so\nAdd entries to so-package-map.txt (next to validate-media-runtime.sh).' ;;
      denied:present) expected=$'\n=== FAIL: 3 source-built dependencies unresolved (apt repair denied) ===\n  libone.so\n  libtwo.so\n  libone.so\nThese ship from this repo\'s own build; a miss means the builder did not\ninstall the SONAME link. Fix the builder — do NOT map them to a distro\npackage, which is what silently downgraded ONNX Runtime before 2026-08-28.' ;;
    esac
    : > "$work/expected-out"; [ -z "$expected" ] || printf '%s\n' "$expected" > "$work/expected-out"
    "${kind}_report" > "$work/out" 2> "$work/err"
    t_assert_rc 0 cmp "$work/expected-out" "$work/out"
    t_assert_eq '' "$(cat "$work/err")"
    count=42; [ "$kind:$state" != denied:present ] || count=3
    t_assert_eq "$count" "$_VMR_DENIED_FAILURES"
    t_record_fixture_receipt "$receipt" report "$kind" "$state" "$_VMR_DENIED_FAILURES" "${UNIQ_REMAINING[*]}" "${STILL_MISSING[*]}" "${DENIED_MISSING[*]}" "$(vmr_bytes "$work/out")" "$(vmr_bytes "$work/err")"
  done
done
ort_dpkg_gate() { printf called >> "$work/dpkg"; return "$dpkg_status"; }
for dpkg_status in 0 9; do
  for _VMR_DENIED_FAILURES in 0 3; do
    t_case "final verdict dpkg=$dpkg_status denied=$_VMR_DENIED_FAILURES retains both fatal gates"
    : > "$work/dpkg"; output=''; status=0
    t_capture_command output status final_verdict
    expected_status=1; if [ "$dpkg_status:$_VMR_DENIED_FAILURES" = 0:0 ]; then expected_status=0; fi
    t_assert_eq "$expected_status" "$status"
    t_assert_eq called "$(cat "$work/dpkg")"
    expected=''; if [ "$dpkg_status:$_VMR_DENIED_FAILURES" = 0:3 ]; then expected='FAIL: 3 DENIED source-built dependency failure(s) — see above'; fi
    t_assert_eq "$expected" "$output"
    t_record_fixture_receipt "$receipt" final "$dpkg_status" "$_VMR_DENIED_FAILURES" "$status" "$output"
  done
done
t_summary
