#!/usr/bin/env bash
# renovate_audit.py, the half that does not trust the locator; test-renovate-local.sh grades the locator.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/renovate-fixtures.sh"
# Read from linux/scripts, so the locator and the planner's apply half can each run alone.
SCRIPTS_DIR="${TESTS_DIR}/.."

# Each case asserts the refusal AND that the locator alone still errs; see docs/dependency-updates.md#the-edit-is-audited-by-a-real-parser

# _locator_says <manager> <file> <dep> <old> <new>: "<line> <rewritten>" per line the locator alone would write.
_locator_says() {
  "${PY_ABS}" - "${SCRIPTS_DIR}" "$@" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
import renovate_locator

mgr, path, dep, old, new = sys.argv[2:7]
with open(path, encoding="utf-8", newline="") as fh:
    lines = fh.read().split("\n")
kind, found, why = renovate_locator.resolve(mgr, lines, dep, old, new, 1)
if kind != "EDIT":
    print("%s %s" % (kind, why))
for site in found:
    raw = lines[site.line]
    print("%d %s" % (site.line + 1, raw[:site.start] + new + raw[site.end:]))
PY
}

# _parser_refuses <repo> <report> <manager> <reason>: refused for that reason with rc 2; see docs/dependency-updates.md#what-a-caller-branches-on
_parser_refuses() {
  _run "$1" "$2" --apply --managers "$3"
  t_assert_eq "2" "${RC}" "the refusal is the RESULT, so the run exits 2"
  t_assert_contains "${OUT}" "$4" "the refusal is the parser's, and it says why"
}

# (H1) `dependencies: &deps` hides the mapping from the line reader, which then rewrites dependency_overrides.
t_case "(H1) a YAML anchor: the locator still writes the WRONG entry, the run refuses"
H1="$(_plant h1 pubspec.yaml 'name: fixture\ndependencies: &deps\n  http: 1.1.0\ndependency_overrides:\n  http: 1.1.0\n')"
t_assert_eq "5   http: 1.6.0" \
  "$(_locator_says pub "${H1}/pubspec.yaml" http 1.1.0 1.6.0)" \
  "the locator ALONE still picks line 5, the dependency_overrides entry"
_parser_refuses "${H1}" "${A_REPORT}" pub \
  "a real parser reads this file as declaring 'http'"
t_assert_contains "${OUT}" "dependencies.http=1.1.0, dependency_overrides.http=1.1.0" \
  "and it names BOTH declarations, by path"
t_assert_eq "  http: 1.1.0" "$(_pub "${H1}" 3)" "the real declaration is untouched"
t_assert_eq "  http: 1.1.0" "$(_pub "${H1}" 5)" "and so is the override the locator picked"

# An alias shares one node's bytes between two paths, so paths are counted, not nodes.
t_case "(H1b) an ALIAS puts one node at two paths, and that counts as two"
H1B="$(_plant h1b .github/workflows/ci.yml 'name: ci\njobs:\n  b:\n    steps:\n      - &s\n        uses: actions/checkout@v4\n  c:\n    steps:\n      - *s\n')"
t_assert_eq "6         uses: actions/checkout@v5" \
  "$(_locator_says github-actions "${H1B}/.github/workflows/ci.yml" \
     actions/checkout v4 v5)" \
  "the locator sees ONE line, because the alias is not a line"
_parser_refuses "${H1B}" "${B_REPORT}" github-actions \
  "jobs.b.steps[0].uses=v4, jobs.c.steps[0].uses=v4"
t_assert_eq "        uses: actions/checkout@v4" "$(_step "${H1B}" 6)" \
  "nothing written: a text edit cannot move one alias without moving the other"

# (H2) The audit strips a BOM for tomllib, but the BOM defeats the locator's `[project]` match.
t_case "(H2) a UTF-8 BOM: the locator still writes the WRONG array, the run refuses"
H2="$(_plant h2 pyproject.toml '\xef\xbb\xbf[project]\nname = "fixture"\ndependencies = [\n  "ruff==0.9.0",\n]\n\n[dependency-groups]\ndev = [\n  "ruff==0.9.0",\n]\n')"
t_assert_eq '9   "ruff==0.16.6",' \
  "$(_locator_says pep621 "${H2}/pyproject.toml" ruff ==0.9.0 ==0.16.6)" \
  "the locator ALONE still picks line 9, the dependency-groups entry"
H2_REPORT="${WORK}/h2.json"
_report "${H2_REPORT}" pep621 pyproject.toml ruff ==0.9.0 ==0.16.6
_parser_refuses "${H2}" "${H2_REPORT}" pep621 \
  "project.dependencies[0]===0.9.0, dependency-groups.dev[0]===0.9.0"
t_assert_eq '  "ruff==0.9.0",' "$(_line "${H2}/pyproject.toml" 4)" \
  "the [project] pin is untouched"
t_assert_eq '  "ruff==0.9.0",' "$(_line "${H2}/pyproject.toml" 9)" \
  "and so is the one the locator picked"

# (H3) YAML allows `|2-` as well as `|-2`; the locator knows one and edits a workflow that is only printed.
t_case "(H3) the block header |2-: the locator still writes inside the run: block"
H3="$(_plant h3 .github/workflows/ci.yml 'name: ci\njobs:\n  b:\n    steps:\n      - name: print a workflow\n        run: |2-\n            steps:\n              - uses: actions/checkout@v4\n')"
t_assert_eq "8               - uses: actions/checkout@v5" \
  "$(_locator_says github-actions "${H3}/.github/workflows/ci.yml" \
     actions/checkout v4 v5)" \
  "the locator ALONE still picks line 8, a line inside the block scalar"
_parser_refuses "${H3}" "${B_REPORT}" github-actions \
  "a real parser finds no declaration of 'actions/checkout' in this file at all"
t_assert_eq "              - uses: actions/checkout@v4" "$(_step "${H3}" 8)" \
  "the printed workflow is untouched"

# (H4) Every pre-flight passes, so only parsing the written file back catches where the edit landed.
t_case "(H4) a plan naming the wrong line is WRITTEN, caught on read-back, put back"
H4="$(_plant h4 pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n  other_pkg: 1.1.0\n')"
H4_PLAN="${WORK}/h4-plan.json"
printf '[{"file":"pubspec.yaml","line":3,"old":"  other_pkg: 1.1.0","new":"  other_pkg: 1.6.0","manager":"pub","dep":"http","cur":"1.1.0","next":"1.6.0"}]\n' \
  > "${H4_PLAN}"
_apply_plan "${H4}" "${H4_PLAN}"
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "did not survive being read back by a real parser" \
  "the audit says what it did"
t_assert_contains "${OUT}" \
  "it changed dependencies.other_pkg, which declares nothing this report names" \
  "and names the path that moved"
t_assert_contains "${OUT}" \
  "it left dependencies.http, the declaration the report named, alone" \
  "and the path that should have"
t_assert_eq "  http: 1.1.0" "$(_pub "${H4}" 3)" "http is where it was"
t_assert_eq "  other_pkg: 1.1.0" "$(_pub "${H4}" 4)" \
  "and other_pkg is back at the bytes it had"
t_assert_eq "" "$(find "${H4}" -maxdepth 1 -name '.renovate*')" "no temp file left behind"

t_case "(H4b) the same plan pointing at the RIGHT line still applies"
H4B_PLAN="${WORK}/h4b-plan.json"
printf '[{"file":"pubspec.yaml","line":2,"old":"  http: 1.1.0","new":"  http: 1.6.0","manager":"pub","dep":"http","cur":"1.1.0","next":"1.6.0"}]\n' \
  > "${H4B_PLAN}"
_apply_plan "${H4}" "${H4B_PLAN}"
t_assert_eq "0" "${RC}" "the audit sanctions the edit it was described"
t_assert_eq "  http: 1.6.0" "$(_pub "${H4}" 3)" "http moved"
t_assert_eq "  other_pkg: 1.1.0" "$(_pub "${H4}" 4)" "other_pkg untouched"

t_case "(H4c) a plan step that does not say WHICH value moves is not written"
H4C="$(_plant h4c pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n')"
H4C_PLAN="${WORK}/h4c-plan.json"
printf '[{"file":"pubspec.yaml","line":2,"old":"  http: 1.1.0","new":"  http: 1.6.0","manager":"pub","dep":"http"}]\n' \
  > "${H4C_PLAN}"
_apply_plan "${H4C}" "${H4C_PLAN}"
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "planned without cur, next" "and name what is missing"
t_assert_eq "  http: 1.1.0" "$(_pub "${H4C}" 3)" "nothing written"

# (H5) newValue is another program's text; a `"` in it injects a key no pre-flight can see.
t_case "(H5) a newValue carrying a quote injects a key, and the audit undoes it"
H5="$(_plant h5 package.json '{\n  "name": "fixture",\n  "dependencies": {\n    "left-pad": "1.1.0"\n  }\n}\n')"
H5_REPORT="${WORK}/h5.json"
# JSON-escaped, so _report's printf carries the string `1.6.0", "evil": "yes` through.
_report "${H5_REPORT}" npm package.json left-pad 1.1.0 '1.6.0\", \"evil\": \"yes'
_run "${H5}" "${H5_REPORT}" --apply --managers npm
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "changed the SHAPE of the file" "the audit says what it saw"
t_assert_contains "${OUT}" "1 appeared (dependencies.evil)" "and names the injected key"
t_assert_eq '    "left-pad": "1.1.0"' "$(_line "${H5}/package.json" 4)" \
  "the manifest is back at the bytes it had"
t_assert_ok git -C "${H5}" diff --quiet HEAD

# (H6) A manifest that does not parse before the edit cannot be audited, so it is not written into.
t_case "(H6) a manifest that does not parse is refused, not written into"
H6="$(_plant h6 pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\nbroken: [unclosed\n')"
t_assert_eq "3   http: 1.6.0" \
  "$(_locator_says pub "${H6}/pubspec.yaml" http 1.1.0 1.6.0)" \
  "the locator is happy to rewrite line 3 of a file it cannot read"
_parser_refuses "${H6}" "${A_REPORT}" pub "PyYAML cannot read it"
t_assert_eq "  http: 1.1.0" "$(_pub "${H6}" 3)" "nothing written"

# (H7) A manager the locator can edit but nothing can verify is a hole, so the tables are compared.
t_case "(H7) every manager the locator can edit has a real parser behind it"
t_assert_eq "" "$("${PY_ABS}" - "${SCRIPTS_DIR}" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
import renovate_audit
import renovate_locator

gap = set(renovate_locator.FINDERS) - set(renovate_audit.FORMATS)
gap |= set(renovate_locator.FINDERS) - set(renovate_audit.DECLARERS)
gap |= set(renovate_audit.FORMATS) ^ set(renovate_audit.DECLARERS)
print(", ".join(sorted(gap)), end="")
PY
)" "FINDERS, FORMATS and DECLARERS must name exactly the same managers"

# (H8) Without PyYAML there is no guarantee, so the run refuses instead of falling back to line reading.
t_case "(H8) a python with no PyYAML refuses the run instead of falling back"
H8="$(_plant h8 pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n')"
NO_YAML="${WORK}/no-yaml"
mkdir -p "${NO_YAML}"
printf 'raise ImportError("PyYAML is not installed in this fixture")\n' \
  > "${NO_YAML}/yaml.py"
RUN_PYTHONPATH="${NO_YAML}" _parser_refuses "${H8}" "${A_REPORT}" pub \
  "PyYAML is not installed for this python"
t_assert_eq "  http: 1.1.0" "$(_pub "${H8}" 3)" "nothing written"

# (H9) The shipped requirements parser splits fields, so a disturbed marker or hash shows as a second changed leaf.
t_case "(H9) requirements: the marker and the hash beside a pin survive the audit"
H9="$(_plant h9 requirements.txt 'ruff==0.9.0 ; python_version >= "3.9"\nblack==1.0.0 \\\n  --hash=sha256:abc\n')"
_run "${H9}" "${RUFF_REPORT}" --apply --managers pip_requirements
t_assert_eq "0" "${RC}" "apply must succeed"
t_assert_eq 'ruff==0.16.6 ; python_version >= "3.9"' "$(_req "${H9}" 1)" \
  "the pin moved and the marker beside it did not"
t_assert_eq 'black==1.0.0 \' "$(_req "${H9}" 2)" "the continued line is untouched"
t_assert_eq '  --hash=sha256:abc' "$(_req "${H9}" 3)" "and so is its hash"

t_case "(H9b) requirements: a plan aimed at the wrong pin is put back"
H9B="$(_plant h9b requirements.txt 'ruff==0.9.0\nblack==0.9.0\n')"
H9B_PLAN="${WORK}/h9b-plan.json"
printf '[{"file":"requirements.txt","line":1,"old":"black==0.9.0","new":"black==0.16.6","manager":"pip_requirements","dep":"ruff","cur":"==0.9.0","next":"==0.16.6"}]\n' \
  > "${H9B_PLAN}"
_apply_plan "${H9B}" "${H9B_PLAN}"
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "it changed [1].spec" "the audit names the record that moved"
t_assert_eq "black==0.9.0" "$(_req "${H9B}" 2)" "black is back at the bytes it had"
t_assert_eq "ruff==0.9.0" "$(_req "${H9B}" 1)" "and ruff never moved"

# (H9c) The parser splits a --hash continuation into opts, and expected() refuses because of it; both halves asserted.
t_case "(H9c) requirements: a --hash continuation is split off the specifier"
t_assert_eq "spec ==0.9.0 | opts --hash=sha256:abc" "$("${PY_ABS}" - "${SCRIPTS_DIR}" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
import renovate_audit

TEXT = "ruff==0.9.0 \\\n  --hash=sha256:abc\n"
one = renovate_audit.parse_requirements(TEXT)[0]
print("spec %s | opts %s" % (one["spec"], one["opts"]), end="")
PY
)" "the digest is a second thing about the requirement, not part of its version"

t_case "(H9d) requirements: a pin carrying digests is refused, not bumped past them"
t_assert_contains "$("${PY_ABS}" - "${SCRIPTS_DIR}" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
import renovate_audit

TEXT = "ruff==0.9.0 \\\n  --hash=sha256:abc\n"
_want, _leaves, why = renovate_audit.expected(
    "pip_requirements", TEXT, [("ruff", "==0.9.0", "==0.16.6", 1)])
print(why or "(SANCTIONED)", end="")
PY
)" "pinned by digest" "moving the version alone would leave the digests stale"

t_case "(H9e) and the SCRIPT reaches that refusal, with the digest in the reason"
H9E="$(_plant h9e requirements.txt 'ruff==0.9.0 \\\n  --hash=sha256:abc\n')"
_run "${H9E}" "${RUFF_REPORT}" --apply --managers pip_requirements
t_assert_eq "2" "${RC}" "the refusal is the RESULT, so the run exits 2"
t_assert_contains "${OUT}" "pinned by digest (--hash=sha256:abc)" \
  "the reason names the digests, not a value that 'moved'"
t_assert_contains "${OUT}" "re-run pip-compile" "and says who can recompute them"
t_assert_eq 'ruff==0.9.0 \' "$(_req "${H9E}" 1)" "the pin is untouched"
t_assert_eq '  --hash=sha256:abc' "$(_req "${H9E}" 2)" "and so is its digest"

# _deep_plan <out> <depth>: a newValue nesting <depth> arrays; see docs/dependency-updates.md#the-mechanics-of-a-refusal
_deep_plan() {
  "${PY_ABS}" - "$@" <<'PY'
import json
import sys

out, depth = sys.argv[1], int(sys.argv[2])
deep = "[" * depth + "]" * depth
tail = '1.6.0", "x": %s, "y": "yes' % deep
plan = [{"file": "package.json", "line": 3,
         "old": '    "left-pad": "1.1.0"',
         "new": '    "left-pad": "%s"' % tail,
         "manager": "npm", "dep": "left-pad", "cur": "1.1.0", "next": tail}]
with open(out, "w", encoding="utf-8") as fh:
    json.dump(plan, fh)
PY
}

_npm_repo() {
  _plant "$1" package.json \
    '{\n  "name": "fixture",\n  "dependencies": {\n    "left-pad": "1.1.0"\n  }\n}\n'
}

# (H10) Deep nesting must be a bounded refusal, not a RecursionError that skips the rollback.
t_case "(H10) a newValue nesting 1200 arrays is a REFUSAL, not a stack overflow"
H10="$(_npm_repo h10)"
H10_PLAN="${WORK}/h10-plan.json"
_deep_plan "${H10_PLAN}" 1200
_apply_plan "${H10}" "${H10_PLAN}"
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "nests past 200 levels" "and refuse by the declared ceiling"
t_assert_eq "0" "$(printf '%s' "${OUT}" | grep -c RecursionError)" \
  "no traceback: an exception here is what took the rollback with it"
t_assert_eq '    "left-pad": "1.1.0"' "$(_line "${H10}/package.json" 4)" \
  "the hostile write is gone"
t_assert_ok git -C "${H10}" diff --quiet HEAD

# (H11) The rollback must not rest on the audit finishing: a copied auditor that raises is injected.
t_case "(H11) an auditor that RAISES still puts every file back"
H11="$(_npm_repo h11)"
H11_PLAN="${WORK}/h11-plan.json"
# A CORRECT plan, so every pre-flight passes and the file really is written.
printf '[{"file":"package.json","line":3,"old":"    \\"left-pad\\": \\"1.1.0\\"","new":"    \\"left-pad\\": \\"1.6.0\\"","manager":"npm","dep":"left-pad","cur":"1.1.0","next":"1.6.0"}]\n' \
  > "${H11_PLAN}"
BROKEN="${WORK}/broken-auditor"
mkdir -p "${BROKEN}"
cp "${SCRIPTS_DIR}/renovate_planner.py" "${SCRIPTS_DIR}/renovate_locator.py" \
   "${SCRIPTS_DIR}/renovate_audit.py" "${SCRIPTS_DIR}/renovate_cmake.py" "${BROKEN}/"
cat >> "${BROKEN}/renovate_audit.py" <<'PY'


def audit(*_args, **_kwargs):
    raise MemoryError("the auditor died on its way to a verdict")
PY
OUT="$(cd "${BROKEN}" && "${PY_ABS}" renovate_planner.py edit "${H11}" "${H11_PLAN}" 2>&1)"
RC=$?
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "the audit itself raised MemoryError" "and name what raised"
t_assert_contains "${OUT}" "back at the bytes it had" "and say the file went back"
t_assert_eq '    "left-pad": "1.1.0"' "$(_line "${H11}/package.json" 4)" \
  "the write is undone even though no verdict was ever reached"
t_assert_ok git -C "${H11}" diff --quiet HEAD

# (H12) A key written twice resolves last-wins for both readers, so the duplicate itself must be refused.
t_case "(H12) a pubspec declaring one dep twice: both readers agree, and it is refused"
H12="$(_plant h12 pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n  http: 1.1.0\n')"
t_assert_eq "4   http: 1.6.0" \
  "$(_locator_says pub "${H12}/pubspec.yaml" http 1.1.0 1.6.0)" \
  "the locator picks the LAST one, which is what PyYAML resolves it to as well"
_parser_refuses "${H12}" "${A_REPORT}" pub "declares 'http' twice"
t_assert_contains "${OUT}" "contradicts itself" "and says why that is not editable"
t_assert_eq "  http: 1.1.0" "$(_pub "${H12}" 3)" "the shadowed copy is untouched"
t_assert_eq "  http: 1.1.0" "$(_pub "${H12}" 4)" "and so is the one both readers picked"

# Asserted at the module: through the script the locator refuses json and cargo earlier, on a count mismatch.
t_case "(H12b) json and toml refuse a repeated key too, each by its own parser"
t_assert_contains "$("${PY_ABS}" - "${SCRIPTS_DIR}" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
import renovate_audit

TEXT = '{"name":"f","dependencies":{"left-pad":"1.1.0","left-pad":"1.2.0"}}'
try:
    renovate_audit.parse("npm", TEXT)
    print("(PARSED)", end="")
except renovate_audit.Unreadable as exc:
    print(exc, end="")
PY
)" "declares 'left-pad' twice" "json takes last-wins as silently as PyYAML does"
t_assert_contains "$("${PY_ABS}" - "${SCRIPTS_DIR}" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
import renovate_audit

TEXT = '[dependencies]\nserde = "1.0"\nserde = "1.1"\n'
try:
    renovate_audit.parse("cargo", TEXT)
    print("(PARSED)", end="")
except renovate_audit.Unreadable as exc:
    print(exc, end="")
PY
)" "does not read as toml" "tomllib refuses one on its own, and is left to"

# (H13) --dry-run audits the text it would write, so its reason must match --apply's word for word.
t_case "(H13) --dry-run predicts the post-write refusal, in the same words"
H13="$(_npm_repo h13)"
H13_REPORT="${WORK}/h13.json"
_report "${H13_REPORT}" npm package.json left-pad 1.1.0 '1.6.0\", \"evil\": \"yes'
_run "${H13}" "${H13_REPORT}" --apply --dry-run --managers npm
H13_DRY_RC="${RC}"
H13_DRY="$(printf '%s\n' "${OUT}" | grep 'changed the SHAPE')"
_run "${H13}" "${H13_REPORT}" --apply --managers npm
t_assert_eq "${RC}" "${H13_DRY_RC}" "--dry-run exits what --apply exits"
t_assert_eq "1" "${H13_DRY_RC}" "and that is a refusal with nothing written"
t_assert_eq "$(printf '%s\n' "${OUT}" | grep 'changed the SHAPE')" "${H13_DRY}" \
  "and gives the same reason, word for word"
t_assert_contains "${H13_DRY}" "1 appeared (dependencies.evil)" \
  "which names the key the newValue would have injected"
t_assert_eq '    "left-pad": "1.1.0"' "$(_line "${H13}/package.json" 4)" \
  "and neither run wrote anything"
t_assert_ok git -C "${H13}" diff --quiet HEAD

# (H14) Put back includes the mtime, since make and ninja read a fresh one as a change; asserted on the planner alone.
t_case "(H14) a rolled-back file keeps its mtime, not just its bytes"
H14="$(_plant h14 pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n  other_pkg: 1.1.0\n')"
touch -d '2001-02-03 04:05:06' "${H14}/pubspec.yaml"
H14_WAS="$(stat -c '%y' "${H14}/pubspec.yaml")"
H14_PLAN="${WORK}/h14-plan.json"
printf '[{"file":"pubspec.yaml","line":3,"old":"  other_pkg: 1.1.0","new":"  other_pkg: 1.6.0","manager":"pub","dep":"http","cur":"1.1.0","next":"1.6.0"}]\n' \
  > "${H14_PLAN}"
_apply_plan "${H14}" "${H14_PLAN}"
t_assert_eq "1" "${RC}" "the plan is the wrong-line one, so the run must FAIL"
t_assert_eq "${H14_WAS}" "$(stat -c '%y' "${H14}/pubspec.yaml")" \
  "the file was put back, and putting back means the times too"
t_assert_eq "  other_pkg: 1.1.0" "$(_pub "${H14}" 4)" "the bytes went back as well"

t_summary
