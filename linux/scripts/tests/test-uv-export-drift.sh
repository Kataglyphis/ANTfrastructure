#!/usr/bin/env bash
# Exercise export drift and error handling with a stub uv, not live resolution.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-workspace-fixture.sh"
source "${TESTS_DIR}/test-uv-fixture.sh"
declare WORK
t_fixture_workspace_init WORK || exit 1
mkdir -p "${WORK}/bin" "${WORK}/repo/.github" "${WORK}/repo/quality/tool" "${WORK}/repo/linux"
: > "${WORK}/repo/quality/tool/pyproject.toml"
: > "${WORK}/repo/quality/tool/uv.lock"
printf 'fixture==1\n' > "${WORK}/repo/linux/legacy.txt"
printf '%s\n' '{"exports":[{"project":"quality/tool","output":"linux/legacy.txt"}]}' > "${WORK}/repo/.github/renovate-uv-exports.json"
t_uv_fixture_write "${WORK}/bin"
run_check() { PATH="${WORK}/bin:${PATH}" bash "${TESTS_DIR}/../verify-uv-exports.sh" "${WORK}/repo"; }
t_case 'matching locked export passes'
t_assert_rc 0 run_check
t_case 'drift cannot pass'
printf 'fixture==2\n' > "${WORK}/repo/linux/legacy.txt"
t_assert_rc 1 run_check
printf 'fixture==1\n' > "${WORK}/repo/linux/legacy.txt"
t_case 'empty and failed exports fail'
EMPTY_EXPORT=1 t_assert_rc 1 run_check
FAIL_EXPORT=7 t_assert_rc 7 run_check
t_case 'missing or empty configuration fails'
rm "${WORK}/repo/.github/renovate-uv-exports.json"
t_assert_rc 1 run_check
printf '%s\n' '{"exports":[]}' > "${WORK}/repo/.github/renovate-uv-exports.json"
t_assert_rc 1 run_check
t_summary
