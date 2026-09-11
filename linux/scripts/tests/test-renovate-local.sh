#!/usr/bin/env bash
# Tests for renovate-local.sh + renovate_planner.py + renovate_locator.py -- the
# half Renovate cannot do. Every case runs the REAL script against a throwaway
# checkout, with the Renovate round trip replaced by the two documented inputs
# (RENOVATE_LOCAL_REPORT / RENOVATE_LOCAL_CONFIG): no network, no node, no live
# repository. The world those cases run in is renovate-fixtures.sh beside this
# file; the read-back wave is test-renovate-audit.sh.

# The eight lettered cases below are the ones that WITHDREW the previous apply
# engine, whose locator searched for the OLD VALUE and then claimed a line near
# something that named the dep. Each is red against that approach and green
# against locating by the manager's own syntax.
# docs/dependency-updates.md#how-one-value-gets-rewritten
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/renovate-fixtures.sh"

# (a) the pubspec other_pkg cascade, with a commit between applies
t_case "(a) pubspec: only the reported dep moves, and a second apply is a no-op"
A="$(_plant a pubspec.yaml 'name: fixture\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\ndependencies:\n  http: 1.1.0\n  other_pkg: 1.1.0\n')"
_run "${A}" "${A_REPORT}" --apply --managers pub
t_assert_eq "0" "${RC}" "apply #1 must succeed"
t_assert_eq "  http: 1.6.0" "$(_pub "${A}" 5)" "http moves"
t_assert_eq "  other_pkg: 1.1.0" "$(_pub "${A}" 6)" "other_pkg must NOT move"
_commit "${A}"
_run "${A}" "${A_REPORT}" --apply --managers pub
t_assert_eq "0" "${RC}" "apply #2 over the same report must succeed"
t_assert_contains "${OUT}" "already applied" "apply #2 reports DONE, structurally"
t_assert_eq "  other_pkg: 1.1.0" "$(_pub "${A}" 6)" \
  "apply #2 must still not touch other_pkg"
t_assert_eq "  http: 1.6.0" "$(_pub "${A}" 5)" "http stays where it is"

# (b) the three-step github-actions cascade
t_case "(b) workflow: three applies never walk past the reported step"
B="$(_plant b .github/workflows/ci.yml 'name: ci\non: [push]\njobs:\n  b:\n    steps:\n      - uses: actions/checkout@v4\n      - uses: actions/setup-node@v4\n      - uses: actions/upload-artifact@v4\n')"
for _pass in 1 2 3; do
  _run "${B}" "${B_REPORT}" --apply --managers github-actions
  t_assert_eq "0" "${RC}" "apply #${_pass} must succeed"
  t_assert_eq "      - uses: actions/checkout@v5" "$(_step "${B}" 6)" \
    "checkout at v5 after pass ${_pass}"
  t_assert_eq "      - uses: actions/setup-node@v4" "$(_step "${B}" 7)" \
    "setup-node untouched after pass ${_pass}"
  t_assert_eq "      - uses: actions/upload-artifact@v4" "$(_step "${B}" 8)" \
    "upload-artifact untouched after pass ${_pass}"
  _commit "${B}"
done

# (c) `http` vs `http_parser` in one pubspec
t_case "(c) pubspec: a longer name that starts with the dep is a different key"
C="$(_plant c pubspec.yaml 'name: fixture\ndependencies:\n  http_parser: 1.1.0\n  http: 1.1.0\n')"
# byte-identical to (a)'s report: same manager, file, dep and value pair.
C_REPORT="${A_REPORT}"
_run "${C}" "${C_REPORT}" --apply --managers pub
t_assert_eq "0" "${RC}" "apply must succeed"
t_assert_eq "  http_parser: 1.1.0" "$(_pub "${C}" 3)" "http_parser untouched"
t_assert_eq "  http: 1.6.0" "$(_pub "${C}" 4)" "http moved"

t_case "(c2) with only http_parser declared, a report naming http writes nothing"
C2="$(_plant c2 pubspec.yaml 'name: fixture\ndependencies:\n  http_parser: 1.1.0\n')"
_run "${C2}" "${C_REPORT}" --apply --managers pub
t_assert_eq "2" "${RC}" "the refusal is the RESULT, so the run exits 2 and never 0"
t_assert_contains "${OUT}" "no pub declaration of 'http'" "and refuses by name"
t_assert_eq "  http_parser: 1.1.0" "$(_pub "${C2}" 3)" "http_parser untouched"

# (d) `actions/checkout` vs `actions/checkout-extra` in one workflow
t_case "(d) workflow: checkout-extra is not checkout"
D="$(_plant d .github/workflows/ci.yml 'name: ci\njobs:\n  b:\n    steps:\n      - uses: actions/checkout-extra@v4\n      - uses: actions/checkout@v4\n')"
# byte-identical to (b)'s report: same manager, file, dep and value pair.
D_REPORT="${B_REPORT}"
_run "${D}" "${D_REPORT}" --apply --managers github-actions
t_assert_eq "0" "${RC}" "apply must succeed"
t_assert_eq "      - uses: actions/checkout-extra@v4" "$(_step "${D}" 5)" "extra untouched"
t_assert_eq "      - uses: actions/checkout@v5" "$(_step "${D}" 6)" "checkout moved"

t_case "(d2) with only checkout-extra used, a report naming checkout writes nothing"
D2="$(_plant d2 .github/workflows/ci.yml 'name: ci\njobs:\n  b:\n    steps:\n      - uses: actions/checkout-extra@v4\n')"
_run "${D2}" "${D_REPORT}" --apply --managers github-actions
t_assert_eq "2" "${RC}" "the refusal is the RESULT, so the run exits 2 and never 0"
t_assert_contains "${OUT}" "no github-actions declaration of 'actions/checkout'" \
  "and refuses by name"
t_assert_eq "      - uses: actions/checkout-extra@v4" \
  "$(_step "${D2}" 5)" "checkout-extra untouched"

# (e) a dep named only in a COMMENT above an unrelated pin
t_case "(e) requirements: a comment naming the dep declares nothing"
E="$(_plant e requirements.txt '# ruff is managed by renovate\nblack==0.9.0\n')"
E_REPORT="${RUFF_REPORT}"
_run "${E}" "${E_REPORT}" --apply --managers pip_requirements
t_assert_eq "2" "${RC}" "the refusal is the RESULT, so the run exits 2 and never 0"
t_assert_contains "${OUT}" "no pip_requirements declaration of 'ruff'" \
  "the refusal names the dep and the manager"
t_assert_eq "black==0.9.0" "$(_req "${E}" 2)" "black untouched"
t_assert_eq "# ruff is managed by renovate" "$(_req "${E}" 1)" \
  "the comment untouched"

# (f) two pre-commit hooks pinned to the SAME rev, report naming one
t_case "(f) pre-commit: the rev belonging to the named repo, and only that one"
F="$(_plant f .pre-commit-config.yaml 'repos:\n  - repo: https://github.com/astral-sh/ruff-pre-commit\n    rev: v0.9.0\n    hooks:\n      - id: ruff\n  - repo: https://github.com/other/thing\n    rev: v0.9.0\n    hooks:\n      - id: thing\n')"
F_REPORT="${WORK}/f.json"
_report "${F_REPORT}" pre-commit .pre-commit-config.yaml astral-sh/ruff-pre-commit v0.9.0 v0.16.6
_run "${F}" "${F_REPORT}" --apply --managers pre-commit
t_assert_eq "0" "${RC}" "apply must succeed"
t_assert_eq "    rev: v0.16.6" "$(_line "${F}/.pre-commit-config.yaml" 3)" "ruff hook moved"
t_assert_eq "    rev: v0.9.0" "$(_line "${F}/.pre-commit-config.yaml" 7)" "other hook untouched"

t_case "(f2) pre-commit: a comment between repo: and rev: does not break the block"
F2="$(_plant f2 .pre-commit-config.yaml 'repos:\n  - repo: https://github.com/astral-sh/ruff-pre-commit\n    # kept equal to pyproject\n    rev: v0.9.0\n    hooks:\n      - id: ruff\n')"
_run "${F2}" "${F_REPORT}" --apply --managers pre-commit
t_assert_eq "    rev: v0.16.6" "$(_line "${F2}/.pre-commit-config.yaml" 4)" "rev still found"

t_case "(f3) pre-commit: a rev: written AFTER the hooks: list still belongs to it"
F3="$(_plant f3 .pre-commit-config.yaml 'repos:\n  - repo: https://github.com/astral-sh/ruff-pre-commit\n    hooks:\n      - id: ruff\n      - id: ruff-format\n    rev: v0.9.0\n')"
_run "${F3}" "${F_REPORT}" --apply --managers pre-commit
t_assert_eq "0" "${RC}" "apply must succeed"
t_assert_eq "    rev: v0.16.6" "$(_line "${F3}/.pre-commit-config.yaml" 6)" \
  "the nested hooks sequence does not end the repo item"
t_assert_eq "      - id: ruff-format" "$(_line "${F3}/.pre-commit-config.yaml" 5)" \
  "the hook ids are untouched"

# (g) the same dep pinned on several lines -- refuse, and say so
t_case "(g) requirements: one reported update, two pins -- refused by name"
G="$(_plant g requirements.txt 'ruff==0.9.0\nblack==1.0.0\nruff==0.9.0\n')"
G_REPORT="${RUFF_REPORT}"
_run "${G}" "${G_REPORT}" --apply --managers pip_requirements
t_assert_eq "2" "${RC}" "the refusal is the RESULT, so the run exits 2 and never 0"
t_assert_contains "${OUT}" "which one the report means is not knowable" \
  "the refusal says why"
t_assert_contains "${OUT}" "line 1,3" "the refusal names BOTH lines"
t_assert_eq "ruff==0.9.0" "$(_req "${G}" 1)" "line 1 untouched"
t_assert_eq "ruff==0.9.0" "$(_req "${G}" 3)" "line 3 untouched"

t_case "(g2) two pins AND two reported occurrences: both move, no guess left"
G2="$(_plant g2 requirements.txt 'ruff==0.9.0\nblack==1.0.0\nruff==0.9.0\n')"
G2_REPORT="${WORK}/g2.json"
_report "${G2_REPORT}" pip_requirements requirements.txt ruff ==0.9.0 ==0.16.6 2
_run "${G2}" "${G2_REPORT}" --apply --managers pip_requirements
t_assert_eq "0" "${RC}" "apply must succeed"
t_assert_eq "ruff==0.16.6" "$(_req "${G2}" 1)" "first pin moved"
t_assert_eq "black==1.0.0" "$(_req "${G2}" 2)" "black untouched"
t_assert_eq "ruff==0.16.6" "$(_req "${G2}" 3)" "second pin moved"

# (h) requirements.txt name normalisation
t_case "(h) requirements: foo-bar in the report is Foo_Bar in the file"
H="$(_plant h requirements.txt 'Foo_Bar==1.0.0\nfoo==2.0.0\n')"
H_REPORT="${WORK}/h.json"
_report "${H_REPORT}" pip_requirements requirements.txt foo-bar ==1.0.0 ==1.4.0
_run "${H}" "${H_REPORT}" --apply --managers pip_requirements
t_assert_eq "0" "${RC}" "apply must succeed"
t_assert_eq "Foo_Bar==1.4.0" "$(_req "${H}" 1)" "Foo_Bar moved"
t_assert_eq "foo==2.0.0" "$(_req "${H}" 2)" "foo untouched"

# The value must be ON the located line (property 3)
t_case "a declaration carrying an unexpected value is a refusal, not a rewrite"
V="$(_plant v pubspec.yaml 'name: fixture\ndependencies:\n  http: 2.0.0\n')"
_run "${V}" "${A_REPORT}" --apply --managers pub
t_assert_eq "2" "${RC}" "the refusal is the RESULT, so the run exits 2 and never 0"
t_assert_contains "${OUT}" "something moved, so nothing is written" "the reason is exact"
t_assert_contains "${OUT}" "3:2.0.0" "the refusal shows the line and what it carries"
t_assert_eq "  http: 2.0.0" "$(_pub "${V}" 3)" "nothing written"

t_case "a dep declared as a nested map carries no version, and is refused"
N="$(_plant n pubspec.yaml 'name: fixture\ndependencies:\n  http:\n    sdk: flutter\n')"
_run "${N}" "${A_REPORT}" --apply --managers pub
t_assert_contains "${OUT}" "(no value)" "the refusal says the line carries no value"
t_assert_eq "    sdk: flutter" "$(_pub "${N}" 4)" "the nested key untouched"

# A manager with no exact locator refuses; it never falls back to a text search
t_case "an unparsed manager is a refusal, never a fallback"
U="$(_plant u Dockerfile 'FROM ubuntu:22.04\nRUN true\n')"
U_REPORT="${WORK}/u.json"
_report "${U_REPORT}" dockerfile Dockerfile ubuntu 22.04 26.04
_run "${U}" "${U_REPORT}" --apply --managers dockerfile
t_assert_eq "2" "${RC}" "the refusal is the RESULT, so the run exits 2 and never 0"
t_assert_contains "${OUT}" "no exact locator for manager 'dockerfile'" "it says so by name"
t_assert_eq "FROM ubuntu:22.04" "$(_line "${U}/Dockerfile" 1)" "the Dockerfile untouched"

# --dry-run: file, line NUMBER, and the exact before/after text
t_case "--dry-run prints file, line number and both texts, and writes nothing"
P="$(_plant p pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n  other_pkg: 1.1.0\n')"
_run "${P}" "${A_REPORT}" --apply --dry-run --managers pub
t_assert_eq "0" "${RC}" "--dry-run must succeed"
t_assert_contains "${OUT}" "pubspec.yaml:3" "the plan names file and line NUMBER"
t_assert_contains "${OUT}" "-   http: 1.1.0" "the line as it stands"
t_assert_contains "${OUT}" "+   http: 1.6.0" "the line as it would stand"
t_assert_eq "  http: 1.1.0" "$(_pub "${P}" 3)" "--dry-run wrote nothing"

# cargo, npm and pep621: the shapes the fleet's manifests actually use
t_case "cargo: a bare string, an inline table and a [dependencies.<dep>] table"
K="$(_repo k)"
printf '[package]\nname = "fixture"\n\n[dependencies]  # trailing comment on the header\nserde = "=1.0.100"\nserde_json = "=1.0.100"\ntokio = { version = "=1.0.100", features = ["full"] }\n\n[dev-dependencies.anyhow]\nversion = "=1.0.100"\n' \
  > "${K}/Cargo.toml"
printf '# placeholder\n' > "${K}/Cargo.lock"
_commit "${K}"
K_REPORT="${WORK}/k.json"
while IFS=' ' read -r _dep _at; do
  [ -n "${_dep}" ] || continue
  _report "${K_REPORT}" cargo Cargo.toml "${_dep}" =1.0.100 =1.0.229
  _run_stubbed "${K}" "${K_REPORT}" --apply --managers cargo
  t_assert_eq "0" "${RC}" "cargo apply for ${_dep} must succeed"
  t_assert_contains "$(_cargo_line "${K}" "${_at}")" "1.0.229" "${_dep} moved on line ${_at}"
  _commit "${K}"
done <<'CARGOCASES'
serde 5
tokio 7
anyhow 10
CARGOCASES
t_assert_eq 'serde_json = "=1.0.100"' "$(_cargo_line "${K}" 6)" "serde_json untouched"
t_assert_contains "$(_cargo_line "${K}" 7)" 'features = ["full"]' \
  "the inline table's other keys survive"

t_case "npm: the key in the right dependencies object, and in no other"
M="$(_plant m package.json '{\n  "name": "fixture",\n  "scripts": {\n    "left-pad": "1.1.0"\n  },\n  "custom": [\n    {\n      "dependencies": {\n        "left-pad": "1.1.0"\n      }\n    }\n  ],\n  "dependencies": {\n    "left-pad": "1.1.0"\n  }\n}\n')"
M_REPORT="${WORK}/m.json"
_report "${M_REPORT}" npm package.json left-pad 1.1.0 1.6.0
_run "${M}" "${M_REPORT}" --apply --managers npm
t_assert_eq "0" "${RC}" "npm apply must succeed"
t_assert_eq '    "left-pad": "1.1.0"' "$(_line "${M}/package.json" 4)" \
  "the scripts entry is not a dependency"
t_assert_eq '        "left-pad": "1.1.0"' "$(_line "${M}/package.json" 9)" \
  "nor is a dependencies object nested inside an array"
t_assert_eq '    "left-pad": "1.6.0"' "$(_line "${M}/package.json" 14)" "the dependency moved"

t_case "pep621: a keyword that spells a package name is not a pin"
Y="$(_plant y pyproject.toml '[project]\nname = "fixture"\nkeywords = ["ruff", "linting"]\ndependencies = [\n  "ruff==0.9.0",\n  "ruff-extra==0.9.0",\n]\n')"
Y_REPORT="${WORK}/y.json"
_report "${Y_REPORT}" pep621 pyproject.toml ruff ==0.9.0 ==0.16.6
_run "${Y}" "${Y_REPORT}" --apply --managers pep621
t_assert_eq "0" "${RC}" "pep621 apply must succeed"
t_assert_eq 'keywords = ["ruff", "linting"]' "$(_line "${Y}/pyproject.toml" 3)" \
  "the keywords array untouched"
t_assert_eq '  "ruff==0.16.6",' "$(_line "${Y}/pyproject.toml" 5)" "the pin moved"
t_assert_eq '  "ruff-extra==0.9.0",' "$(_line "${Y}/pyproject.toml" 6)" "ruff-extra untouched"

# Line endings: a CRLF checkout stays CRLF, and only the value changes
t_case "a CRLF manifest keeps its CRLF, and every other byte on the line"
R="$(_plant r pubspec.yaml 'name: fixture\r\ndependencies:\r\n  http: 1.1.0  # pinned\r\n')"
_run "${R}" "${A_REPORT}" --apply --managers pub
t_assert_eq "0" "${RC}" "apply must succeed on a CRLF file"
t_assert_eq '  http: 1.6.0  # pinned' "$(_pub "${R}" 3 | tr -d '\r')" \
  "the trailing comment survives"
t_assert_eq "3" "$(tr -cd '\r' < "${R}/pubspec.yaml" | wc -c | tr -d ' ')" \
  "all three CRs are still there"

# Lockfiles: refused up front when the tool is missing, run when it is there
t_case "a missing lock tool refuses BEFORE anything is written"
L="$(_cargo_repo l)"
L_REPORT="${WORK}/l.json"
_report "${L_REPORT}" cargo Cargo.toml serde =1.0.100 =1.0.229
t_assert_eq "" "$(PATH="${BARE_PATH}" bash -c 'command -v cargo' || true)" \
  "the fixture PATH must genuinely have no cargo"
_run "${L}" "${L_REPORT}" --apply --managers cargo
t_assert_eq "1" "${RC}" "the run must FAIL, not warn"
t_assert_contains "${OUT}" "needs 'cargo', which is not on this PATH" "it names the tool"
t_assert_contains "${OUT}" "Cargo.lock" "it names the lockfile"
t_assert_eq 'serde = "=1.0.100"' "$(_cargo_line "${L}" 5)" \
  "the manifest is untouched -- the refusal came first"

t_case "with the tool present the manifest is written and the lock command runs"
: > "${ARGV_LOG}"
_run_stubbed "${L}" "${L_REPORT}" --apply --managers cargo
t_assert_eq "0" "${RC}" "apply must succeed"
t_assert_eq 'serde = "=1.0.229"' "$(_cargo_line "${L}" 5)" "the manifest moved"
t_assert_eq "cargo | update -p serde | l" "$(cat "${ARGV_LOG}")" \
  "cargo update -p <dep> ran in the manifest's own directory"

t_case "a manifest with no lockfile in the tree needs no tool"
W="$(_plant w requirements.txt 'ruff==0.9.0\n')"
W_REPORT="${RUFF_REPORT}"
_run "${W}" "${W_REPORT}" --apply --managers pip_requirements
t_assert_eq "0" "${RC}" "apply must succeed with no lock tool on PATH"
t_assert_contains "${OUT}" "none of the edited manifests has a lockfile" "and it says so"

t_case "--dry-run names the lockfile that would be refreshed, and runs nothing"
L2="$(_cargo_repo l2)"
: > "${ARGV_LOG}"
_run_stubbed "${L2}" "${L_REPORT}" --apply --dry-run --managers cargo
t_assert_contains "${OUT}" "Cargo.lock via cargo" "the lock job is in the plan"
t_assert_eq "" "$(cat "${ARGV_LOG}")" "--dry-run ran no lock tool"
t_assert_eq 'serde = "=1.0.100"' "$(_cargo_line "${L2}" 5)" "--dry-run wrote nothing"

# The pre-flight the manifest half inherits from the gitlink half
t_case "a dirty manifest refuses the whole run"
DZ="$(_plant dz pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n')"
printf 'name: fixture\ndependencies:\n  http: 1.1.0\n# edited by hand\n' > "${DZ}/pubspec.yaml"
_run "${DZ}" "${A_REPORT}" --apply --managers pub
t_assert_eq "1" "${RC}" "the run must fail"
t_assert_contains "${OUT}" "these paths have local changes" "the refusal explains itself"
t_assert_contains "${OUT}" "pubspec.yaml" "and names the file"
t_assert_eq "  http: 1.1.0" "$(_pub "${DZ}" 3)" "nothing written"

# Manager detection from the tree, and the report table
t_case "with no --managers the tree's own files pick the managers"
T="$(_repo t)"
printf 'name: fixture\ndependencies:\n  http: 1.1.0\n' > "${T}/pubspec.yaml"
printf 'ruff==0.9.0\n' > "${T}/requirements.txt"
_commit "${T}"
_run "${T}" "${A_REPORT}"
t_assert_eq "0" "${RC}" "the report mode must succeed"
t_assert_contains "${OUT}" "pub  <- pubspec.yaml" "pub detected from the tree"
t_assert_contains "${OUT}" "pip_requirements  <- requirements.txt" "pip detected too"
t_assert_contains "${OUT}" "1 update(s) available" "the report table renders"

# A refusal in the repo's own Renovate config still wins
t_case "dependencyDashboardApproval sends an update to a human, unwritten"
Q="$(_plant q pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n')"
RUN_CONFIG="${REFUSE_CONFIG}" _run "${Q}" "${A_REPORT}" --apply --managers pub
t_assert_eq "2" "${RC}" "the refusal is the RESULT, so the run exits 2 and never 0"
t_assert_contains "${OUT}" "${REFUSE_WHY}" "the rule's description is printed"
t_assert_eq "  http: 1.1.0" "$(_pub "${Q}" 3)" "nothing written"

# --------------------------------------------------------------------------
# The second wave. Every case below is a defect that was MEASURED against this
# tool on 2026-09-10, with the fixture that found it. They are grouped by the
# property they hold, and each one writes something wrong -- or leaves the tree
# half-written -- against the code as it stood that morning.
# --------------------------------------------------------------------------
# (A) Containment. The report's packageFile is JSON someone else wrote.
t_case "(A) a report naming a file OUTSIDE the checkout writes nothing"
AB="$(_plant ab pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n')"
OUTSIDE="${WORK}/outside.yaml"
printf 'name: outside\ndependencies:\n  http: 1.1.0\n' > "${OUTSIDE}"
ABS_REPORT="${WORK}/abs.json"
_report "${ABS_REPORT}" pub "${OUTSIDE}" http 1.1.0 1.6.0
_run "${AB}" "${ABS_REPORT}" --apply --managers pub
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "is not a file inside" "and say the path left the checkout"
t_assert_eq "  http: 1.1.0" "$(_line "${OUTSIDE}" 3)" "the file outside is untouched"

t_case "(A2) and a report reaching out with .. writes nothing either"
DOTDOT_REPORT="${WORK}/dotdot.json"
_report "${DOTDOT_REPORT}" pub ../outside.yaml http 1.1.0 1.6.0
_run "${AB}" "${DOTDOT_REPORT}" --apply --managers pub
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "is not a file inside" "and name the escape"
t_assert_eq "  http: 1.1.0" "$(_line "${OUTSIDE}" 3)" "the file outside is untouched"
t_assert_eq "  http: 1.1.0" "$(_pub "${AB}" 3)" "and the repo's own file too"

# (B) The write itself. open(path, "w") truncates first.
t_case "(B) the manifest is REPLACED, so its mode survives and no temp is left"
BM="$(_plant bm pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n')"
chmod 640 "${BM}/pubspec.yaml"
_run "${BM}" "${A_REPORT}" --apply --managers pub
t_assert_eq "0" "${RC}" "apply must succeed"
t_assert_eq "  http: 1.6.0" "$(_pub "${BM}" 3)" "the value moved"
t_assert_eq "640" "$(stat -c '%a' "${BM}/pubspec.yaml")" "the file's own mode survived"
t_assert_eq "" "$(find "${BM}" -maxdepth 1 -name '.renovate*')" "no temp file left behind"

t_case "(B2) a manifest whose DIRECTORY cannot be written is refused, not written"
BD="$(_repo bd)"
mkdir -p "${BD}/app"
printf 'name: fixture\ndependencies:\n  http: 1.1.0\n' > "${BD}/app/pubspec.yaml"
_commit "${BD}"
BD_REPORT="${WORK}/bd.json"
_report "${BD_REPORT}" pub app/pubspec.yaml http 1.1.0 1.6.0
chmod 555 "${BD}/app"
_run "${BD}" "${BD_REPORT}" --apply --managers pub
chmod 755 "${BD}/app"
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "cannot write in the directory holding app/pubspec.yaml" \
  "the refusal names the directory and the file"
t_assert_eq "  http: 1.1.0" "$(_line "${BD}/app/pubspec.yaml" 3)" "nothing written"

# (C) One plan is one unit, and --dry-run runs the same pre-flight.
_cp_pair() {
  local d
  d="$(_repo "$1")"
  printf 'name: fixture\ndependencies:\n  http: 1.1.0\n' > "${d}/pubspec.yaml"
  mkdir -p "${d}/pkg"
  printf 'name: fixture\ndependencies:\n  http: 1.1.0\n' > "${d}/pkg/pubspec.yaml"
  _commit "${d}"
  printf '%s' "${d}"
}
CP="$(_cp_pair cp)"
CP_REPORT="${WORK}/cp.json"
_report_pair "${CP_REPORT}" pub http 1.1.0 1.6.0 pubspec.yaml pkg/pubspec.yaml

t_case "(C) two files in one plan, the second unwritable -- NEITHER is written"
chmod 444 "${CP}/pkg/pubspec.yaml"
_run "${CP}" "${CP_REPORT}" --apply --managers pub
chmod 644 "${CP}/pkg/pubspec.yaml"
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "nothing written, in any file" "the guard is per-RUN"
t_assert_eq "  http: 1.1.0" "$(_pub "${CP}" 3)" "the FIRST file of the plan is untouched"
t_assert_eq "  http: 1.1.0" "$(_line "${CP}/pkg/pubspec.yaml" 3)" "and so is the second"

t_case "(C2) --dry-run runs that pre-flight too, and PREDICTS the failure"
chmod 444 "${CP}/pkg/pubspec.yaml"
_run "${CP}" "${CP_REPORT}" --apply --dry-run --managers pub
chmod 644 "${CP}/pkg/pubspec.yaml"
t_assert_eq "1" "${RC}" "--dry-run must fail where --apply would"
t_assert_contains "${OUT}" "cannot write pkg/pubspec.yaml" "and name the file it cannot write"
t_assert_eq "  http: 1.1.0" "$(_pub "${CP}" 3)" "--dry-run wrote nothing"

# _sub_repo and SUB_REPORT -- the superproject-plus-manifest fixture these cases
# and the rollback cases in test-renovate-exit.sh both drive -- live in
# renovate-fixtures.sh. They were here until 2026-09-10, when the exit suite
# needed the same shape to prove the gitlink half is put back too, and a second
# copy of a submodule fixture is exactly the clone the duplication gate catches.

t_case "(C3) a plan spanning a gitlink and an unwritable manifest moves NO gitlink"
CS="$(_sub_repo cs)"
chmod 444 "${CS}/pubspec.yaml"
_run "${CS}" "${SUB_REPORT}" --apply --managers pub,git-submodules
chmod 644 "${CS}/pubspec.yaml"
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_eq "  http: 1.1.0" "$(_pub "${CS}" 3)" "the manifest is untouched"
t_assert_ok git -C "${CS}" diff --quiet HEAD -- sub

t_case "(C4) with that manifest writable the same plan does BOTH"
CS2="$(_sub_repo cs2)"
_run "${CS2}" "${SUB_REPORT}" --apply --managers pub,git-submodules
t_assert_eq "0" "${RC}" "apply must succeed"
t_assert_eq "  http: 1.6.0" "$(_pub "${CS2}" 3)" "the manifest moved"
t_assert_fails git -C "${CS2}" diff --quiet HEAD -- sub

# (D) A lock tool that EXISTS can still fail; the pre-flight cannot see that.
t_case "(D) a lock tool that FAILS puts every manifest and lock back"
DF="$(_repo df)"
mkdir -p "${DF}/a" "${DF}/b"
printf '[package]\nname = "a"\n\n[dependencies]\nserde = "=1.0.100"\n' > "${DF}/a/Cargo.toml"
printf '# lock-a\n' > "${DF}/a/Cargo.lock"
printf '[package]\nname = "b"\n\n[dependencies]\nserde = "=1.0.100"\n' > "${DF}/b/Cargo.toml"
printf '# lock-b\n' > "${DF}/b/Cargo.lock"
_commit "${DF}"
DF_REPORT="${WORK}/df.json"
_report_pair "${DF_REPORT}" cargo serde =1.0.100 =1.0.229 a/Cargo.toml b/Cargo.toml
# a cargo that MUTATES the lock and then fails -- exactly what a resolution
# conflict or a dead registry does, and what no pre-flight can predict.
FAIL_STUBS="${WORK}/fail-stubs"
mkdir -p "${FAIL_STUBS}"
printf '#!/usr/bin/env bash\nprintf "touched\\n" >> Cargo.lock\nexit 1\n' > "${FAIL_STUBS}/cargo"
chmod +x "${FAIL_STUBS}/cargo"
STUB_PATH="${FAIL_STUBS}:${BARE_PATH}" _run "${DF}" "${DF_REPORT}" --apply --managers cargo
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "put back to the bytes" "and say what it undid"
t_assert_eq 'serde = "=1.0.100"' "$(_line "${DF}/a/Cargo.toml" 5)" "manifest a is back"
t_assert_eq 'serde = "=1.0.100"' "$(_line "${DF}/b/Cargo.toml" 5)" "manifest b is back"
t_assert_eq "# lock-a" "$(cat "${DF}/a/Cargo.lock")" "lock a is back"
t_assert_eq "# lock-b" "$(cat "${DF}/b/Cargo.lock")" "lock b is back"

# (E) Which lock a manifest has is a question for the TREE.
_pep_repo() {
  local d
  d="$(_repo "$1")"
  printf '[project]\nname = "fixture"\ndependencies = [\n  "ruff==0.9.0",\n]\n' \
    > "${d}/pyproject.toml"
  shift
  local lock
  for lock in "$@"; do printf '# placeholder\n' > "${d}/${lock}"; done
  _commit "${d}"
  printf '%s' "${d}"
}
EP_REPORT="${WORK}/ep.json"
_report "${EP_REPORT}" pep621 pyproject.toml ruff ==0.9.0 ==0.16.6

t_case "(E) a pyproject beside a poetry.lock needs poetry, not the hardcoded uv"
EP="$(_pep_repo ep poetry.lock)"
_run "${EP}" "${EP_REPORT}" --apply --managers pep621
t_assert_eq "1" "${RC}" "the run must FAIL: poetry is not on the fixture PATH"
t_assert_contains "${OUT}" "needs 'poetry', which is not on this PATH" "it names the real tool"
t_assert_contains "${OUT}" "poetry.lock" "and the real lockfile"
t_assert_eq '  "ruff==0.9.0",' "$(_line "${EP}/pyproject.toml" 4)" "the manifest is untouched"

t_case "(E2) with poetry present the manifest moves and poetry lock runs"
: > "${ARGV_LOG}"
_run_stubbed "${EP}" "${EP_REPORT}" --apply --managers pep621
t_assert_eq "0" "${RC}" "apply must succeed"
t_assert_eq '  "ruff==0.16.6",' "$(_line "${EP}/pyproject.toml" 4)" "the manifest moved"
t_assert_eq "poetry | lock | ep" "$(cat "${ARGV_LOG}")" \
  "poetry lock ran in the manifest's own directory"

t_case "(E3) a pyproject beside TWO lockfiles is refused, never guessed"
EA="$(_pep_repo ea uv.lock poetry.lock)"
_run_stubbed "${EA}" "${EP_REPORT}" --apply --managers pep621
t_assert_eq "1" "${RC}" "the run must FAIL even with every tool present"
t_assert_contains "${OUT}" "sits beside uv.lock, poetry.lock" "it names both"
t_assert_eq '  "ruff==0.9.0",' "$(_line "${EA}/pyproject.toml" 4)" "nothing written"

# (F1) github-actions: a `uses:` that is not a step's. Each decoy is planted
# ALONE, because that is what makes the measurement: with one match in the file
# the old finder WROTE it, and with several it would have refused for a count
# mismatch and proved nothing. Two cases that differ only in the decoy share one
# assertion helper -- the copy the duplication gate catches.
#   _refuses_actions <repo> <decoy line> <that line, unchanged>
_refuses_actions() {
  _run "$1" "${B_REPORT}" --apply --managers github-actions
  t_assert_eq "2" "${RC}" "the refusal is the RESULT, so the run exits 2 and never 0"
  t_assert_contains "${OUT}" "no github-actions declaration of 'actions/checkout'" \
    "and refuses by name"
  t_assert_eq "$3" "$(_step "$1" "$2")" "the decoy is untouched"
}

t_case "(F1) workflow: a uses: printed inside a run: block is TEXT, not a step"
FA="$(_plant fa .github/workflows/ci.yml 'name: ci\njobs:\n  b:\n    steps:\n      - name: print a workflow\n        run: |\n          steps:\n            - uses: actions/checkout@v4\n')"
_refuses_actions "${FA}" 8 "            - uses: actions/checkout@v4"

t_case "(F1b) workflow: a with: input literally named uses is an input"
FB="$(_plant fb .github/workflows/ci.yml 'name: ci\njobs:\n  b:\n    steps:\n      - uses: actions/other@v1\n        with:\n          uses: actions/checkout@v4\n')"
_refuses_actions "${FB}" 7 "          uses: actions/checkout@v4"
t_assert_eq "      - uses: actions/other@v1" "$(_step "${FB}" 5)" "and the step it belongs to"

t_case "(F1c) and with both decoys beside the real step, only the step moves"
FC="$(_plant fc .github/workflows/ci.yml 'name: ci\njobs:\n  b:\n    steps:\n      - uses: actions/checkout@v4\n      - name: print a workflow\n        run: |\n          - uses: actions/checkout@v4\n      - uses: actions/other@v1\n        with:\n          uses: actions/checkout@v4\n')"
_run "${FC}" "${B_REPORT}" --apply --managers github-actions
t_assert_eq "0" "${RC}" "apply must succeed"
t_assert_eq "      - uses: actions/checkout@v5" "$(_step "${FC}" 5)" "the real step moved"
t_assert_eq "          - uses: actions/checkout@v4" "$(_step "${FC}" 8)" "the run: block did not"
t_assert_eq "          uses: actions/checkout@v4" "$(_step "${FC}" 11)" "nor did the with: input"

# (F2) pub: an unreadable form is a refusal, never a fallback to another site.
t_case "(F2) pub: a hosted: map refuses, and the dependency_overrides entry stays"
FD="$(_plant fd pubspec.yaml 'name: fixture\ndependencies:\n  http:\n    hosted:\n      name: http\n      url: https://pub.example\n    version: 1.1.0\ndependency_overrides:\n  http: 1.1.0\n')"
_run "${FD}" "${A_REPORT}" --apply --managers pub
t_assert_eq "2" "${RC}" "the refusal is the RESULT, so the run exits 2 and never 0"
t_assert_contains "${OUT}" "(no value)" "the refusal names the unreadable line"
t_assert_contains "${OUT}" "cannot read" "and says what is wrong with it"
t_assert_eq "    version: 1.1.0" "$(_pub "${FD}" 7)" "the nested version is untouched"
t_assert_eq "  http: 1.1.0" "$(_pub "${FD}" 9)" "and so is the dependency_overrides entry"

# (F3) cargo: a table whose LAST segment is `dependencies` is not one.
t_case "(F3) cargo: [package.metadata.dependencies] is not a dependency table"
FE="$(_repo fe)"
printf '[package]\nname = "fixture"\n\n[package.metadata.dependencies]\nserde = "=1.0.100"\n\n[dependencies]\nserde = "=1.0.100"\n' > "${FE}/Cargo.toml"
printf '# placeholder\n' > "${FE}/Cargo.lock"
_commit "${FE}"
FE_REPORT="${WORK}/fe.json"
_report "${FE_REPORT}" cargo Cargo.toml serde =1.0.100 =1.0.229
_run_stubbed "${FE}" "${FE_REPORT}" --apply --managers cargo
t_assert_eq "0" "${RC}" "apply must succeed"
t_assert_eq 'serde = "=1.0.100"' "$(_cargo_line "${FE}" 5)" "the metadata key is untouched"
t_assert_eq 'serde = "=1.0.229"' "$(_cargo_line "${FE}" 8)" "the real dependency moved"

t_case "(F3b) a dep named ONLY under [package.metadata] is refused by name"
FF="$(_repo ff)"
printf '[package]\nname = "fixture"\n\n[package.metadata.dependencies]\nserde = "=1.0.100"\n' \
  > "${FF}/Cargo.toml"
_commit "${FF}"
_run "${FF}" "${FE_REPORT}" --apply --managers cargo
t_assert_eq "2" "${RC}" "the refusal is the RESULT, so the run exits 2 and never 0"
t_assert_contains "${OUT}" "no cargo declaration of 'serde'" "and refuses by name"
t_assert_eq 'serde = "=1.0.100"' "$(_cargo_line "${FF}" 5)" "the metadata key is untouched"

# (F4) npm: which object a key sits in, tracked rather than assumed. The
# array-nested decoy lives in the npm case above, beside the `scripts` one --
# two cases planting near-identical package.json fixtures is the copy the
# duplication gate catches, and one fixture carrying every decoy reads better.
t_case "(F4b) npm: a manifest written on ONE line is read too"
FH="$(_plant fh package.json '{"name":"fixture","scripts":{"left-pad":"1.1.0"},"dependencies":{"left-pad":"1.1.0"}}\n')"
_run "${FH}" "${M_REPORT}" --apply --managers npm
t_assert_eq "0" "${RC}" "apply must succeed"
t_assert_eq '{"name":"fixture","scripts":{"left-pad":"1.1.0"},"dependencies":{"left-pad":"1.6.0"}}' \
  "$(_line "${FH}/package.json" 1)" "only the dependency moved"

# (G) cargo workspace inheritance: `{ workspace = true }` states no version.
t_case "(G) cargo: a workspace-inherited crate re-applies as DONE, not as a refusal"
GW="$(_repo gw)"
printf '[workspace]\nmembers = []\n\n[workspace.dependencies]\nclap = { version = "4.0.0", features = ["derive"] }\n\n[package]\nname = "fixture"\n\n[dependencies]\nclap = { workspace = true }\n' > "${GW}/Cargo.toml"
printf '# placeholder\n' > "${GW}/Cargo.lock"
_commit "${GW}"
GW_REPORT="${WORK}/gw.json"
_report "${GW_REPORT}" cargo Cargo.toml clap 4.0.0 4.6.0
_run_stubbed "${GW}" "${GW_REPORT}" --apply --managers cargo
t_assert_eq "0" "${RC}" "the first apply must succeed"
t_assert_eq 'clap = { version = "4.6.0", features = ["derive"] }' "$(_cargo_line "${GW}" 5)" \
  "the workspace pin moved"
t_assert_eq 'clap = { workspace = true }' "$(_cargo_line "${GW}" 11)" \
  "the member's inheriting line is untouched"
_commit "${GW}"
_run_stubbed "${GW}" "${GW_REPORT}" --apply --managers cargo
t_assert_eq "0" "${RC}" "the second apply must succeed"
t_assert_contains "${OUT}" "already applied" "and report DONE, structurally"

# --------------------------------------------------------------------------
# (H) The cleanliness check and a NESTED submodule. One question asked once per
# direction, because the fix is a single option and the way to get it wrong is
# to widen it: `--ignore-submodules=all` passes (H1) and (H2) and silently fails
# (H3), which is the gitlink --apply exists to move. What (H1) was measured
# doing before the option, on all four family consumers from WSL:
# docs/dependency-updates.md#the-nested-submodule-that-no-end-of-line-option-can-reach
# --------------------------------------------------------------------------
H_REPORT="${WORK}/h.json"
_report "${H_REPORT}" git-submodules .gitmodules sub main main

t_case "(H1) a dirty NESTED submodule does not refuse the parent's gitlink"
H1="$(_deep_repo h1)"
printf 'scribbled\n' >> "${H1}/sub/deep/d.txt"
_run "${H1}" "${H_REPORT}" --apply --dry-run --managers git-submodules
t_assert_eq "0" "${RC}" "the run must reach the plan, not a refusal"
t_assert_fails grep -q "these paths have local changes" <<<"${OUT}"
# The SECOND diff in classify_one needs the option too. Given it to the first
# call only, this tree comes back clean, falls through to the elif, and the
# eol-classifier -- which carries no --ignore-cr-at-eol either -- reads the same
# `-dirty` suffix as an end-of-line disagreement and refuses instead. Same
# false refusal, different message.
t_assert_fails grep -q "wrong git for this working tree" <<<"${OUT}"
t_assert_contains "${OUT}" "gitlink(s), moved to the tip" "the plan is printed instead"

t_case "(H2) the submodule's OWN tracked file, edited, still refuses"
H2="$(_deep_repo h2)"
printf 'edited by hand\n' > "${H2}/sub/f.txt"
_run "${H2}" "${H_REPORT}" --apply --dry-run --managers git-submodules
t_assert_eq "1" "${RC}" "a real local change must still stop the run"
t_assert_contains "${OUT}" "these paths have local changes" "and say why"
t_assert_contains "${OUT}" "sub" "naming the path"

t_case "(H3) a nested gitlink at another COMMIT still refuses -- =dirty, not =all"
H3="$(_deep_repo h3)"
printf 'deep two\n' > "${WORK}/deepstream-h3/d.txt"
_commit "${WORK}/deepstream-h3"
git -C "${H3}/sub/deep" fetch -q origin main
git -C "${H3}/sub/deep" checkout -q --detach "$(git -C "${WORK}/deepstream-h3" rev-parse main)"
t_assert_eq "1" "$(t_rc git -C "${H3}/sub" diff --quiet HEAD)" \
  "the fixture really did move the nested gitlink"
_run "${H3}" "${H_REPORT}" --apply --dry-run --managers git-submodules
t_assert_eq "1" "${RC}" "a MOVED nested gitlink is a real change and must refuse"
t_assert_contains "${OUT}" "these paths have local changes" "and say why"

t_case "(H4) the apply runs, and the nested submodule's uncommitted work survives"
H4="$(_deep_repo h4)"
printf 'scribbled\n' >> "${H4}/sub/deep/d.txt"
H4_BEFORE="$(_sub_at "${H4}")"
_run "${H4}" "${H_REPORT}" --apply --managers git-submodules
t_assert_eq "0" "${RC}" "the apply must succeed"
t_assert_contains "$(cat "${H4}/sub/f.txt")" "two" "the gitlink actually moved"
t_assert_fails test "${H4_BEFORE}" = "$(_sub_at "${H4}")"
t_assert_contains "$(cat "${H4}/sub/deep/d.txt")" "scribbled" \
  "ignoring the nested dirt for the DECISION must not destroy it"

t_summary
