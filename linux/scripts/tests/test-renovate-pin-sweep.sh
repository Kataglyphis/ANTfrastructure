#!/usr/bin/env bash
# renovate-local.sh runs bump_versions.py in the same call: --check on report, --write (+ sync) on apply. docs/dependency-updates.md#the-sweep-rides-the-renovate-call
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
_local="$(cat "${TESTS_DIR}/../renovate-local.sh")"
_cli="$(cat "${TESTS_DIR}/../renovate-cli.sh")"

t_case "both modes end in the sweep, after Renovate's own halves"
t_assert_contains "${_local}" '  report) run_report; report_default_submodules; report_lock_maintenance; report_pin_sweep ;;' "report ends in --check"
t_assert_contains "${_local}" '  apply)  run_report; report_default_submodules; report_lock_maintenance; run_apply; apply_pin_sweep ;;' "apply writes after run_apply"

t_case "the report half fails loudly on an incomplete check; the apply half exits 2 and keeps Renovate's writes"
t_assert_contains "${_local}" '"${PY_BIN}" "${tool}" --check || err "the versions.env sweep could not check every key' "a failed lookup is never 'up to date'"
t_assert_contains "${_local}" 'if "${PY_BIN}" "${tool}" --write && "${PY_BIN}" "${TARGET}/docs/scripts/sync_versions.py" --write; then' "write, then sync the derived files"
t_assert_contains "${_local}" '  EXIT_CODE="${EXIT_REFUSED}"' "a failed sweep is a refused update, not a rolled-back run"
t_assert_contains "${_local}" '[ "${DRY_RUN}" = 0 ] || { note ""; note "dry run: bump_versions.py --write and sync_versions.py --write would follow"; return 0; }' "a dry run writes nothing"

t_case "--no-bump is a local flag, and a tree without the tool (a consumer) skips the sweep"
t_assert_contains "${_cli}" '    local:--no-bump) assign_renovate_options BUMP 0 ;;' "the flag"
t_assert_contains "${_local}" '  [ "${BUMP}" = 1 ] || return 1' "honoured by the selector"
t_assert_contains "${_local}" '  [ -f "${TARGET}/docs/scripts/bump_versions.py" ] || return 1' "consumers have no versions.env sweep"

t_summary
