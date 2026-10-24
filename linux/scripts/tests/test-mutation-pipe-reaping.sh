#!/usr/bin/env bash
# A child holding captured pipes once delayed mutation baselines to 300 seconds.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PY="${PREFLIGHT_PYTHON:-python3}"
t_skip_unless "Python POSIX process groups" "${PY}" -c 'import os; assert hasattr(os, "killpg")'
GATE="$(cd "${TESTS_DIR}/../../.." && pwd)/docs/scripts/verify_mutations.py"
WORK="$(mktemp -d)" || exit 1
_cleanup() {
  local child
  if [ -f "${WORK}/children" ]; then
    while IFS= read -r child; do kill -KILL "${child}" 2>/dev/null || true; done < "${WORK}/children"
  fi
  rm -rf -- "${WORK}"
}
trap _cleanup EXIT
printf 'GUARD=on\n' > "${WORK}/subject.sh"
cat > "${WORK}/t.sh" <<'SH'
sleep 60 &
printf '%s\n' "$!" >> children
grep -q 'GUARD=on' subject.sh
SH
printf '%s\n' '[{"id":"pipe-probe","target":"subject.sh","find":"GUARD=on","replace":"GUARD=off","test":"bash t.sh","timeout":5,"why":"captured pipes close"}]' > "${WORK}/m.json"

t_case "a test child holding stdout and stderr is reaped after the test shell exits"
out="$("${PY}" "${GATE}" --manifest "${WORK}/m.json" --root "${WORK}" --in-place 2>&1)"; rc=$?
t_assert_eq 0 "${rc}" "the baseline and mutant must finish before their timeout"
t_assert_contains "${out}" "bites" "the mutation must still be caught"
t_assert_eq 'GUARD=on' "$(cat "${WORK}/subject.sh")" "the in-place fixture must be restored"
count=0
while IFS= read -r child; do
  count=$((count + 1))
  t_assert_eq dead "$(t_pid_state "${child}")" "a completed test left its captured pipe open"
done < "${WORK}/children"
t_assert_eq 2 "${count}" "both baseline and mutant must have launched a child"
t_summary
