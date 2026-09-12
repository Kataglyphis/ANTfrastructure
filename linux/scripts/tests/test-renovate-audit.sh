#!/usr/bin/env bash
# Tests for renovate_audit.py -- the half that does not trust the locator.
# The world these cases run in is renovate-fixtures.sh beside this file; the
# cases that grade the locator itself are test-renovate-local.sh.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/renovate-fixtures.sh"
# The three python modules under test are read straight out of linux/scripts:
# this suite runs the LOCATOR on its own to show it is still wrong, and the
# planner's apply half on its own to hand it a plan that is wrong on purpose.
SCRIPTS_DIR="${TESTS_DIR}/.."

# --------------------------------------------------------------------------
# The sixth wave, and a change of KIND rather than another round of fixtures.
# The cases below do not ask the locator to get better; they let it be WRONG
# and check the RESULT against a real parser. The reasoning, the three defects
# that forced it and the decisions taken are one page:
# docs/dependency-updates.md#the-edit-is-audited-by-a-real-parser
#
# Every case asserts TWO things, and the second is the point: that the run
# refused, AND that the locator alone still picks the wrong line.
# --------------------------------------------------------------------------

# _locator_says <manager> <file> <dep> <old> <new> -> "<line> <that line rewritten>"
# for each line renovate_locator.py ALONE would write, or "<verdict> <reason>".
# It writes nothing; it is the independent reading of the locator that lets a
# case state what the locator still does.
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

# _apply_plan <root> <plan.json> -- the planner's apply half over a plan written
# by hand. That is how a case makes the locator wrong on purpose without
# monkey-patching it: the plan is the boundary the two halves meet at, so a plan
# naming the wrong line IS "the locator got it wrong", injected honestly.
_apply_plan() {
  OUT="$(cd "${SCRIPTS_DIR}" && "${PY_ABS}" renovate_planner.py edit "$1" "$2" 2>&1)"
  RC=$?
  return 0
}

# _parser_refuses <repo> <report> <manager> <reason>
# The shape every refusal case below shares: run --apply, and demand that the
# update was refused for exactly this reason AND that the EXIT CODE says so.
# What each case then asserts about its own file stays with the case -- that is
# the part a reader has to see, and folding it in would hide which case asserts
# what.
#
# rc 2, not 0. Until 2026-09-10 every case here asserted 0 -- the same code a run
# with nothing behind gives -- so the suite was pinning the exact ambiguity a
# caller cannot live with. docs/dependency-updates.md#what-a-caller-branches-on
_parser_refuses() {
  _run "$1" "$2" --apply --managers "$3"
  t_assert_eq "2" "${RC}" "the refusal is the RESULT, so the run exits 2"
  t_assert_contains "${OUT}" "$4" "the refusal is the parser's, and it says why"
}

# (H1) A YAML ANCHOR on the dependencies key. `dependencies: &deps` puts a value
# after the colon, so the locator's line reader never opens the mapping under it
# and the whole section vanishes from its view -- leaving dependency_overrides
# as the only pub section it can see, and that entry as the one it rewrites.
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

# An ALIAS is the other half of the same decision. One node reachable at two
# paths cannot be edited at one of them: the bytes are shared, so a rewrite
# moves both. Paths are therefore what gets counted, not nodes -- and the run
# refuses rather than pretend the blast radius was the one line it wrote.
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

# (H2) A UTF-8 BOM before the first TOML table header. tomllib rejects a BOM
# outright, so it is stripped on BOTH sides of the comparison -- it is an
# encoding artefact of the byte stream, not a member of the grammar, and no
# construct can span it. The locator has no such rule: the BOM defeats its
# `[project]` match, the table it thinks it is in is the one BEFORE it, and the
# [dependency-groups] entry is what it ends up rewriting.
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

# (H3) YAML 1.2 lets a block scalar header write the indentation indicator and
# the chomping indicator in EITHER order, so `|2-` is `|-2`. The locator's
# header pattern accepts only one of the two spellings, reads the block's body
# as document structure, and rewrites a workflow that is being PRINTED.
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

# (H4) The post-write half, with the locator wrong ON PURPOSE. The file declares
# `http` exactly once, so every pre-flight passes and the edit IS written; only
# reading the file back and parsing it can catch where it landed.
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

# (H5) The report is JSON another program wrote, and `newValue` goes into the
# file as text. A value carrying a `"` closes the JSON string it lands in and
# opens a second key -- an INJECTION, and one no pre-flight over the file as it
# stands can see, because the file as it stands is fine.
t_case "(H5) a newValue carrying a quote injects a key, and the audit undoes it"
H5="$(_plant h5 package.json '{\n  "name": "fixture",\n  "dependencies": {\n    "left-pad": "1.1.0"\n  }\n}\n')"
H5_REPORT="${WORK}/h5.json"
# The value is JSON-ESCAPED here, so _report's printf carries it through as
# the string `1.6.0", "evil": "yes` -- one owner for the report shape, and
# the hostile value spelled where the reader can see it.
_report "${H5_REPORT}" npm package.json left-pad 1.1.0 '1.6.0\", \"evil\": \"yes'
_run "${H5}" "${H5_REPORT}" --apply --managers npm
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "changed the SHAPE of the file" "the audit says what it saw"
t_assert_contains "${OUT}" "1 appeared (dependencies.evil)" "and names the injected key"
t_assert_eq '    "left-pad": "1.1.0"' "$(_line "${H5}/package.json" 4)" \
  "the manifest is back at the bytes it had"
t_assert_ok git -C "${H5}" diff --quiet HEAD

# (H6) A manifest that does not parse BEFORE the edit cannot be audited, and
# this tool will not write into one. Refusing is the decision: writing a value
# into a file whose meaning cannot be read is what the five waves kept doing.
t_case "(H6) a manifest that does not parse is refused, not written into"
H6="$(_plant h6 pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\nbroken: [unclosed\n')"
t_assert_eq "3   http: 1.6.0" \
  "$(_locator_says pub "${H6}/pubspec.yaml" http 1.1.0 1.6.0)" \
  "the locator is happy to rewrite line 3 of a file it cannot read"
_parser_refuses "${H6}" "${A_REPORT}" pub "PyYAML cannot read it"
t_assert_eq "  http: 1.1.0" "$(_pub "${H6}" 3)" "nothing written"

# (H7) A manager the locator can EDIT but nothing can VERIFY would be a hole
# exactly where this module exists to close one. The two tables are asserted
# equal rather than eyeballed, so adding a finder without a parser fails here.
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

# (H8) Without a real YAML parser there is no guarantee to rest on, so the run
# ends saying so. A fallback to the line-level reading would be the one answer
# this whole wave exists to remove.
t_case "(H8) a python with no PyYAML refuses the run instead of falling back"
H8="$(_plant h8 pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n')"
NO_YAML="${WORK}/no-yaml"
mkdir -p "${NO_YAML}"
printf 'raise ImportError("PyYAML is not installed in this fixture")\n' \
  > "${NO_YAML}/yaml.py"
RUN_PYTHONPATH="${NO_YAML}" _parser_refuses "${H8}" "${A_REPORT}" pub \
  "PyYAML is not installed for this python"
t_assert_eq "  http: 1.1.0" "$(_pub "${H8}" 3)" "nothing written"

# (H9) requirements.txt has no standard parser, so this tool ships one: the
# ordered list of what the file asks pip for, with each requirement split into
# name, extras, specifier and tail. Splitting is what makes the diff mean
# something -- rewriting the version moves ONE field, and a write that also
# disturbed the marker or the hash shows up as a second changed leaf.
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

# (H9c) `pip-compile --generate-hashes` writes the digests onto a continuation of
# the requirement, and pip joins them back on. The parser cuts them off as
# `opts` -- and that split is what lets this tool SEE them and refuse.
#
# This decision used to be argued in the docs and reachable by nothing: the
# locator read `ruff==0.9.0 \` as the value `==0.9.0 \`, matched no reported
# current value, and refused the file one step earlier with the wrong reason
# ("something moved") for a pin that had not moved. Both halves are asserted
# here, because either alone would let the other rot: the parser SPLITS the
# digest off the specifier, and expected() then refuses BECAUSE of it.
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

# --------------------------------------------------------------------------
# The seventh wave. Not the parsing -- the MECHANICS of a refusal: an audit that
# raises, a key written twice, and a plan whose --dry-run did not predict its
# own --apply. Each case below is a defect MEASURED on 2026-09-10, with the
# fixture that found it. docs/dependency-updates.md#the-mechanics-of-a-refusal
# --------------------------------------------------------------------------
# _deep_plan <out> <depth> -- a plan whose newValue nests <depth> arrays inside
# the package.json string it lands in. json parses that without complaint; the
# walk that compares the two documents is what used to die on it.
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

# (H10) The walk that compares two documents was RECURSIVE, and a newValue is
# text from a report another program wrote. 1200 nested arrays is a value json
# reads without complaint and python's own recursion limit will not survive
# walking: the RecursionError left renovate_audit.audit(), went past _put_back()
# and left the hostile write on disk at rc 1. Both halves are fixed and both are
# asserted -- a bounded refusal here, and the rollback under (H11) below.
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

# (H11) And the rollback must not rest on the audit finishing at all. The
# auditor is replaced by one that RAISES -- a copy of the three modules with
# renovate_audit.audit overridden, which is the honest injection: the real
# planner, a real write, and an auditor that dies on its way to a verdict.
t_case "(H11) an auditor that RAISES still puts every file back"
H11="$(_npm_repo h11)"
H11_PLAN="${WORK}/h11-plan.json"
# A CORRECT plan, so every pre-flight passes and the file really is written.
printf '[{"file":"package.json","line":3,"old":"    \\"left-pad\\": \\"1.1.0\\"","new":"    \\"left-pad\\": \\"1.6.0\\"","manager":"npm","dep":"left-pad","cur":"1.1.0","next":"1.6.0"}]\n' \
  > "${H11_PLAN}"
BROKEN="${WORK}/broken-auditor"
mkdir -p "${BROKEN}"
cp "${SCRIPTS_DIR}/renovate_planner.py" "${SCRIPTS_DIR}/renovate_locator.py" \
   "${SCRIPTS_DIR}/renovate_audit.py" "${BROKEN}/"
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

# (H12) A key written TWICE. YAML resolves it last-wins, and so does a line
# reader -- so the locator and the parser AGREE, the edit lands on the winner,
# and the file is left declaring `http` at two different values with the run
# reporting success. Measured 2026-09-10 at rc 0. The asymmetry is what proved
# it an oversight: a plan aimed at the SHADOWED copy was already caught, because
# the winner never moves.
t_case "(H12) a pubspec declaring one dep twice: both readers agree, and it is refused"
H12="$(_plant h12 pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n  http: 1.1.0\n')"
t_assert_eq "4   http: 1.6.0" \
  "$(_locator_says pub "${H12}/pubspec.yaml" http 1.1.0 1.6.0)" \
  "the locator picks the LAST one, which is what PyYAML resolves it to as well"
_parser_refuses "${H12}" "${A_REPORT}" pub "declares 'http' twice"
t_assert_contains "${OUT}" "contradicts itself" "and says why that is not editable"
t_assert_eq "  http: 1.1.0" "$(_pub "${H12}" 3)" "the shadowed copy is untouched"
t_assert_eq "  http: 1.1.0" "$(_pub "${H12}" 4)" "and so is the one both readers picked"

# The other two formats get the same answer from their own parsers, asserted at
# the module rather than through the script: json_strings and the cargo finder
# both SEE two declarations, so the locator refuses those one step earlier for a
# count mismatch and the parser's verdict would never be reached.
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

# (H13) --dry-run claimed to print "the exact writes this would make, and
# nothing else", and did not run the post-write audit -- so the hostile newValue
# of (H5) printed a CLEAN plan at rc 0 and --apply then refused. The pre-flight
# now audits the text the write WOULD produce, so the two agree. Both are run
# here and the reason is compared, because a dry run that merely also fails
# would satisfy the exit code without predicting anything.
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

# (H14) "back at the bytes it had" includes the TIMES. Until 2026-09-10 the
# planner restored the bytes and the mode and stamped the file with now: the
# preservation anyone saw came from renovate-local.sh's own `cp -p` copies, one
# layer up, so driving `renovate_planner.py edit` -- which is where the contract
# is written -- left a fresh mtime on a file whose edit had been undone. Every
# timestamp-driven tool downstream reads that as a change: make, ninja, cargo, a
# watcher. Asserted HERE, against the planner alone, because that is the layer
# the guarantee is claimed at.
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
