#!/usr/bin/env bash
# Offline commands cover current-UID execute/status policies, not privilege changes or real sudo/package installs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/stream-receipt-fixture.sh"
receipt=''
t_stream_workspace WORK receipt "${2:-}"
subject="${1:-$TESTS_DIR/../02-toolchain/packaging-deps.sh}"
for name in best_effort_mode _packaging_execute _packaging_step_failure run_step _packaging_sudo_failure try_or_sudo; do
  if grep -q "^${name}() {" "$subject"; then t_fn_src "$subject" "$name"; fi
done > "$WORK/functions.sh"
cat > "$WORK/worker.sh" <<'WORKER'
set -u
TESTS_DIR="${1%/*}" root="$2" kind="$3" mode="$4" first="$5" available="$6" second="$7" strict="$8" context="$9"
source "$TESTS_DIR/shell-context-fixture.sh"
source "$root/functions.sh"
PACKAGING_DEPS_MODE="$mode"
warn() { printf 'WARN:%s\n' "$*" >&2; }
info() { printf 'INFO:%s\n' "$*"; }
probe() {
  false
  printf 'command-out\n'; printf 'command-err\n' >&2
  printf 'command:<%s><%s><%s>\n' "$1" "$2" "$3" >> "$root/trace"
  return "$first"
}
sudo() {
  printf 'sudo-out\n'; printf 'sudo-err\n' >&2
  printf 'sudo:<%s><%s><%s><%s>\n' "$1" "$2" "$3" "$4" >> "$root/trace"
  return "$second"
}
command() {
  if [ "$1" = -v ] && [ "$2" = sudo ]; then
    printf 'sudo-probe\n' >> "$root/trace"
    [ "$available" = yes ]; return "$?"
  fi
  builtin command "$@"
}
invoke() {
  if [ "$kind" = step ]; then run_step 'build tools' probe 'a b' '' '*.deb'
  else try_or_sudo probe 'a b' '' '*.deb'; fi
}
[ "$strict" != strict ] || set -e
shell_fixture_run_context "$context" status invoke
printf '%s\n' "$status" > "$root/returned"
exit "$status"
WORKER

_packaging_expected() {
  local kind="$1" mode="$2" first="$3" available="$4" second="$5"
  printf 'command-out\n' > "$WORK/expected.out"
  printf 'command-err\n' > "$WORK/expected.err"
  printf 'command:<a b><><*.deb>\n' > "$WORK/expected.trace"
  expected="$first"
  [ "$first" -ne 0 ] || return 0
  if [ "$kind" = step ]; then
    if [ "$mode" = best-effort ]; then
      expected=0
      printf 'WARN:build tools failed; continuing because PACKAGING_DEPS_MODE=best-effort\n' >> "$WORK/expected.err"
    fi
  elif [ "$EUID" -ne 0 ]; then
    printf 'sudo-probe\n' >> "$WORK/expected.trace"
    if [ "$available" = yes ]; then
      expected="$second"
      printf 'INFO:Retrying with sudo: probe\nsudo-out\n' >> "$WORK/expected.out"
      printf 'sudo-err\n' >> "$WORK/expected.err"
      printf 'sudo:<probe><a b><><*.deb>\n' >> "$WORK/expected.trace"
    else
      printf 'WARN:Command failed and sudo unavailable: probe a b  *.deb\n' >> "$WORK/expected.err"
    fi
  fi
}

_packaging_case() {
  local kind="$1" mode="$2" first="$3" available="$4" second="$5" strict="$6" context="$7" status=0 expected
  t_case "$*"
  _packaging_expected "$kind" "$mode" "$first" "$available" "$second"
  t_stream_capture status "$WORK" "$WORK/worker.sh" "$WORK" "$@"
  t_assert_eq "$expected" "$status"
  t_stream_assert_files "$WORK" out err trace
  t_stream_assert_return "$WORK" "$(t_stream_expected_return "$expected" "$context" "$strict")"
  t_stream_record "$receipt" "$WORK" 'out err trace' "$@" "$status"
}

for strict in strict relaxed; do
  for context in direct conditional; do
    _packaging_case step required 0 no 23 "$strict" "$context"
    _packaging_case step required 7 no 23 "$strict" "$context"
    _packaging_case step best-effort 7 no 23 "$strict" "$context"
    _packaging_case sudo required 0 yes 23 "$strict" "$context"
    _packaging_case sudo required 7 no 23 "$strict" "$context"
    _packaging_case sudo required 7 yes 0 "$strict" "$context"
    _packaging_case sudo required 7 yes 23 "$strict" "$context"
  done
done
t_summary
