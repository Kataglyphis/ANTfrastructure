#!/usr/bin/env bash
# Fake Git covers refresh ordering and failure policies, not network transfers or Git internals.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repository/.git"
export REFRESH_REPOSITORY="$work/repository"
export REFRESH_DOWNLOADS="${REFRESH_DOWNLOADS:-${TESTS_DIR}/../01-core/downloads.sh}"
export REFRESH_TVM="${REFRESH_TVM:-${TESTS_DIR}/../05-frameworks/tvm.sh}"
export REFRESH_TVM_FUNCTION
REFRESH_TVM_FUNCTION="$(t_fn_src "$REFRESH_TVM" fetch_tvm_source)"

_refresh_case() {
  local driver="$1" mode="$2" checkout_failure="${3:-0}" rc=0 out expected
  export REFRESH_DRIVER="$driver" REFRESH_MODE="$mode" REFRESH_CHECKOUT_FAILURE="$checkout_failure"
  export REFRESH_LOG="$work/$driver-$mode-$checkout_failure.log"
  : > "$REFRESH_LOG"
  out="$(bash -c '
    set -euo pipefail
    source "$REFRESH_DOWNLOADS"
    eval "$REFRESH_TVM_FUNCTION"
    log() { :; }
    git() {
      shift 2
      printf "%s\n" "$*" >> "$REFRESH_LOG"
      case "$1" in
        fetch)
          if [ "${*: -1}" = --tags ]; then [ "$REFRESH_MODE" != failed ];
          else [ "$REFRESH_MODE" = direct ]; fi ;;
        rev-parse) printf "same-head\n" ;;
        checkout) [ "$REFRESH_CHECKOUT_FAILURE" = 0 ] ;;
        *) return 0 ;;
      esac
    }
    if [ "$REFRESH_DRIVER" = generic ]; then
      clone_or_update_repo https://example.invalid/repository "$REFRESH_REPOSITORY" main
    else
      tvm_dir="$REFRESH_REPOSITORY"; ref=main
      fetch_tvm_source
    fi
    printf "REFRESH_FINISHED\n"
  ' 2>&1)" || rc=$?
  expected=0
  if [ "$driver" = tvm ] && [ "$checkout_failure" = 1 ]; then expected=1; fi
  t_assert_eq "$expected" "$rc" "$driver/$mode checkout=$checkout_failure status"
  t_assert_eq 'fetch --depth 1 origin main' "$(sed -n '/^fetch /{p;q;}' "$REFRESH_LOG")" 'requested ref is tried first'
  if [ "$mode" = direct ]; then
    t_assert_eq 1 "$(awk '/^fetch /{n++} END{print n+0}' "$REFRESH_LOG")" 'successful ref fetch does not fetch tags'
  else
    t_assert_contains "$(cat "$REFRESH_LOG")" 'fetch --depth 1 --tags' 'failed ref fetch tries tags'
  fi
  if [ "$expected" = 0 ]; then
    t_assert_contains "$out" REFRESH_FINISHED 'best-effort fetch failures do not abort refresh'
    if [ "$driver" = tvm ]; then
      t_assert_eq 'submodule update --init --recursive' "$(tail -1 "$REFRESH_LOG")" 'existing TVM checkout refreshes submodules'
    fi
  else
    t_assert_eq 'checkout main' "$(tail -1 "$REFRESH_LOG")" 'fatal checkout prevents submodule refresh'
  fi
}

for driver in generic tvm; do
  for mode in direct tags failed; do
    t_case "$driver refresh with $mode fetch result"
    _refresh_case "$driver" "$mode"
  done
  t_case "$driver retains its checkout failure policy"
  _refresh_case "$driver" direct 1
done
t_summary
