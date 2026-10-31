#!/usr/bin/env bash
# Tests argument policies without invoking Renovate, network requests or repository writes.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../renovate-say.sh" cli-test
source "${TESTS_DIR}/../renovate-cli.sh"

parse_fixture() (
  local flavor="$1"
  shift
  MODE=report DRY_RUN=0 REFRESH=0 HERE=0 VENDORED_MODE=0
  MANAGERS="" ONLY="" SKIP="" ROOT="" BUDGET=600
  # shellcheck disable=SC2034 # Used by the sourced option parser.
  SELECTED_SUBMODULES=()
  fixture_usage() { printf 'usage\n'; }
  parse_renovate_options "${flavor}" fixture_usage root ROOT "$@"
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "${MODE}" "${DRY_RUN}" "${REFRESH}" "${HERE}" "${VENDORED_MODE}" \
    "${MANAGERS}" "${ONLY}" "${SKIP}" "${BUDGET}" "${ROOT}"
)

t_case "local dry runs preserve the selected mode; fleet dry runs select apply"
t_assert_eq 'report|1|0|0|0||||600|' "$(parse_fixture local --dry-run)"
t_assert_eq 'apply|1|0|0|0||||600|' "$(parse_fixture fleet --dry-run)"
t_assert_eq 'report|1|0|0|0||||600|' "$(parse_fixture fleet --dry-run --report)"
t_assert_eq 'apply|1|0|0|0||||600|' "$(parse_fixture local --apply --dry-run)"

t_case "value options accept both spellings, explicit empties and dash-prefixed values"
t_assert_eq 'report|0|0|0|0|npm|one|two|0|repo path' \
  "$(parse_fixture fleet --managers npm --only=one --skip two --timeout=0 'repo path')"
t_assert_eq 'report|0|0|0|0|||-literal|600|' \
  "$(parse_fixture fleet --managers= --only '' --skip -literal)"
t_assert_eq 'print-bin|0|1|0|0|cargo|||600|repo' \
  "$(parse_fixture local --refresh --print-bin --managers=cargo repo)"
t_assert_eq 'report|0|0|1|1||||600|' "$(parse_fixture fleet --here --in-place)"
t_assert_eq 'report|0|0|0|1||||600|' "$(parse_fixture fleet --vendored)"

t_case "missing values and options from the other driver are refused"
for flag in --managers --only --skip --timeout; do
  t_assert_fails parse_fixture fleet "${flag}"
  t_assert_contains "$(parse_fixture fleet "${flag}" 2>&1)" "${flag} needs a value"
done
for flag in --only=x --here --vendored --timeout=0 --unknown; do
  t_assert_fails parse_fixture local "${flag}"
done
for flag in --refresh --print-bin; do
  t_assert_fails parse_fixture fleet "${flag}"
done
t_assert_fails parse_fixture fleet --submodule-path=first
t_assert_fails parse_fixture local --submodule-path=
t_assert_fails parse_fixture local --submodule-path first --submodule-path first
t_assert_fails parse_fixture local first second
t_assert_contains "$(parse_fixture local first second 2>&1)" 'more than one root given'
t_assert_eq usage "$(parse_fixture local --help)"
t_assert_eq usage "$(parse_fixture fleet -h)"
t_summary
