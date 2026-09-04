#!/usr/bin/env bash
# Tests for verify_doc_links.py. The gate derives its root from its own path, so
# each case copies it into a throwaway tree with a minimal docs/ and code tree.
# The copy sits OUTSIDE the scanned dirs, and fixture pointers are spelled via
# ${D} so this file's own text is not read as pointers by the real gate.
# docs/code-quality-tooling.md#code-to-docs-pointers-doc-links
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
REPO_ROOT="$(cd "${TESTS_DIR}/../../.." && pwd)"
GATE="${REPO_ROOT}/docs/scripts/verify_doc_links.py"
PY="${PREFLIGHT_PYTHON:-python3}"
D='docs/'

# A tree with one indexed page (heading + stable id) and one code file whose
# content is $1. Extra pages/files are added by the caller before running.
_fixture() {
  local d; d="$(mktemp -d)"
  mkdir -p "${d}/docs" "${d}/tools/gate" "${d}/linux/scripts"
  cp "${GATE}" "${d}/tools/gate/"
  printf '# Guide\n\n<a id="stable"></a>\n## Real Heading\n\ntext\n' > "${d}/docs/guide.md"
  printf '# Index\n\n- [guide](guide.md)\n' > "${d}/docs/INDEX.md"
  printf '.. toctree::\n\n   guide\n' > "${d}/docs/index.rst"
  printf '%s\n' "$1" > "${d}/linux/scripts/subject.sh"
  printf '%s' "${d}"
}
_run() { t_out "${PY}" "$1/tools/gate/verify_doc_links.py"; }
_rc()  { t_rc "${PY}" "$1/tools/gate/verify_doc_links.py"; }

t_case "valid code pointers (page, heading slug, stable id) pass"
fix="$(_fixture "# see ${D}guide.md and ${D}guide.md#real-heading and ${D}guide.md#stable")"
t_assert_eq "0" "$(_rc "${fix}")"
t_assert_contains "$(_run "${fix}")" "3 code pointers"
rm -rf "${fix}"

t_case "a code pointer to a missing page fails and is located"
fix="$(_fixture "# see ${D}gone.md")"
out="$(_run "${fix}")"
t_assert_eq "1" "$(_rc "${fix}")"
t_assert_contains "${out}" "[pointer] linux/scripts/subject.sh:1 -> ${D}gone.md  (no such page)"
rm -rf "${fix}"

t_case "a code pointer to a missing heading fails -- exact match, no prose tolerance"
fix="$(_fixture "# see ${D}guide.md#real")"
t_assert_eq "1" "$(_rc "${fix}")"
t_assert_contains "$(_run "${fix}")" "${D}guide.md#real  (no such heading)"
rm -rf "${fix}"

t_case "a ../-relative pointer resolves from the file's own directory"
fix="$(_fixture "# see ../../${D}guide.md#stable")"
t_assert_eq "0" "$(_rc "${fix}")"
rm -rf "${fix}"

t_case "windows/ is its own lane: its pointers are not scanned"
fix="$(_fixture ':')"
mkdir -p "${fix}/windows"; printf '# %sgone.md\n' "${D}" > "${fix}/windows/x.ps1"
t_assert_eq "0" "$(_rc "${fix}")"
rm -rf "${fix}"

t_case "a .patch under linux/ is upstream content, not scanned"
fix="$(_fixture ':')"
printf '+# %sgone.md\n' "${D}" > "${fix}/linux/scripts/x.patch"
t_assert_eq "0" "$(_rc "${fix}")"
rm -rf "${fix}"

t_case "a Markdown link to a missing file fails"
fix="$(_fixture ':')"
printf '# Guide\n\n[x](missing.md)\n' > "${fix}/docs/guide.md"
t_assert_contains "$(_run "${fix}")" "[link]    ${D}guide.md -> missing.md  (no such file)"
rm -rf "${fix}"

t_case "a Markdown deep link to a renamed heading fails"
fix="$(_fixture ':')"
printf '# Guide\n\n## Real Heading\n\n[x](guide.md#old-heading)\n' > "${fix}/docs/guide.md"
t_assert_contains "$(_run "${fix}")" "[anchor]  ${D}guide.md -> guide.md#old-heading  (no such heading)"
rm -rf "${fix}"

t_case "a page in neither INDEX.md nor the toctree fails twice"
fix="$(_fixture ':')"
printf '# Orphan\n' > "${fix}/docs/orphan.md"
out="$(_run "${fix}")"
t_assert_contains "${out}" "${D}orphan.md is in no docs/index.rst toctree"
t_assert_contains "${out}" "${D}orphan.md is linked from no row in docs/INDEX.md"
rm -rf "${fix}"

t_case "a bare (S 1a) pointing at no section on the page fails"
# SECTION_REF only covers the cross-file form, so these were counted and never
# checked -- a dangling one survived several renumberings unnoticed.
fix="$(_fixture ':')"
printf '# Guide\n\n## 1b. Real\n\ntext (\xc2\xa7 1a) more\n' > "${fix}/docs/guide.md"
SGN="$(printf '\302\247')"
t_assert_contains "$(_run "${fix}")" "${D}guide.md ${SGN} 1a  (no such section on this page)"
rm -rf "${fix}"

t_case "a bare section reference that resolves passes"
fix="$(_fixture ':')"
printf '# Guide\n\n## 1b. Real\n\ntext (\xc2\xa7 1b) more\n' > "${fix}/docs/guide.md"
t_assert_eq "0" "$(_rc "${fix}")"
rm -rf "${fix}"

t_case "a licence clause on a page with no numbered sections is not a section ref"
# "Apache-2.0 S4(b)" must not be guessed at -- checking pages that define no
# numbered sections would trade a real gap for false alarms.
fix="$(_fixture ':')"
printf '# Guide\n\n## Real Heading\n\nApache-2.0 \xc2\xa74(b) requires notice.\n' > "${fix}/docs/guide.md"
t_assert_eq "0" "$(_rc "${fix}")"
rm -rf "${fix}"

t_case "a cross-file reference is not read as a local one"
fix="$(_fixture ':')"
printf '# Guide\n\n## 1b. Real\n\nSee CHANGELOG.md \xc2\xa7 2026-09-01 for it.\n' > "${fix}/docs/guide.md"
t_assert_eq "0" "$(_rc "${fix}")"
rm -rf "${fix}"

t_case "the REAL tree is clean today"
t_assert_eq "0" "$( "${PY}" "${GATE}" >/dev/null 2>&1; echo $? )"

t_summary
