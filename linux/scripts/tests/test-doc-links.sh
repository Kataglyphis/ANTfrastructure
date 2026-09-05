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

t_case "the scanned set does not depend on .git being present"
# The mutation gate mirrors the repo WITHOUT .git and runs this suite from the
# copy. There `git check-ignore` exits 128 and answers nothing; treating that
# as "nothing is ignored" quietly turned 566 scanned files into 5,467, failed
# the gate on model output, and killed BOTH doc-links mutation entries before
# either was ever mutated. Neither side could see it: one change made the gate
# ask git, the other took git away.
# Comparing the two lists is NOT enough -- with git present the fallback branch
# never runs, and that version of this test let the mutation survive. So point
# the gate at a directory that is not a repository and prove the wiring.
t_assert_eq "wired" "$( "${PY}" - <<'PYCHK'
import importlib.util, pathlib, tempfile
spec = importlib.util.spec_from_file_location("g", "docs/scripts/verify_doc_links.py")
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
cand = []
for name in g.CODE_SCAN:
    root = g.REPO_ROOT / name
    if root.is_file():
        cand.append(root); continue
    for f in sorted(root.rglob("*")):
        if f.is_file() and f.suffix not in g.CODE_SKIP_SUFFIXES and not (
                g.CODE_SKIP_PARTS & set(f.parts)):
            cand.append(f)
rel = [f.relative_to(g.REPO_ROOT) for f in cand]
# A SYNTHETIC list for the floor, so this proves the same thing in a full
# checkout and in the gate's mirror. The mirror now prunes git-ignored paths,
# so measuring the floor against what is on disk found nothing there and this
# test failed for the very reason it exists to guard -- two correct changes,
# broken together, the second time in one day.
probe = [pathlib.Path(e) / "probe.bin" if not e.endswith((".zst", ".env", ".cjs"))
         else pathlib.Path(e) for e in g.UNTRACKED_OUTPUT]
keep = [pathlib.Path("linux/llm-stack/bench_coding.py"),
        pathlib.Path("linux/llm-stack/.env.example")]
floor_probe = g._static_ignores(probe + keep)
with_git = g._ignored_paths(rel)
floor = g._static_ignores(rel)
g.REPO_ROOT = pathlib.Path(tempfile.mkdtemp())   # not a git repository
without_git = g._ignored_paths(rel)
without_git_probe = g._ignored_paths(probe + keep)
problems = []
if len(floor_probe) != len(probe):
    problems.append("the floor skips %d of %d output paths" % (len(floor_probe), len(probe)))
if any(str(k) in floor_probe for k in keep):
    problems.append("the floor swallowed a tracked file beside an excluded one")
if with_git != floor:
    problems.append("git says %d, floor says %d" % (len(with_git), len(floor)))
if without_git != floor:
    problems.append("no-git path returned %d, not the floor" % len(without_git))
if without_git_probe != floor_probe:
    problems.append("no-git path ignored the floor on the probe list")
print("wired" if not problems else "BROKEN: " + "; ".join(problems))
PYCHK
)"

t_case "the REAL tree is clean today"
t_assert_eq "0" "$( "${PY}" "${GATE}" >/dev/null 2>&1; echo $? )"

t_summary
