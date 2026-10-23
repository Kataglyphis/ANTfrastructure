#!/usr/bin/env bash
# Extracted reports verify listing bytes and rollback dispatch, not Renovate resolution or real repository changes.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-workspace-fixture.sh"
t_fixture_workspace_init WORK
LIB="${1:-${TESTS_DIR}/..}"
cat > "${WORK}/report.sh" <<'SH'
set -u
source "$1"
source "$2/renovate-say.sh" report-test
t_source_functions "$2/renovate-local.sh" print_plan_notes || exit 1
t_source_functions "$2/renovate-tree.sh" tree_row_text report_collateral_outcome assert_manifests_unchanged || exit 1
t_source_functions "$2/renovate-locks.sh" assert_locks_sane || exit 1
trap 'printf "\036"' EXIT
scenario="$3" count="$4"
items=()
for ((i=0; i<count; i++)); do items+=("path $i %s"); done
undo_run() { printf 'UNDO:%s\n' "$*"; exit 37; }
case "$scenario" in
  listing) note_listing 'first %s' 'second line' -- "${items[@]}" ;;
  plan)
    PLAN_REFUSE=() PLAN_SKIP=() PLAN_DONE=() APPLY_UNMATCHED=()
    APPLY_REFUSED=("${items[@]}")
    print_plan_notes ;;
  collateral)
    TREE_PUTBACK=() TREE_UNSAFE=()
    for item in "${items[@]}"; do TREE_UNSAFE+=("$item"$'\t'"already dirty"); done
    report_collateral_outcome ;;
  locks)
    LOCK_DONE=(refreshed)
    lock_probe_all() { LOCK_SAID=(readable); LOCK_UNREADABLE=("${items[@]}"); }
    assert_locks_sane ;;
  manifests)
    MANIFEST_SHAS=()
    for item in "${items[@]}"; do MANIFEST_SHAS+=("$item|oldhash"); done
    GIT_BIN=fixture_git GIT_TARGET=unused
    fixture_git() { printf 'newhash\n'; }
    assert_manifests_unchanged ;;
esac
SH
output='' status=0
for scenario in listing plan collateral locks manifests; do
  t_case "${scenario} preserves empty, single and multiple item reports"
  for count in 0 1 2; do
    t_capture_command output status t_run_fixture_worker "${WORK}/report.sh" "${LIB}" "${scenario}" "${count}"
    expected_status=0
    if [ "${scenario}" = listing ] && [ "${count}" -eq 0 ]; then expected_status=1; fi
    if [[ "${scenario}" = locks || "${scenario}" = manifests ]] && [ "${count}" -gt 0 ]; then expected_status=37; fi
    t_assert_eq "${expected_status}" "${status}" "${scenario}/${count} status"
    t_assert_eq $'\036' "${output: -1}" "the receipt retains final output newlines"
    if [ "${count}" -gt 0 ]; then
      prefix='  '
      [ "${scenario}" != locks ] || prefix=''
      t_assert_contains "${output}" $'\n'"${prefix}path 0 %s" "${scenario} literal item bytes"
      case "${scenario}" in
        plan) tail=$'Move one of these by hand, deliberately, or give it a branch entry.\n\036' ;;
        collateral) tail=$'Decide those by hand -- `git diff -- <path>` says what is in them.\n\036' ;;
        locks) tail="UNDO:${count} refreshed lockfile(s) cannot be read back"$'\n\036' ;;
        manifests) tail="UNDO:a lockfile tool rewrote ${count} audited manifest(s)"$'\n\036' ;;
        listing) tail=$'first %s\nsecond line\n' ;;
      esac
      t_assert_contains "${output}" "${tail}" "${scenario} advice and dispatch bytes"
    elif [ "${scenario}" != locks ]; then
      t_assert_eq $'\036' "${output}" "${scenario} empty lists stay silent"
    fi
    t_record_fixture_receipt "${RECEIPT:-}" "${scenario}" "${count}" "${status}" "${output}"
  done
done
t_summary
