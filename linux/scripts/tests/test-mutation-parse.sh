#!/usr/bin/env bash
# A mutant that no longer parses bites for its syntax error alone; see docs/code-quality-tooling.md#mutants-must-parse
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/test-workspace-fixture.sh
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare _work
t_fixture_workspace_init _work || exit 1
PY="${PREFLIGHT_PYTHON:-python3}"
GATE="${TESTS_DIR}/../../../docs/scripts/verify_mutations.py"

# _recipes {<id> <target> <find> <replace> <test>}...: the manifest, JSON-escaped by Python.
_recipes() {
  "${PY}" -c 'import json, sys; a = sys.argv[1:]; print(json.dumps([dict(zip(("id", "target", "find", "replace", "test"), a[i:i + 5]), why="probe") for i in range(0, len(a), 5)]))' \
    "$@" > "${_work}/m.json"
}
_recipe() { _recipes probe "$@"; }
_gate() { "${PY}" "${GATE}" --manifest "${_work}/m.json" --root "${_work}" --in-place "$@"; }

# A test that fails on any syntax error, so only the parse check can tell the two bites apart.
printf 'bash -n ./subject.sh && grep -q "GUARD=on" ./subject.sh\n' > "${_work}/t-sh.sh"

t_case "a shell mutant that does not parse is refused, not counted as a bite"
printf 'if true; then\n  GUARD=on\nfi\n' > "${_work}/subject.sh"
_recipe subject.sh $'fi\n' '' 'bash ./t-sh.sh'
_out="$(t_out _gate)"
t_assert_contains "${_out}" "probe -- the mutant does not parse (bash -n:" "the refusal must name the parser and its error"
t_assert_eq "1" "$(t_rc _gate)" "a refused recipe fails the gate"
t_assert_eq "0" "$(printf '%s\n' "${_out}" | grep -c -e 'bites' || true)" "a syntax error must not pass as a caught mutation"
t_assert_contains "$(t_out _gate --parse-check)" "probe -- the mutant does not parse" "the parse mode refuses the same recipe"
t_assert_eq "1" "$(t_rc _gate --parse-check)"

t_case "a shell mutant that still parses runs as before"
_recipe subject.sh 'GUARD=on' 'GUARD=off' 'bash ./t-sh.sh'
t_assert_contains "$(t_out _gate)" "bites   probe"
t_assert_eq "0" "$(t_rc _gate)"
t_assert_contains "$(t_out _gate --parse-check)" "OK: every selected mutant of a parsed target parses (1 entr(ies), no test run)"
t_assert_eq "0" "$(t_rc _gate --parse-check)"

t_case "a CRLF shell target is judged with its carriage returns stripped"
printf 'if true; then\r\n  GUARD=on\r\nfi\r\n' > "${_work}/subject.sh"
_recipe subject.sh $'fi\n' '' 'bash ./t-sh.sh'
t_assert_contains "$(t_out _gate --parse-check)" "probe -- the mutant does not parse" \
  "bash -n rejects every CRLF file, so without stripping the target would count as unparsed and its mutant pass"

t_case "an extensionless file with a bash or sh shebang is a shell target"
for _shebang in '#!/usr/bin/env bash' '#!/bin/sh' '#!/usr/bin/env -S bash -eu'; do
  printf '%s\nif true; then\n  GUARD=on\nfi\n' "${_shebang}" > "${_work}/hook"
  _recipe hook $'fi\n' '' 'true'
  t_assert_contains "$(t_out _gate --parse-check)" "the mutant does not parse (bash -n:" "${_shebang} names a shell file"
done
printf '#!/usr/bin/env python3\nif True:\n    GUARD = 1\n' > "${_work}/hook"
_recipe hook 'GUARD = 1' 'GUARD = (' 'true'
t_assert_eq "0" "$(t_rc _gate --parse-check)" "a python shebang without .py is not read: the header says so"

t_case "a target that already fails to parse is not refused"
printf 'if true; then\n  GUARD=on\n' > "${_work}/subject.sh"
_recipe subject.sh 'GUARD=on' 'GUARD=off' 'true'
t_assert_eq "0" "$(t_rc _gate --parse-check)" "only a mutant that broke a parsing target is the mutation's fault"

t_case "a Python mutant that does not compile is refused"
printf 'def f():\n    return 1\n' > "${_work}/subject.py"
_recipe subject.py '    return 1' 'return 1' "${PY} -c 'import subject'"
_out="$(t_out _gate)"
t_assert_contains "${_out}" "probe -- the mutant does not parse (compile(): line 2:"
t_assert_eq "1" "$(t_rc _gate)"
_recipe subject.py 'return 1' 'return 2' "${PY} -c 'import subject; assert subject.f() == 1'"
t_assert_eq "0" "$(t_rc _gate --parse-check)" "a mutant that compiles is not refused"

t_case "each test command reports its wall and baseline seconds once, on stderr"
printf 'GUARD=on\nOTHER=on\n' > "${_work}/subject.sh"
printf 'grep -q "GUARD=on" ./subject.sh && grep -q "OTHER=on" ./subject.sh\n' > "${_work}/t-two.sh"
_recipes cost.a subject.sh GUARD=on GUARD=off 'bash ./t-two.sh' cost.b subject.sh OTHER=on OTHER=off 'bash ./t-two.sh'
_err="$(_gate 2>&1 >/dev/null)"
t_assert_eq "1" "$(printf '%s\n' "${_err}" | grep -c -E -e '^  cost    wall=[0-9]+\.[0-9]{2}s baseline=[0-9]+\.[0-9]{2}s entries=2 test=bash \./t-two\.sh$' || true)" \
  "one line per command, after its last entry, naming how many entries it served"
t_assert_eq "0" "$(_gate 2>/dev/null | grep -c -e 'cost ' || true)" "the cost lines stay off stdout, which carries verdicts"

t_case "every PowerShell mutant is parsed, by one pwsh process"
t_skip_unless "PowerShell 7" command -v pwsh
printf 'function Get-Guard {\n  return "on"\n}\n' > "${_work}/subject.ps1"
printf 'function Get-Other {\n  return "on"\n}\n' > "${_work}/other.psm1"
_recipes ps.broken subject.ps1 $'}\n' '' true ps.fine subject.ps1 '"on"' '"off"' true psm.broken other.psm1 '{' '(' true
_out="$(t_out _gate --parse-check)"
t_assert_contains "${_out}" "ps.broken -- the mutant does not parse (PowerShell parser: line"
t_assert_contains "${_out}" "psm.broken -- the mutant does not parse (PowerShell parser: line"
t_assert_eq "0" "$(printf '%s\n' "${_out}" | grep -c -e 'ps.fine' || true)" "a mutant that parses is not named"
mkdir -p "${_work}/pwsh-log"
printf '#!/usr/bin/env bash\necho run >> %q\nexec %q "$@"\n' "${_work}/pwsh-log/calls" "$(command -v pwsh)" > "${_work}/pwsh-log/pwsh"
chmod +x "${_work}/pwsh-log/pwsh"
PATH="${_work}/pwsh-log:${PATH}" _gate --parse-check > /dev/null 2>&1
t_assert_eq "1" "$(wc -l < "${_work}/pwsh-log/calls" | tr -d ' ')" "one process for every PowerShell text, not one per mutant"

t_case "a missing parser fails the run, it never skips"
mkdir -p "${_work}/no-pwsh"
ln -sf "$(command -v "${PY}")" "${_work}/no-pwsh/${PY##*/}"
ln -sf "$(command -v bash)" "${_work}/no-pwsh/bash"
_no_pwsh() { PATH="${_work}/no-pwsh" "${PY##*/}" "${GATE}" --manifest "${_work}/m.json" --root "${_work}" --in-place "$@"; }
t_assert_contains "$(t_out _no_pwsh --parse-check)" "pwsh is not on PATH"
t_assert_eq "1" "$(t_rc _no_pwsh --parse-check)"
_out="$(t_out _no_pwsh)"
t_assert_contains "${_out}" "pwsh is not on PATH" "the proving run refuses the same way"
t_assert_eq "1" "$(t_rc _no_pwsh)"

t_summary
