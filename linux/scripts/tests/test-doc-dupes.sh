#!/usr/bin/env bash
# Shingles, not lines, because a reworded copy shares no whole line; see docs/code-quality-tooling.md#the-allowlist-contract
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/gate-tree.sh"
GATE="${TESTS_DIR}/../../../docs/scripts/verify_doc_dupes.py"
PY="${PREFLIGHT_PYTHON:-python3}"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
mkdir -p "${_work}/docs/scripts" "${_work}/linux/scripts"
cp "${GATE}" "${_work}/docs/scripts/"
# The gate imports gate_scope.py at module level; without it a fixture gets a traceback, not a verdict.
cp "${TESTS_DIR}/../quality_allow.py" "${TESTS_DIR}/../gate_scope.py" "${_work}/linux/scripts/"
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

t_case "badges and images are markup, not prose: every README's badge row would match"
_reset
_BADGES="[![Linux x64 build and test](https://github.com/Kataglyphis/Example/actions/workflows/linux-x64.yml/badge.svg)](https://github.com/Kataglyphis/Example/actions/workflows/linux-x64.yml)
[![Windows x64 build and test](https://github.com/Kataglyphis/Example/actions/workflows/windows-x64.yml/badge.svg)](https://github.com/Kataglyphis/Example/actions/workflows/windows-x64.yml)
![logo](https://github.com/Kataglyphis/Example/raw/develop/images/logo.png)"
_page alpha "${_BADGES}"
_page beta "${_BADGES}"
t_assert_eq "0" "$(_rc)" "a badge row shared by two pages is not a copied passage"
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

# The --root arm. ${_D} hides the fixture page names from doc-links.
t_case "--root grades the named tree, and its budget lives under that root"
_D='docs/'
_root_para="$(printf 'The runtime image ships a cross built toolchain for every architecture we\ntarget and the media layer is rebuilt on top of it whenever a pin moves so the\nresulting artifacts stay reproducible across the whole fleet of machines.')"
gate_root_pair_arm "${PY}" "${GATE}" "${_root_para}" "${_D}one.md" "${_D}two.md" doc-dupes.allow

# The --against-hub arm: a fixture hub holds the gate and one tracked page, since the hub's pages come from git ls-files.
_hubfx="$(mktemp -d "${_work}/hub.XXXXXX")"
mkdir -p "${_hubfx}/${_D}scripts" "${_hubfx}/linux/scripts"
cp "${GATE}" "${_hubfx}/${_D}scripts/"
cp "${TESTS_DIR}/../quality_allow.py" "${TESTS_DIR}/../gate_scope.py" "${_hubfx}/linux/scripts/"
printf '# Owner\n\n%s\n' "${_PARA}" > "${_hubfx}/${_D}owner.md"
git -C "${_hubfx}" init -q
t_git_commit "${_hubfx}"
_HUB_GATE="${_hubfx}/${_D}scripts/verify_doc_dupes.py"
_hub() { "${PY}" "${_HUB_GATE}" --against-hub "$@"; }
# _consumer <README text> [<allow file text>]: a consumer checkout; the allow file is written only when given.
_consumer() {
  local d; d="$(mktemp -d "${_work}/consumer.XXXXXX")"
  printf '# Readme\n\n%s\n' "$1" > "${d}/README.md"
  [ "$#" -lt 2 ] || printf '%s\n' "$2" > "${d}/doc-dupes-hub.allow"
  git -C "${d}" init -q
  t_git_commit "${d}"
  printf '%s' "${d}"
}

t_case "--against-hub is off until the consumer seeds doc-dupes-hub.allow, and --report still lists"
_c="$(_consumer "${_PARA}")"
t_assert_eq "0" "$(t_rc _hub --root "${_c}")" "an unseeded consumer is not failed"
t_assert_contains "$(t_out _hub --root "${_c}")" "OFF for"
t_assert_contains "$(t_out _hub --root "${_c}")" "--report lists what it would find"
t_assert_eq "0" "$(t_rc _hub --root "${_c}" --report)" "--report on an unseeded consumer lists, and still does not fail"
t_assert_contains "$(t_out _hub --root "${_c}" --report)" "1 passage(s) restate a hub page"
t_assert_contains "$(t_out _hub --root "${_c}" --report)" "hub:${_D}owner.md"

t_case "off, it never reads the hub: a git-less hub (the mutation mirror) still passes an unseeded consumer"
_nogit="$(mktemp -d "${_work}/nogit.XXXXXX")"
mkdir -p "${_nogit}/${_D}scripts" "${_nogit}/linux/scripts"
cp "${_HUB_GATE}" "${_nogit}/${_D}scripts/"
cp "${_hubfx}/linux/scripts/"*.py "${_nogit}/linux/scripts/"
cp "${_hubfx}/${_D}owner.md" "${_nogit}/${_D}"
t_assert_eq "0" "$(t_rc "${PY}" "${_nogit}/${_D}scripts/verify_doc_dupes.py" --against-hub --root "${_c}")" \
  "the aggregator's no-shell case runs this in a mirror with no .git"
t_assert_eq "2" "$(t_rc "${PY}" "${_nogit}/${_D}scripts/verify_doc_dupes.py" --against-hub --root "${_c}" --report)" \
  "asked to scan, a hub git cannot list is a refusal, not an empty reference"

t_case "seeded, a consumer passage that restates a hub page fails, naming both pages"
_c="$(_consumer "${_PARA}" "")"
t_assert_eq "1" "$(t_rc _hub --root "${_c}")" "a copy of a hub paragraph in a seeded consumer is a finding"
_out="$(t_out _hub --root "${_c}")"
t_assert_contains "${_out}" "README.md:"
t_assert_contains "${_out}" "hub:${_D}owner.md:"
t_assert_contains "${_out}" "replace the consumer's copy with a link"

t_case "a pair budgeted in <root>/doc-dupes-hub.allow passes at its measurement"
_n="$(t_out _hub --root "${_c}" | sed -n 's/^  \([0-9]*\) shared shingles.*/\1/p' | head -1)"
_c="$(_consumer "${_PARA}" "README.md | ${_D}owner.md | ${_n} | fixture budget")"
t_assert_eq "0" "$(t_rc _hub --root "${_c}")" "the row in the consumer's own allow file silences the pair"
t_assert_contains "$(t_out _hub --root "${_c}")" "doc-dupes --against-hub OK"

t_case "a budget row whose overlap is gone fails as stale"
_c="$(_consumer "Nothing here resembles the hub at all; it talks about kitchen utensils, the weather in a different hemisphere, and bread." \
  "README.md | ${_D}owner.md | 20 | fixture budget")"
t_assert_eq "1" "$(t_rc _hub --root "${_c}")" "a row that measures nothing is cover for the next copy"
t_assert_contains "$(t_out _hub --root "${_c}")" "no longer overlaps"

t_case "two consumer pages sharing a passage are the plain mode's business, not this one's"
_c="$(_consumer "${_root_para}" "")"
printf '# Other\n\n%s\n' "${_root_para}" > "${_c}/other.md"
t_git_commit "${_c}"
t_assert_eq "0" "$(t_rc _hub --root "${_c}")" "only consumer <-> hub pairs count here"

t_case "the hub itself is refused: it is the reference, not a consumer"
t_assert_eq "2" "$(t_rc _hub)" "without --root the gate would grade the hub against its own pages"
t_assert_contains "$(t_out _hub)" "is its own reference"

t_case "run-lint-gates.sh runs the mode in its ratchet step and returns its verdict"
# shellcheck source=../run-lint-gates.sh
source "${TESTS_DIR}/../run-lint-gates.sh"
_LINT_GATES_DIR="${_hubfx}/linux/scripts"
_lint_gates_parse_args "$(_consumer "${_PARA}" "")"
t_assert_eq "1" "$(t_rc _lint_gates_doc_dupes_hub)" "a seeded consumer restating the hub fails the aggregator"
_lint_gates_parse_args "$(_consumer "${_PARA}")"
t_assert_eq "0" "$(t_rc _lint_gates_doc_dupes_hub)" "an unseeded one passes"
t_assert_contains "$(declare -f _lint_gates_ratchet)" "_lint_gates_doc_dupes_hub" "--ratchets must call it"

t_summary
