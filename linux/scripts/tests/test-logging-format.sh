#!/usr/bin/env bash
# Byte-level prefix and stream checks cover non-TTY policy; real terminal rendering is outside this fixture.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LOGGING="${1:-${TESTS_DIR}/../01-core/logging.sh}"
# shellcheck source=../01-core/logging.sh
source "$LOGGING"
_work=$(mktemp -d)
trap 'rm -rf "$_work"' EXIT

for level in INFO WARN ERROR unknown ''; do
  case "$level" in
    INFO) expected=INFO; color=34 ;;
    WARN) expected=WARN; color=33 ;;
    ERROR) expected=ERROR; color=31 ;;
    *) expected=LOG; color='' ;;
  esac
  t_case "plain and colored prefixes preserve exact bytes for [$level]"
  t_assert_eq "[$expected]:end" "$(_log_prefix_plain "$level"; printf :end)"
  t_assert_eq "$(printf '\033[1%sm[%s]\033[0m' "${color:+;$color}" "$expected"):end" "$(_log_prefix_color "$level"; printf :end)"
done

for mode in always never auto; do
  for no_color in '' 1; do
    export LOG_COLOR="$mode" NO_COLOR="$no_color"
    t_case "$mode / NO_COLOR=$no_color keeps message bytes and warning stream"
    _emit=plain
    [[ "$mode" != always || -n "$no_color" ]] || _emit=color
    info 'literal %s \n text' > "$_work/out" 2> "$_work/err"
    t_assert_eq "$(_log_prefix_$_emit INFO) literal %s \n text" "$(cat "$_work/out")"
    t_assert_eq '' "$(cat "$_work/err")"
    warn 'warning text' > "$_work/out" 2> "$_work/err"
    t_assert_eq '' "$(cat "$_work/out")"
    t_assert_eq "$(_log_prefix_$_emit WARN) warning text" "$(cat "$_work/err")"
  done
done

for command_name in err die; do
  t_case "$command_name remains fatal and writes only to stderr"
  _rc=0
  LOG_COLOR=never NO_COLOR=1 bash -c 'source "$1"; "$2" "fatal text"; printf survived' _ "$LOGGING" "$command_name" \
    > "$_work/out" 2> "$_work/err" || _rc=$?
  t_assert_eq 1 "$_rc"
  t_assert_eq '' "$(cat "$_work/out")"
  t_assert_eq '[ERROR] fatal text' "$(cat "$_work/err")"
done

t_summary
