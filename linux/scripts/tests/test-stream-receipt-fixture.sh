#!/usr/bin/env bash
# Controlled workers cover byte fidelity, captured failure and return markers, not operating-system resource exhaustion.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-workspace-fixture.sh"
t_fixture_workspace_init WORK
source "${TESTS_DIR}/stream-receipt-fixture.sh"

t_case 'hex receipts preserve NUL and trailing newline bytes'
printf 'A\000B\n' > "$WORK/bytes"
t_assert_eq 4100420a "$(t_stream_hex "$WORK/bytes")"
t_assert_eq 1 "$(t_rc t_stream_hex "$WORK/missing")"

cat > "$WORK/worker.sh" <<'WORKER'
printf 'out\n'
printf 'err\n' >&2
printf 'trace\n' > "$2/trace"
exit 7
WORKER
t_case 'worker failure remains observable with separate byte streams'
status=0
t_stream_capture status "$WORK" "$WORK/worker.sh" "$WORK"
t_assert_eq 7 "$status"
t_assert_eq 6f75740a "$(t_stream_hex "$WORK/out")"
t_assert_eq 6572720a "$(t_stream_hex "$WORK/err")"
t_assert_eq 74726163650a "$(t_stream_hex "$WORK/trace")"
t_assert_eq absent "$(t_stream_return_value "$WORK")"

for row in '0 direct strict 0 0' '7 direct strict 0 absent' '7 conditional strict 0 7' \
           '7 direct relaxed 0 7' '7 conditional relaxed 1 absent' '0 conditional strict 1 0'; do
  read -r code context strict fatal expected <<< "$row"
  t_case "return marker $row"
  t_assert_eq "$expected" "$(t_stream_expected_return "$code" "$context" "$strict" "$fatal")"
done

_stream_compare_rc() {
  t_rc bash -c 'source "$1"; t_stream_assert_files "$2" out; t_summary' _ "$TESTS_DIR/stream-receipt-fixture.sh" "$WORK"
}
t_case 'the comparison gate detects differences beyond a matching prefix'
printf 'same-prefix-X\n' > "$WORK/expected.out"
cp "$WORK/expected.out" "$WORK/out"
t_assert_eq 0 "$(_stream_compare_rc)"
printf 'same-prefix-Y\n' > "$WORK/out"
t_assert_eq 1 "$(_stream_compare_rc)"
t_summary
