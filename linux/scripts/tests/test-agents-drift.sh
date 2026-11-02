#!/usr/bin/env bash
# verify_agents_drift.py over fixture consumers, and its two callers; arguments select case groups. See docs/code-quality-tooling.md#agents-drift-agents-drift
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
HUB_ROOT="$(cd "${SCRIPTS}/../.." && pwd)"
GATE="${SCRIPTS}/verify_agents_drift.py"
PY="${PREFLIGHT_PYTHON:-python3}"
_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

_clean="${_work}/template/OxidANT"
mkdir -p "${_clean}/.github/workflows" "${_clean}/guide" "${_clean}/pkg" "${_clean}/crates/alpha/src" "${_clean}/Src/mod" "${_clean}/packages/dartish"
cat > "${_clean}/AGENTS.md" <<'MD'
# AGENTS.md

## 1. What this project is

pkg, crates/alpha, Src/mod and packages/dartish.

```
## 5. not a heading: fenced.yml
```

MD
sed -n 's/^## [1-6]\. .*/&/p' "${HUB_ROOT}/shared/templates/AGENTS.md.template" | sed 1d | while IFS= read -r heading; do
  printf '%s\n\n' "${heading}" >> "${_clean}/AGENTS.md"
  case "${heading}" in
    '## 5.'*) printf 'ci.yml alpha pkg-run other-bin native-tool\n\n' >> "${_clean}/AGENTS.md" ;;
  esac
done
printf 'name: ci\n' > "${_clean}/.github/workflows/ci.yml"
printf 'x = 1\n' > "${_clean}/pkg/__init__.py"
printf '[project]\nname = "p"\nversion = "0"\n[project.scripts]\npkg-run = "pkg:main"\n' > "${_clean}/pyproject.toml"
printf '[package]\nname = "alpha"\nversion = "0.0.0"\n[[bin]]\nname = "other-bin"\npath = "src/o.rs"\n' > "${_clean}/crates/alpha/Cargo.toml"
printf 'fn main() {}\n' > "${_clean}/crates/alpha/src/main.rs"
printf 'project(native)\nset(TOOL tool)\nadd_executable(${PROJECT_NAME}-${TOOL} a.c)\ninstall(TARGETS ${PROJECT_NAME}-${TOOL} RUNTIME DESTINATION bin)\nadd_executable(internal b.c)\n' > "${_clean}/CMakeLists.txt"
printf 'void f(void);\n' > "${_clean}/Src/mod/a.h"
printf 'name: dartish\n' > "${_clean}/packages/dartish/pubspec.yaml"
printf '# page\n' > "${_clean}/guide/page.md"
printf '[docs]\nbuild_list = "docs.list"\nsource = "guide"\n' > "${_clean}/quality-report.toml"
printf 'guide/page.md|page|Page\n' > "${_clean}/docs.list"
printf -- '- LAI-O4 open\n- LAI-O5 open\n' > "${_clean}/BACKLOG.md"
git -C "${_clean}" init -q
git -C "${_clean}" remote add origin https://example.invalid/Kataglyphis/OxidANT.git
git -C "${_clean}" -c core.autocrlf=false add -A

long="$(printf 'r%.0s' {1..41})"
# _copy: a fresh mutable copy of the clean consumer; the index comes with it, so a new file needs `git add`.
_copy() { local d; d="$(mktemp -d "${_work}/copy.XXXXXX")"; cp -a "${_clean}/." "${d}/"; printf '%s' "${d}"; }
_grade() { "${PY}" "${GATE}" --root "$1"; }
_add() { git -C "$1" add -A; }
# _red <dir> <check> <text>: the gate must exit 1 and print that check and text.
_red() {
  local out rc=0
  out="$(_grade "$1" 2>&1)" || rc=$?
  t_assert_eq 1 "${rc}" "$2 must fail"
  t_assert_contains "${out}" "$2: $3"
}

_group_basic() {
t_case "a consumer that names everything is green, and its JSON says 0"
t_assert_eq 0 "$(t_rc _grade "${_clean}")" "the clean fixture"
"${PY}" "${GATE}" --root "${_clean}" --json "${_work}/ok.json" >/dev/null
t_assert_eq 0 "$("${PY}" -c 'import json,sys; print(json.load(open(sys.argv[1]))["totals"]["findings"])' "${_work}/ok.json")" "totals.findings on a clean tree"
}

_group_section5() {
t_case "a workflow section 5 does not name fails, even when a fence or section 1 does"
d="$(_copy)"; printf 'name: new\n' > "${d}/.github/workflows/new.yml"; _add "${d}"
_red "${d}" section5-workflow "section 5 does not name workflow new.yml"
sed -i 's/^pkg, crates/new.yml pkg, crates/' "${d}/AGENTS.md"
_red "${d}" section5-workflow "section 5 does not name workflow new.yml"
d="$(_copy)"; printf 'name: x\n' > "${d}/.github/workflows/fenced.yml"; _add "${d}"
_red "${d}" section5-workflow "section 5 does not name workflow fenced.yml"
d="$(_copy)"; printf 'name: x\n' > "${d}/.github/workflows/ci2.yml"; _add "${d}"
sed -i 's/^ci.yml alpha/xci2.yml ci.yml alpha/' "${d}/AGENTS.md"
_red "${d}" section5-workflow "section 5 does not name workflow ci2.yml"
t_case "each kind of console script must be named in section 5"
for name in pkg-run other-bin alpha native-tool; do
  d="$(_copy)"; sed -i "s/^ci.yml alpha pkg-run other-bin native-tool$/$(printf 'ci.yml alpha pkg-run other-bin native-tool' | sed "s/\b${name}\b//")/" "${d}/AGENTS.md"
  _red "${d}" section5-script "section 5 does not name console script ${name}"
done
d="$(_copy)"; sed -i 's#^path = "src/o.rs"#path = "src/main.rs"#' "${d}/crates/alpha/Cargo.toml"
sed -i 's/^ci.yml alpha pkg-run/ci.yml pkg-run/' "${d}/AGENTS.md"
t_assert_eq 0 "$(t_rc _grade "${d}")" "a [[bin]] that claims src/main.rs leaves no binary named after the package"
d="$(_copy)"; printf 'add_executable(never_installed c.c)\n' >> "${d}/CMakeLists.txt"; _add "${d}"
t_assert_eq 0 "$(t_rc _grade "${d}")" "an executable that is not installed is no console script"
}

_group_section1() {
t_case "each kind of top-level unit must be named in section 1, not only elsewhere"
for pair in "pkg:pkg" "crates/alpha:crates/alpha" "Src/mod:Src/mod" "packages/dartish:packages/dartish"; do
  d="$(_copy)"; sed -i "s#^pkg, crates/alpha, Src/mod and packages/dartish.\$#$(printf 'pkg, crates/alpha, Src/mod and packages/dartish.' | sed "s#${pair%%:*}#gone#")#" "${d}/AGENTS.md"
  printf 'pkg crates/alpha Src/mod packages/dartish\n' >> "${d}/AGENTS.md"
  _red "${d}" section1-unit "section 1 does not name ${pair##*:}"
done
d="$(_copy)"; sed -i 's#^pkg, crates/alpha, #pkg, alpha, #' "${d}/AGENTS.md"
t_assert_eq 0 "$(t_rc _grade "${d}")" "a crate's package name is as good as its path"
}

_group_headings() {
t_case "a missing or reordered template heading fails"
d="$(_copy)"; sed -i '/^## 3\. /d' "${d}/AGENTS.md"
_red "${d}" headings "the headings must be, in order"
d="$(_copy)"; sed -i -e 's/^## 2\. /## TWO /' -e 's/^## 4\. \(.*\)$/## 4. \1 changed/' "${d}/AGENTS.md"
_red "${d}" headings "the headings must be, in order"
d="$(_copy)"; h6="$(sed -n '/^## 6\. /p' "${d}/AGENTS.md")"; sed -i '/^## 6\. /d' "${d}/AGENTS.md"
sed -i "s/^## 1\. /${h6}\n\n&/" "${d}/AGENTS.md"
_red "${d}" headings "the headings must be, in order"
}

_group_duplicates() {
t_case "a line over 40 characters repeated verbatim fails; exactly 40 does not"
d="$(_copy)"; printf '%s\n\n%s\n' "${long}" "${long}" >> "${d}/AGENTS.md"
_red "${d}" duplicate-line "repeats line"
d="$(_copy)"; short="$(printf 'r%.0s' {1..40})"; printf '%s\n\n%s\n' "${short}" "${short}" >> "${d}/AGENTS.md"
t_assert_eq 0 "$(t_rc _grade "${d}")" "40 characters is not longer than 40"
}

_group_docs() {
t_case "a docs page the build list leaves out fails; toctree stems and includes are understood"
d="$(_copy)"; printf '# new\n' > "${d}/guide/new.md"; _add "${d}"
_red "${d}" docs-page "the docs build list leaves out guide/new.md"
printf 'newer|new|New\n' >> "${d}/docs.list"
_red "${d}" docs-page "the docs build list leaves out guide/new.md"
d="$(_copy)"; mkdir -p "${d}/guide/_inc"; printf '# inc\n' > "${d}/guide/_inc/x.md"; _add "${d}"
t_assert_eq 0 "$(t_rc _grade "${d}")" "an include directory holds no pages"
d="$(_copy)"; printf '[docs]\nbuild_list = "index.rst"\nsource = "guide"\n' > "${d}/quality-report.toml"
printf '.. toctree::\n\n   page\n   Sub page <sub/two>\n' > "${d}/index.rst"; mkdir "${d}/guide/sub"; printf 'x\n' > "${d}/guide/sub/two.rst"; _add "${d}"
t_assert_eq 0 "$(t_rc _grade "${d}")" "a bare toctree stem and a titled entry both list a page"
sed -i 's/^   page$/   pages/' "${d}/index.rst"
_red "${d}" docs-page "the docs build list leaves out guide/page.md"
t_case "a broken declaration is unusable, never a pass"
d="$(_copy)"; rm "${d}/quality-report.toml"; _add "${d}"
t_assert_eq 2 "$(t_rc _grade "${d}")" "no quality-report.toml"
d="$(_copy)"; printf '[docs]\nbuild_list = "gone.txt"\nsource = "guide"\n' > "${d}/quality-report.toml"
t_assert_eq 2 "$(t_rc _grade "${d}")" "a declared build list that does not exist"
d="$(_copy)"; printf '[project\n' > "${d}/pyproject.toml"
t_assert_eq 2 "$(t_rc _grade "${d}")" "a malformed manifest"
}

_group_backlog() {
t_case "an open LAI ID of this repo's letter must be in BACKLOG.md; Done, foreign letters and prose mentions are not"
d="$(_copy)"; printf -- '- LAI-O4\n' > "${d}/BACKLOG.md"
_red "${d}" backlog-lai "open LAI-O5"
d="$(_copy)"; rm "${d}/BACKLOG.md"; _add "${d}"
_red "${d}" backlog-lai "open LAI-O4"
d="$(_copy)"; printf -- '- LAI-O5\n- LAI-O4\n- LAI-P3\n' > "${d}/BACKLOG.md"
t_assert_eq 0 "$(t_rc _grade "${d}")" "done rows such as LAI-O1 need no line, nor the other letters"
d="$(_copy)"; git -C "${d}" remote set-url origin https://example.invalid/x/OrchestrANT.git
_red "${d}" backlog-lai "open LAI-P3"
d="$(_copy)"; git -C "${d}" remote set-url origin https://example.invalid/x/Other; rm "${d}/BACKLOG.md"; _add "${d}"
t_assert_eq 0 "$(t_rc _grade "${d}")" "a repository without a letter owes no LAI line"
t_assert_eq "A1 B2 C3" "$(PYTHONPATH="${SCRIPTS}" "${PY}" - <<'PYEOF'
from verify_agents_drift import open_lai_ids

page = """prose LAI-Z9 stays closed
| LAI-D4 | Done 2026-10-30. | hub |
| LAI-A1 | work naming LAI-Y7 | repo |
| 2 NLP | LAI-B2, LAI-C3 | work |
"""
print(" ".join(i.removeprefix("LAI-") for i in open_lai_ids(page)))
PYEOF
)" "only an ID cell of a row without Done is open"
}

_group_json() {
t_case "the JSON counts findings per check, and carries the rows quality-report reads"
d="$(_copy)"; printf 'name: new\n' > "${d}/.github/workflows/new.yml"; _add "${d}"; printf -- '- LAI-O4\n' > "${d}/BACKLOG.md"
"${PY}" "${GATE}" --root "${d}" --json "${_work}/bad.json" >/dev/null
t_assert_eq "2 1 AGENTS.md" "$("${PY}" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["totals"]["findings"], d["totals"]["checks"]["backlog-lai"], d["items"][0]["path"])' "${_work}/bad.json")" "totals and items"
}

_group_hub() {
t_case "over the hub only the duplicate-line check runs, and the hub's AGENTS.md has none"
t_assert_eq 0 "$(t_rc "${PY}" "${GATE}")" "the hub reports 0 findings; its AGENTS.md has no numbered sections"
d="${_work}/hub"; mkdir -p "${d}/linux/scripts" "${d}/shared/templates" "${d}/docs"
cp "${GATE}" "${SCRIPTS}/gate_scope.py" "${d}/linux/scripts/"
cp "${HUB_ROOT}/shared/templates/AGENTS.md.template" "${d}/shared/templates/"; cp "${HUB_ROOT}/docs/language-ai.md" "${d}/docs/"
printf '# rulebook\n' > "${d}/AGENTS.md"; git -C "${d}" init -q; git -C "${d}" add -A
t_assert_eq 0 "$(t_rc "${PY}" "${d}/linux/scripts/verify_agents_drift.py" --root "${d}")" "a hub without numbered headings passes"
printf '%s\n%s\n' "${long}" "${long}" >> "${d}/AGENTS.md"
t_assert_eq 1 "$(t_rc "${PY}" "${d}/linux/scripts/verify_agents_drift.py" --root "${d}")" "a hub with a repeated line fails"
}

_group_lintgates() {
t_case "run-lint-gates.sh runs it only behind --agents-drift, over the consumer root"
# shellcheck source=../run-lint-gates.sh
source "${SCRIPTS}/run-lint-gates.sh"
d="$(_copy)"; printf 'name: new\n' > "${d}/.github/workflows/new.yml"; _add "${d}"
_lint_gates_parse_args "${d}"
t_assert_eq 0 "${_LINT_GATES_AGENTS_DRIFT}" "off by default"
_lint_gates_parse_args "${d}" --agents-drift
t_assert_eq 1 "${_LINT_GATES_AGENTS_DRIFT}" "the flag sets it"
t_assert_eq 1 "$(t_rc _lint_gates_agents_drift)" "the aggregator returns the gate's verdict for the consumer"
_lint_gates_parse_args "${_clean}"
t_assert_eq 0 "$(t_rc _lint_gates_agents_drift)" "and it passes a clean consumer"
t_assert_contains "$(declare -f _lint_gates_main)" 'run_gate "agents drift" _lint_gates_agents_drift' "the gate is registered"
t_assert_contains "$(declare -f _lint_gates_main)" '_LINT_GATES_AGENTS_DRIFT' "and behind its flag"
}

# No argument runs every group; a recipe names its own so its proof stays short.
_selected=" ${*:-all} "
_want() {
  case "${_selected}" in
    *" all "* | *" $1 "*) return 0 ;;
  esac
  return 1
}
if _want basic; then _group_basic; fi
if _want section5; then _group_section5; fi
if _want section1; then _group_section1; fi
if _want headings; then _group_headings; fi
if _want duplicates; then _group_duplicates; fi
if _want docs; then _group_docs; fi
if _want backlog; then _group_backlog; fi
if _want json; then _group_json; fi
if _want hub; then _group_hub; fi
if _want lintgates; then _group_lintgates; fi

t_summary
