#!/usr/bin/env bash
# Separate-stream workers share capture and byte receipts while consumer expectations stay in their suites.
source "${BASH_SOURCE[0]%/*}/test-harness.sh"

t_stream_workspace() {
  source "${BASH_SOURCE[0]%/*}/test-workspace-fixture.sh"
  t_fixture_workspace_init "$1" || return "$?"
  local -n _tsw_receipt="$2"
  _tsw_receipt="${3:-}"
  [ -z "$_tsw_receipt" ] || : > "$_tsw_receipt"
}

t_stream_hex() {
  local bytes
  if ! bytes="$(od -An -v -tx1 "$1")"; then printf 'unreadable:%s' "$1"; return 1; fi
  printf '%s' "$bytes" | tr -d ' \n'
}

t_stream_capture() {
  local -n _tsc_status="$1"
  local directory="$2" worker="$3"
  shift 3
  _tsc_status=0
  : > "$directory/trace"
  rm -f "$directory/returned" "$directory/rematch"
  t_run_fixture_worker "$worker" "$@" > "$directory/out" 2> "$directory/err" || _tsc_status=$?
  return 0
}

t_stream_assert_files() {
  local directory="$1" field
  shift
  for field in "$@"; do
    t_assert_eq "$(t_stream_hex "$directory/expected.$field")" "$(t_stream_hex "$directory/$field")"
  done
}

t_stream_should_abort() {
  [ "$3" -ne 0 ] || return 1
  if [ "${4:-0}" -eq 1 ] || { [ "$1" = strict ] && [ "$2" = direct ]; }; then return 0; fi
  return 1
}

t_stream_expected_return() {
  if t_stream_should_abort "$3" "$2" "$1" "${4:-0}"; then printf absent; else printf '%s' "$1"; fi
}

t_stream_return_value() {
  if [ -f "$1/returned" ]; then t_stream_hex "$1/returned"; else printf absent; fi
}

t_stream_assert_return() {
  local directory="$1" expected="$2"
  if [ "$expected" != absent ]; then
    printf '%s\n' "$expected" > "$directory/expected.returned"
    expected="$(t_stream_hex "$directory/expected.returned")"
  fi
  t_assert_eq "$expected" "$(t_stream_return_value "$directory")"
}

t_stream_record() {
  local receipt="$1" directory="$2" fields="$3" field IFS=' '
  local -a payload=()
  shift 3
  for field in $fields; do payload+=("$(t_stream_hex "$directory/$field")"); done
  payload+=("$(t_stream_return_value "$directory")")
  t_record_fixture_receipt "$receipt" "$@" "${payload[@]}"
}
