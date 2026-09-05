#!/usr/bin/env bash
# The docs duplication gate, run against fixture pages: a reworded copy shares
# no whole line, which is why it is measured in 8-word shingles.
# docs/code-quality-tooling.md#the-allowlist-contract
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GATE="${TESTS_DIR}/../../../docs/scripts/verify_doc_dupes.py"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
mkdir -p "${_work}/docs/scripts" "${_work}/linux/scripts"
cp "${GATE}" "${_work}/docs/scripts/"
cp "${TESTS_DIR}/../quality_allow.py" "${_work}/linux/scripts/"
: > "${_work}/docs/scripts/doc-dupes.allow"

# One paragraph, long enough to carry shingles, plus a reworded twin.
_PARA="The runtime image ships a cross built toolchain for every architecture we
support and the build refuses to publish a manifest until each one has been
smoke tested against the bytes that will actually be pushed to the registry."
_D=docs  # built, never written literally: a docs/<page>.md string here reads as a code pointer to the doc-links gate
_page() { printf '# %s\n\n%s\n' "$1" "$2" > "${_work}/${_D}/$1.md"; }
_gate() { (cd "${_work}" && python3 docs/scripts/verify_doc_dupes.py 2>&1); }
_rc()   { (cd "${_work}" && python3 docs/scripts/verify_doc_dupes.py >/dev/null 2>&1); echo $?; }

t_case "two pages that share no passage pass"
_page alpha "${_PARA}"
_page beta "Nothing here resembles the other page at all; it talks about kitchen
utensils, the weather in a different hemisphere, and a recipe for bread."
t_assert_eq "0" "$(_rc)"
t_assert_contains "$(_gate)" "docs duplication gate OK"

t_case "a copied passage fails, naming both pages"
_page beta "${_PARA}"
t_assert_eq "1" "$(_rc)" "a verbatim copy is duplication"
_out="$(_gate)"
t_assert_contains "${_out}" "${_D}/alpha.md"
t_assert_contains "${_out}" "${_D}/beta.md"

t_case "a REWORDED copy is caught too: whole-line matching would miss it"
_page beta "The runtime image ships a cross built toolchain for every architecture
we support, and the build refuses to publish a manifest until every one of them
has been smoke tested against the bytes that will actually be pushed."
t_assert_eq "1" "$(_rc)" "reflowed prose shares no whole line, but the same shingles"

t_case "an allowlisted pair passes, and its budget is the measurement"
_out="$(_gate)"
_shared="$(printf '%s\n' "${_out}" | sed -n 's/.*[^0-9]\([0-9]\+\) shared shingles.*/\1/p' | head -1)"
printf '%s/alpha.md | %s/beta.md | %s | reviewed: fixture\n' "${_D}" "${_D}" "${_shared}" > "${_work}/${_D}/scripts/doc-dupes.allow"
t_assert_eq "0" "$(_rc)" "a documented twin with the measured budget passes"

t_case "a budget below the measurement still fails: the row must equal what is there"
printf '%s/alpha.md | %s/beta.md | 1 | reviewed: fixture\n' "${_D}" "${_D}" > "${_work}/${_D}/scripts/doc-dupes.allow"
t_assert_eq "1" "$(_rc)" "under-declaring the overlap is not a waiver"

_reset() { rm -f "${_work}/${_D}"/*.md; : > "${_work}/${_D}/scripts/doc-dupes.allow"; }
_report() { (cd "${_work}" && python3 docs/scripts/verify_doc_dupes.py --report 2>&1); }

t_case "a passage in SIX pages is vocabulary, not duplication"
_reset
for _i in 1 2 3 4 5 6; do _page "vocab${_i}" "${_PARA}"; done
t_assert_eq "0" "$(_rc)" "over MAX_OWNERS the shingle is shared vocabulary and is dropped"

t_case "the same passage twice in ONE page is not a finding"
_reset
_page alpha "${_PARA}"
printf '\n%s\n' "${_PARA}" >> "${_work}/${_D}/alpha.md"
t_assert_eq "0" "$(_rc)" "cross-FILE pairs only; a page restating itself is a doc-links question"

t_case "a paragraph under the word floor is never indexed"
_reset
_SHORT="The runtime image ships a cross built toolchain for every arch."
_page alpha "${_SHORT}"
_page beta "${_SHORT}"
t_assert_eq "0" "$(_rc)" "under MIN_WORDS it cannot carry a shingle"
t_assert_contains "$(_report)" "scanned 0 paragraphs in 2 files"

t_case "--report names every allowed pair and what was scanned"
_reset
_page alpha "${_PARA}"
_page beta "${_PARA}"
_shared="$(_gate | sed -n 's/.*[^0-9]\([0-9]\+\) shared shingles.*/\1/p' | head -1)"
printf '%s/alpha.md | %s/beta.md | %s | reviewed: fixture\n' "${_D}" "${_D}" "${_shared}" > "${_work}/${_D}/scripts/doc-dupes.allow"
_out="$(_report)"
t_assert_contains "${_out}" "scanned 2 paragraphs in 2 files"
t_assert_contains "${_out}" "allowed"
t_assert_contains "${_out}" "reviewed: fixture"

t_case "an allowlist row whose overlap is GONE fails as stale"
rm -f "${_work}/${_D}/beta.md"
t_assert_eq "1" "$(_rc)" "a row that no longer measures anything is cover for the next copy"
t_assert_contains "$(_gate)" "no longer overlaps"

t_summary
