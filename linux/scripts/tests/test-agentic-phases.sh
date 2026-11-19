#!/usr/bin/env bash
# Local phase and backlog contracts; no real build, agent or external quality tool runs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../lib/agentic-loop.sh"
_work=$(mktemp -d)
trap 'rm -rf "$_work"' EXIT
LOG_FILE="$_work/phase.log"

_phase_case() {
    local phase="$1" result="$2" dry="$3" label="$4" expected=0 rc=0 output
    t_case "$phase result=$result dry=$dry"
    : > "$LOG_FILE"
    export DRY_RUN="$dry"
    _phase_ran=''
    output="$_work/stdout"
    local cmd="_phase_ran=yes; printf 'child-out\\n'; printf 'child-err\\n' >&2; (exit $result)"
    "invoke_$phase" "$cmd" Debug > "$output" || rc=$?
    if [[ "$phase" != quality && "$result" != 0 && "$dry" == false ]]; then expected=1; fi
    t_assert_eq "$expected" "$rc" 'phase failure policy'
    t_assert_contains "$(cat "$output")" "Command: $cmd"
    if [[ "$dry" == true ]]; then
        t_assert_eq '' "${_phase_ran}" 'dry-run must not execute'
        t_assert_contains "$(cat "$output")" "[DRY RUN] skipped $phase"
    else
        t_assert_eq yes "${_phase_ran}" 'eval retains caller scope'
        t_assert_contains "$(cat "$LOG_FILE")" child-out
        t_assert_contains "$(cat "$LOG_FILE")" child-err
        t_assert_eq 0 "$(grep -c '^child-' "$output" || true)" 'child streams stay in the log'
        if [[ "$phase" == quality ]]; then
            t_assert_contains "$(cat "$output")" 'Quality check complete'
        elif [[ "$result" == 0 ]]; then
            t_assert_contains "$(cat "$output")" "$label PASSED"
        else
            t_assert_contains "$(cat "$output")" "[ERROR] $label FAILED"
        fi
    fi
}
for phase in build tests quality; do
    for result in 0 7; do
        for dry in false true; do
            _phase_case "$phase" "$result" "$dry" "${phase^^}"
        done
    done
done

t_case 'backlog counters distinguish pending, blocked and completed tasks'
printf -- '- [ ] pending\n- [b] blocked\n- [B] blocked too\n- [x] done\n- [X] also done\n' > "$_work/BACKLOG.md"
t_assert_eq 1 "$(unchecked_task_count "$_work/BACKLOG.md")"
t_assert_eq 2 "$(blocked_task_count "$_work/BACKLOG.md")"
export DRY_RUN=false
remove_checked_tasks "$_work/BACKLOG.md" > /dev/null
t_assert_eq 0 "$(grep -c '^- \[[xX]\]' "$_work/BACKLOG.md" || true)"
for counter in unchecked_task_count blocked_task_count; do
    t_case "$counter missing and empty input returns one zero"
    : > "$_work/empty"
    t_assert_eq 0 "$("$counter" "$_work/empty")"
    t_assert_eq 0 "$("$counter" "$_work/missing")"
done

# _commit_repo: a clone with one commit; the auto-commit cases stage into it.
_commit_repo() {
    local d; d="$(mktemp -d "$_work/repo.XXXXXX")"
    git -C "$d" init -q && git -C "$d" config user.email t@example.invalid && git -C "$d" config user.name t
    git -C "$d" config commit.gpgsign false
    printf 'one\n' > "$d/tracked.txt" && git -C "$d" add tracked.txt && git -C "$d" commit -qm base
    printf '%s' "$d"
}
export DRY_RUN=false

t_case 'auto-commit stages tracked edits and new text, leaves out a binary and a large file, and names them'
d="$(_commit_repo)"; : > "$LOG_FILE"
printf 'two\n' >> "$d/tracked.txt"
printf 'new text\n' > "$d/notes.md"
printf 'x\0y' > "$d/core"
head -c $(( 501 * 1024 )) /dev/zero | tr '\0' 'a' > "$d/big.log"
t_assert_eq 0 "$(t_rc invoke_git_auto_commit 'loop: task #1' "$d" true)"
t_assert_eq 'notes.md tracked.txt' "$(git -C "$d" show --name-only --format= HEAD | sort | xargs)" 'only the rule\'s files'
t_assert_contains "$(cat "$LOG_FILE")" 'left out core'
t_assert_contains "$(cat "$LOG_FILE")" 'left out big.log'
t_assert_contains "$(cat "$LOG_FILE")" 'Committed: loop: task #1'

t_case 'nothing to commit is no failure'
d="$(_commit_repo)"; : > "$LOG_FILE"
t_assert_eq 0 "$(t_rc invoke_git_auto_commit 'loop: task #2' "$d" true)"
t_assert_contains "$(cat "$LOG_FILE")" 'nothing to commit'

t_case 'a refused commit fails the phase and says why'
d="$(_commit_repo)"; : > "$LOG_FILE"
mkdir -p "$d/.git/hooks" && printf '#!/bin/sh\necho refused-by-hook >&2\nexit 1\n' > "$d/.git/hooks/pre-commit"
chmod +x "$d/.git/hooks/pre-commit"
printf 'three\n' >> "$d/tracked.txt"
t_assert_eq 1 "$(t_rc invoke_git_auto_commit 'loop: task #3' "$d" true)" 'a silent refusal let the next task pile onto it'
t_assert_contains "$(cat "$LOG_FILE")" 'Auto-commit refused: refused-by-hook'

t_case 'disabled or dry-run commits nothing'
d="$(_commit_repo)"; printf 'four\n' >> "$d/tracked.txt"
t_assert_eq 0 "$(t_rc invoke_git_auto_commit 'x' "$d" false)"
t_assert_eq 0 "$(DRY_RUN=true t_rc invoke_git_auto_commit 'x' "$d" true)"
t_assert_eq 1 "$(git -C "$d" rev-list --count HEAD)" 'still the base commit'

t_summary
