#!/usr/bin/env bash
# Isolated removal probes cover argv, streams and presence-based results, not real cache eviction or disk recovery.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-workspace-fixture.sh"
t_fixture_workspace_init WORK
source "${TESTS_DIR}/../01-core/disk-guard.sh"
output=""

for present in yes no; do
  for remove in yes no; do
    for status in 0 7; do
      t_case "presence=$present remove=$remove command-status=$status"
      mkdir -p "$WORK/cache dir"
      target="$WORK/cache dir/slug % literal"
      [ "$present" != yes ] || mkdir -p "$target"
      rm() {
        printf '%s\n' "$@" > "$WORK/argv"
        printf 'rm output\n'
        printf 'rm diagnostic\n' >&2
        [ "$remove" != yes ] || command rm "$@"
        return "$status"
      }
      result=0
      _disk_guard_remove_slug "$WORK/cache dir" 'slug % literal' > "$WORK/output" 2> "$WORK/error" || result=$?
      expected=0
      if [ "$present/$remove" = yes/no ]; then expected=1; fi
      t_assert_eq "$expected" "$result"
      t_assert_eq "$(printf '%s\n' -rf "$target")" "$(cat "$WORK/argv")"
      t_assert_eq 'rm output' "$(cat "$WORK/output")"
      t_assert_eq '' "$(cat "$WORK/error")"
      unset -f rm
      command rm -rf "$target"
    done
  done
done
t_case 'a failed rm remains advisory in a strict direct call'
t_capture_command output result bash -ec 'source "$1"; rm() { echo output; return 7; }; _disk_guard_remove_slug "$2" absent; echo continued' _ "${TESTS_DIR}/../01-core/disk-guard.sh" "$WORK"
t_assert_eq 0 "$result"
t_assert_eq $'output\ncontinued' "$output"
t_case 'an empty cache root fails before invoking rm'
t_capture_command output result bash -c 'source "$1"; rm() { echo invoked; }; _disk_guard_remove_slug "" victim' _ "${TESTS_DIR}/../01-core/disk-guard.sh"
t_assert_eq 127 "$result"
t_assert_eq "$output" "${output//invoked/}"
t_summary
