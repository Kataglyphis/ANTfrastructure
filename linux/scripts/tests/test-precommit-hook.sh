#!/usr/bin/env bash
# The commit hook's mutation step is SAMPLED, and a sample must never read as
# full coverage: the plan cuts matched entries newest-first to the cap, and the
# notice names both numbers whenever it cut. Guards the cost budget that made the
# hook 5m22s on a 43-file commit before the cap existed.
# docs/code-quality-tooling.md#the-pre-commit-hooks-cost-budget
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
HOOK="${TESTS_DIR}/../../host-config/git-hooks/pre-commit"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

python3 - "${_work}/manifest.json" <<'PY'
import json
import sys

hot = [{"id": "hot.e%02d" % n, "target": "a/hot.sh", "find": "x", "replace": "y",
        "test": "true", "why": "fixture"} for n in range(10)]
cold = [{"id": "cold.only", "target": "a/cold.sh", "find": "x", "replace": "y",
         "test": "true", "why": "fixture"}]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(hot + cold, fh)
PY
printf 'a/hot.sh\n' > "${_work}/hot.txt"
printf 'a/hot.sh\na/cold.sh\n' > "${_work}/both.txt"
printf 'a/untracked-by-any-entry.sh\n' > "${_work}/none.txt"

_plan() { bash "${HOOK}" --print-mutation-plan "$1" "${_work}/manifest.json" "$2"; }

t_case "the cap cuts the run: 10 matched entries, cap 3, three ids"
t_assert_eq "plan 3 10" "$(_plan 3 "${_work}/hot.txt" | head -1)"
t_assert_eq "3" "$(_plan 3 "${_work}/hot.txt" | tail -n +2 | grep -c .)"

t_case "the header reports MATCHED, not the cut size — the number the notice needs"
t_assert_eq "plan 6 11" "$(_plan 6 "${_work}/both.txt" | head -1)"

t_case "newest first: the last manifest entry for a staged target runs first"
t_assert_eq "cold.only" "$(_plan 3 "${_work}/both.txt" | sed -n '2p')"
t_assert_eq "hot.e09" "$(_plan 3 "${_work}/both.txt" | sed -n '3p')"

t_case "cap 0 is uncapped"
t_assert_eq "plan 10 10" "$(_plan 0 "${_work}/hot.txt" | head -1)"

t_case "a staged file no entry targets selects nothing"
t_assert_eq "plan 0 0" "$(_plan 6 "${_work}/none.txt" | head -1)"

_NOTICE_SRC="$(t_fn_src "${HOOK}" _mutation_notice)" || exit 1
eval "${_NOTICE_SRC}"

t_case "a cut run SAYS it sampled, and names both numbers"
t_assert_contains "$(_mutation_notice 6 132)" "SAMPLED 6 of 132"
t_case "a cut run never reads as full coverage"
t_assert_contains "$(_mutation_notice 6 132)" "NOT full coverage"
t_case "an uncut run does not claim to have sampled"
t_assert_fails grep -q -e 'SAMPLED' <<<"$(_mutation_notice 5 5)"
t_assert_contains "$(_mutation_notice 5 5)" "all 5 entries"

t_case "the hook still names the gate it runs, so the registry's hook tier stays true"
t_assert_ok grep -q -F -e 'docs/scripts/verify_mutations.py' "${HOOK}"

t_summary
