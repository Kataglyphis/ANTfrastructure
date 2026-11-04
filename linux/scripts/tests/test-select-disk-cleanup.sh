#!/usr/bin/env bash
# select-disk-cleanup.sh's verdicts over a fake df; not covered: whether the floor still fits the image, which the speed probe measures.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/test-workspace-fixture.sh
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare _work
t_fixture_workspace_init _work || exit 1
SELECT="${TESTS_DIR}/../../../.github/actions/prepare-linux-ci-host/select-disk-cleanup.sh"
mkdir -p "${_work}/bin"
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf " Avail\\n%%s\\n" "${FAKE_AVAIL}"\n' > "${_work}/bin/df"
chmod +x "${_work}/bin/df"
_select() { PATH="${_work}/bin:${PATH}" FAKE_AVAIL="$1" bash "${SELECT}" "$2" "$3" "$4" 2>"${_work}/err"; }

t_case "fast stays fast at or above the floor"
t_assert_eq "fast" "$(_select 122G fast 90 45)"
t_assert_eq "fast" "$(_select 90G fast 90 45)"

t_case "fast becomes the full cleanup below the floor"
t_assert_eq "true" "$(_select 72G fast 90 45)"

t_case "an explicit mode is the caller's, above the refusal floor"
t_assert_eq "false" "$(_select 50G false 90 45)"
t_assert_eq "true" "$(_select 500G true 90 45)"

t_case "below min-free-gb every mode refuses, naming the free space and the floor"
for _mode in fast true false; do
  _select 19G "${_mode}" 90 45 >/dev/null
  t_assert_eq "3" "$?"
  t_assert_contains "$(cat "${_work}/err")" "::error title=runner-disk-refusal::19G free on this runner, floor 45G"
done
t_assert_eq "true" "$(_select 45G fast 90 45)"
t_assert_eq "true" "$(_select 19G true 90 0)"

t_case "a bad floor or an unreadable disk fails instead of guessing, and is no refusal"
_select 122G fast nine 45 >/dev/null
t_assert_eq "1" "$?"
_select 122G fast 90 x >/dev/null
t_assert_eq "1" "$?"
_select "" fast 90 45 >/dev/null
t_assert_eq "1" "$?"
t_assert_no_grep "${_work}/err" 'runner-disk-refusal'

t_case "the action runs each cleanup on the selected mode, not its input"
ACTION="${TESTS_DIR}/../../../.github/actions/prepare-linux-ci-host/action.yml"
t_assert_contains "$(cat "${ACTION}")" "if: steps.disk-cleanup.outputs.mode == 'true'"
t_assert_contains "$(cat "${ACTION}")" "if: steps.disk-cleanup.outputs.mode == 'fast'"

t_case "the refusal stops the job before the pull and keeps its status"
_order="$(grep -n -E -e 'name: (Select the disk cleanup|Start the image pull|Pull the container image|Log in to the container registry)' "${ACTION}" | head -1)"
t_assert_contains "${_order}" "Select the disk cleanup"
t_assert_contains "$(cat "${ACTION}")" 'mode="$(bash "${GITHUB_ACTION_PATH}/select-disk-cleanup.sh"'
t_assert_no_grep "${ACTION}" 'echo "mode=[$]\('

t_summary
