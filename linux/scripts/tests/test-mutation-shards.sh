#!/usr/bin/env bash
# A shard plan that drops or repeats an entry turns every hub round red or thin; see docs/code-quality-tooling.md#the-shard-plan
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/test-workspace-fixture.sh
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare _work
t_fixture_workspace_init _work || exit 1
PY="${PREFLIGHT_PYTHON:-python3}"
SCRIPTS="${TESTS_DIR}/../../../docs/scripts"
GATE="${SCRIPTS}/verify_mutations.py"

# _plan_py <code>: run Python with the planner importable and a 40-entry manifest over 9 commands as `entries`.
_plan_py() {
  (cd "${SCRIPTS}" && "${PY}" -c '
import json, sys
from mutation_shards import Cost, plan, describe, default_cost, read_cost_lines, table
weights = [12, 9, 6, 4, 3, 2, 2, 1, 1]
entries = []
for c, w in enumerate(weights):
    entries += [dict(id=f"e.{c}.{i}", test=f"bash t{c}.sh") for i in range(w)]
costs = {f"bash t{c}.sh": Cost(2.0 + c, 1.5) for c in range(8)}
'"$1")
}

t_case "for any N the plan partitions the selection: every entry once, none dropped"
for _n in 1 3 8 40 41; do
  t_assert_eq "40 40" "$(_plan_py "
shards = plan(entries, costs, ${_n})
ids = [e['id'] for s in shards for e in s]
print(len(ids), len(set(ids) & {e['id'] for e in entries}))")" "N=${_n}"
done

t_case "a command's entries share one shard unless it costs more than a whole shard"
t_assert_eq "[1, 1, 1, 1, 1, 1, 1, 1, 1]" "$(_plan_py "
shards = plan(entries, costs, 3)
print([sum(1 for s in shards if any(e['test'] == f'bash t{c}.sh' for e in s)) for c in range(9)])")" \
  "three shards hold every command whole: the costliest is under a third of the total"
t_assert_eq "True" "$(_plan_py "
heavy = {**costs, 'bash t0.sh': Cost(1.0, 100.0)}
shards = plan(entries, heavy, 3)
print(sum(1 for s in shards if any(e['test'] == 'bash t0.sh' for e in s)) >= 2)")" \
  "a command heavier than a shard splits, or one job carries it alone into the timeout"

t_case "the plan balances cost, longest piece onto the lightest shard"
t_assert_eq "True" "$(_plan_py "
shards = plan(entries, costs, 3)
fb = default_cost(costs)
def load(s):
    cmds = {e['test'] for e in s}
    return sum(costs.get(c, fb).baseline + costs.get(c, fb).per_entry * sum(1 for e in s if e['test'] == c) for c in cmds)
loads = [load(s) for s in shards]
print(max(loads) - min(loads) <= max(costs[c].baseline + costs[c].per_entry * sum(1 for e in entries if e['test'] == c) for c in costs))")"

t_case "the same inputs give the same plan, whichever job computes it"
t_assert_eq "True" "$(_plan_py "
a = [[e['id'] for e in s] for s in plan(entries, costs, 8)]
b = [[e['id'] for e in s] for s in plan(list(entries), dict(reversed(list(costs.items()))), 8)]
print(a == b)")"

t_case "inside a shard the queue alternates commands, so free mirrors start other baselines"
t_assert_eq "3" "$(_plan_py "
shard = plan(entries, costs, 2)[0]
print(len({e['test'] for e in shard[:3]}))")"

t_case "a command missing from the table gets the median cost and is counted"
_line="$(_plan_py "print(describe(entries, costs, 2, 8, 'costs.json'))")"
t_assert_eq "  shard plan: 2/8 from costs.json: 9 test command(s), 1 without a recorded cost (assumed 5.50s baseline, 1.50s per entry)" "${_line}"
t_assert_eq "Cost(baseline=1.0, per_entry=1.0)" "$(_plan_py "print(default_cost({}))")" "an empty table still plans"

t_case "cost lines are read from raw gate output and from CI logs"
printf '%s\n' \
  '[2/4]   cost    wall=13.00s baseline=3.00s entries=5 test=bash t0.sh' \
  $'mutations (3)\tMutation gate, shard 3 of 8\t2026-10-31T06:54:09.6804094Z [1/4]   cost    wall=7.00s baseline=1.00s entries=3 test=bash t1.sh --flag\r' \
  '[1/4]   cost    wall=9.00s baseline=1.00s entries=4 test=bash t0.sh' \
  '[1/4]   bites   e.0.1  why' > "${_work}/gate.log"
t_assert_eq "{'bash t0.sh': {'baseline': 2.0, 'per_entry': 2.0}, 'bash t1.sh --flag': {'baseline': 1.0, 'per_entry': 2.0}}" \
  "$(_plan_py "print(table(read_cost_lines(open('${_work}/gate.log')), ['bash t0.sh', 'bash t1.sh --flag', 'bash gone.sh']))")" \
  "the median of each command's observations, per entry net of its baseline, only for commands the manifest runs"
printf '[{"id":"a","target":"x","find":"a","replace":"b","test":"bash t0.sh","why":"w"}]\n' > "${_work}/m.json"
t_assert_ok "${PY}" "${SCRIPTS}/mutation_shards.py" --from-log "${_work}/gate.log" --manifest "${_work}/m.json" --write "${_work}/costs.json"
t_assert_eq '{"bash t0.sh": {"baseline": 2.0, "per_entry": 2.0}}' "$("${PY}" -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))))' "${_work}/costs.json")"
printf 'no cost lines\n' > "${_work}/empty.log"
t_assert_rc 1 "${PY}" "${SCRIPTS}/mutation_shards.py" --from-log "${_work}/empty.log" --manifest "${_work}/m.json" --write "${_work}/none.json"

# _gate_fixture <n>: n catchable entries over three test commands, each command's suite counting its baselines.
_gate_fixture() {
  local i
  for i in $(seq 1 "$1"); do printf 'GUARD=on\n' > "${_work}/s${i}.sh"; done
  "${PY}" -c 'import json, sys; print(json.dumps([dict(id=f"probe.{i}", target=f"s{i}.sh", find="GUARD=on", replace="GUARD=off", test=f"bash ./t{(i - 1) // 4}.sh", why="probe") for i in range(1, int(sys.argv[1]) + 1)]))' \
    "$1" > "${_work}/m.json"
  for i in 0 1 2; do
    printf 'echo run >> %q\nfor f in ./s*.sh; do grep -q "GUARD=on" "$f" || exit 1; done\n' "${_work}/runs${i}" > "${_work}/t${i}.sh"
  done
  printf '{"bash ./t0.sh":{"baseline":1,"per_entry":1},"bash ./t1.sh":{"baseline":1,"per_entry":1},"bash ./t2.sh":{"baseline":1,"per_entry":1}}\n' > "${_work}/costs.json"
}
_bitten() { printf '%s\n' "$1" | sed -n 's/^\(\[[0-9]*\/[0-9]*\] \)\{0,1\}  bites  *\(probe\.[0-9]*\).*/\2/p'; }

t_case "the gate's planned shards prove every entry exactly once, and each command's baseline once"
_gate_fixture 12
_ids=""
for _k in 0 1 2; do
  _out="$("${PY}" "${GATE}" --manifest "${_work}/m.json" --root "${_work}" --jobs 2 --shard "${_k}/3" --shard-costs "${_work}/costs.json" 2>&1)"
  t_assert_contains "${_out}" "shard plan: ${_k}/3 from ${_work}/costs.json: 3 test command(s), 0 without a recorded cost" "each job names its plan"
  _ids+="$(_bitten "${_out}")"$'\n'
done
t_assert_eq "$(seq 1 12 | sed 's/^/probe./' | LC_ALL=C sort)" "$(printf '%s' "${_ids}" | sed '/^$/d' | LC_ALL=C sort)" \
  "the three planned shards together bite each entry once"
t_assert_eq "1 1 1" "$(for i in 0 1 2; do grep -c run "${_work}/runs${i}" | awk '{print $1 - 4}'; done | tr '\n' ' ' | sed 's/ $//')" \
  "a command whole on one shard runs one baseline per round, plus one run per entry"
t_assert_eq "4" "$("${PY}" "${GATE}" --manifest "${_work}/m.json" --root "${_work}" --stale-check --shard 1/3 | sed -n 's/.*(shard 1\/3: \([0-9]*\) entr(ies)).*/\1/p')" \
  "without a table the slice is still entries[K::N]"

t_summary
