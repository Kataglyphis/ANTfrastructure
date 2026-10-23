#!/usr/bin/env bash
# Stubbed version consumers cover validation, normalization and BASH_REMATCH, not compiler builds or documentation generation.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-workspace-fixture.sh"
t_fixture_workspace_init WORK
source "${TESTS_DIR}/stream-receipt-fixture.sh"
scripts="${1:-${TESTS_DIR}/..}"
receipt="${2:-}"
focus="${3:-all}"
case "$focus" in all|callers) ;; *) printf 'Unknown fixture focus: %s\n' "$focus" >&2; exit 2 ;; esac
[ -z "$receipt" ] || : > "$receipt"
mkdir -p "$WORK/lib" "$WORK/01-core"
cp "$scripts/01-core/load-versions-env.sh" "$WORK/01-core/"
: > "$WORK/01-core/tool-pins.env"
t_fn_src "$scripts/02-toolchain/gcc.sh" gcc_resolve_full_version > "$WORK/consumers.sh" || exit 1
t_fn_src "$scripts/02-toolchain/rust/version_util.sh" normalize_version >> "$WORK/consumers.sh" || exit 1
t_fn_src "$scripts/lib/dartdoc-build.sh" _dartdoc_build_default_doc >> "$WORK/consumers.sh" || exit 1
printf '_numeric_gcc_warning() {\n' >> "$WORK/consumers.sh"
awk '/^if .*GCC_VERSION.*(=~|version_has_numeric_parts)|^if ! version_has_numeric_parts.*GCC_VERSION/ {p=1} p {print} p && /^fi$/ {exit}' \
  "$scripts/02-toolchain/build-gcc.sh" > "$WORK/warning.sh"
[ -s "$WORK/warning.sh" ] || { printf 'Missing GCC version validation block\n' >&2; exit 1; }
cat "$WORK/warning.sh" >> "$WORK/consumers.sh"
printf '}\n' >> "$WORK/consumers.sh"
cat > "$WORK/worker.sh" <<'WORKER'
set -u
harness="$1" work="$2" consumer="$3" value="$4" parts="$5" context="$6"
source "${harness%/*}/shell-context-fixture.sh"
source "$work/01-core/load-versions-env.sh"
source "$work/consumers.sh"
warn() { printf 'WARN:%s\n' "$*" >&2; }
err() { printf 'ERR:%s\n' "$*" >&2; exit 1; }
info() { printf 'INFO:%s\n' "$*"; }
dart() {
  printf '%s\n' "$*" >> "$work/trace"
  case "$*" in
    'pub global list') printf 'dartdoc %s\n' "$DARTDOC_VERSION" ;;
    'pub global run dartdoc:dartdoc') printf 'DOC\n' ;;
    *) printf 'Unexpected dart command\n' >&2; return 29 ;;
  esac
}
_numeric_consumer() {
  case "$consumer" in
    predicate) version_has_numeric_parts "$value" "$parts" ;;
    gcc) gcc_resolve_full_version "$value" 'DEFAULT fallback' ;;
    rust) normalize_version "$value" ;;
    build-gcc) _numeric_gcc_warning ;;
    dartdoc) _dartdoc_build_default_doc ;;
  esac
}
GCC_VERSION="$value"; DARTDOC_VERSION="$value"
_DARTDOC_BUILD_LIB_DIR="$work/lib"; DARTDOC_BUILD_TOOL_CACHE="$work/cache"
BASH_REMATCH=(seed prior-capture)
trap 'declare -p BASH_REMATCH > "$work/rematch"' EXIT
set -e
shell_fixture_run_context "$context" status _numeric_consumer
printf '%s\n' "$status" > "$work/returned"
exit "$status"
WORKER

_numeric_expected() {
  local consumer="$1" value="$2" valid3="$3" valid4="$4" normalized="$5" normalized_match="$6" parts="$7" context="$8" fatal=0
  expected_status=0; expected_out=""; expected_err=""; expected_trace=""; match=""
  case "$consumer" in
    predicate)
      case "$parts" in
        3) expected_status=$((1 - valid3)); [ "$valid3" -ne 1 ] || match="$value" ;;
        4) expected_status=$((1 - valid4)); [ "$valid4" -ne 1 ] || match="$value" ;;
        *) expected_status=2; match=SEED ;;
      esac ;;
    gcc)
      expected_out='DEFAULT fallback'
      if [ "$valid3" -eq 1 ]; then expected_out="$value"; match="$value"; fi ;;
    rust) expected_out="$normalized"$'\n'; match="$normalized_match" ;;
    build-gcc)
      if [ "$valid3" -eq 1 ]; then match="$value"
      else printf -v expected_err "WARN:GCC_VERSION '%s' does not match expected format X.Y.Z (e.g., 16.1.0)\n" "$value"; fi ;;
    dartdoc)
      if [ "$valid3" -eq 1 ]; then
        match="$value"; expected_out=$'DOC\n'
        expected_trace=$'pub global list\npub global list\npub global run dartdoc:dartdoc\n'
      else expected_status=1; fatal=1; expected_err=$'ERR:No exact DARTDOC_VERSION in tool-pins.env.\n'; fi ;;
  esac
  expected_returned="$(t_stream_expected_return "$expected_status" "$context" strict "$fatal")"
}

_numeric_assert() {
  local consumer="$1" value="$2" parts="$7" context="$8" status=0
  local expected_status expected_out expected_err expected_trace expected_returned match
  _numeric_expected "$@"
  case "$match" in SEED) BASH_REMATCH=(seed prior-capture) ;; '') BASH_REMATCH=() ;; *) BASH_REMATCH=("$match") ;; esac
  declare -p BASH_REMATCH > "$WORK/expected.rematch"
  printf '%s' "$expected_out" > "$WORK/expected.out"
  printf '%s' "$expected_err" > "$WORK/expected.err"
  printf '%s' "$expected_trace" > "$WORK/expected.trace"
  t_case "$consumer $value parts=$parts $context"
  t_stream_capture status "$WORK" "$WORK/worker.sh" "$WORK" "$consumer" "$value" "$parts" "$context"
  t_assert_eq "$expected_status" "$status"
  t_stream_assert_files "$WORK" out err trace rematch
  t_stream_assert_return "$WORK" "$expected_returned"
  t_stream_record "$receipt" "$WORK" 'out err trace rematch' "$consumer" "$value" "$parts" "$context" "$status"
}

_numeric_value() {
  local value="$1" valid3="$2" valid4="$3" normalized="$4" normalized_match="$5" context consumer
  for context in direct conditional; do
    for consumer in gcc rust build-gcc dartdoc; do
      _numeric_assert "$consumer" "$value" "$valid3" "$valid4" "$normalized" "$normalized_match" 3 "$context"
    done
    if [ "$focus" = all ]; then
      _numeric_assert predicate "$value" "$valid3" "$valid4" "$normalized" "$normalized_match" 3 "$context"
      _numeric_assert predicate "$value" "$valid3" "$valid4" "$normalized" "$normalized_match" 4 "$context"
    fi
  done
}

_numeric_value '' 0 0 0.1.0.0 ''
_numeric_value 1 0 0 0.1.0.0 ''
_numeric_value 1.2 0 0 0.1.0.0 ''
_numeric_value 1.2.3 1 0 1.2.3.0 1.2.3.0
_numeric_value 01.002.0003 1 0 01.002.0003.0 01.002.0003.0
_numeric_value 1.2.3.4 0 1 1.2.3.4 1.2.3.4
_numeric_value 1.2.3.4.5 0 0 0.1.0.0 ''
_numeric_value v1.2.3 0 0 1.2.3.0 1.2.3.0
_numeric_value v1.2.3.4 0 0 1.2.3.4 1.2.3.4
_numeric_value vv1.2.3 0 0 0.1.0.0 ''
_numeric_value 1a2b3 0 0 0.1.0.0 ''
_numeric_value 1.2.x 0 0 0.1.0.0 ''
_numeric_value ' 1.2.3' 0 0 0.1.0.0 ''
_numeric_value $'1.2.3\n' 0 0 0.1.0.0 ''
if [ "$focus" = all ]; then
  for parts in '' 0 2 5 '3+1'; do
    for context in direct conditional; do _numeric_assert predicate 1.2.3 1 0 1.2.3.0 1.2.3.0 "$parts" "$context"; done
  done
fi
t_summary
