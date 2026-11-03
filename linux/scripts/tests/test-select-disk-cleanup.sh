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
_select() { PATH="${_work}/bin:${PATH}" FAKE_AVAIL="$1" bash "${SELECT}" "$2" "$3" 2>/dev/null; }

t_case "fast stays fast at or above the floor"
t_assert_eq "fast" "$(_select 122G fast 90)"
t_assert_eq "fast" "$(_select 90G fast 90)"

t_case "fast becomes the full cleanup below the floor"
t_assert_eq "true" "$(_select 72G fast 90)"

t_case "an explicit mode is the caller's, whatever the disk"
t_assert_eq "false" "$(_select 10G false 90)"
t_assert_eq "true" "$(_select 500G true 90)"

t_case "a bad floor or an unreadable disk fails instead of guessing"
_select 122G fast nine >/dev/null
t_assert_eq "1" "$?"
_select "" fast 90 >/dev/null
t_assert_eq "1" "$?"

t_case "the action runs each cleanup on the selected mode, not its input"
ACTION="${TESTS_DIR}/../../../.github/actions/prepare-linux-ci-host/action.yml"
t_assert_contains "$(cat "${ACTION}")" "if: steps.disk-cleanup.outputs.mode == 'true'"
t_assert_contains "$(cat "${ACTION}")" "if: steps.disk-cleanup.outputs.mode == 'fast'"

t_summary
