#!/usr/bin/env bash
# KNOWN_SLUGS and the run_check registrations must be equal sets, or PREFLIGHT_ONLY rejects a real slug.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PREFLIGHT="${TESTS_DIR}/../preflight.sh"

t_case "preflight.sh exists and parses"
t_assert_ok bash -n "${PREFLIGHT}"

# Only the KNOWN_SLUGS assignment is evaluated, in an isolated bash.
_known="$(bash -c "
  $(sed -n '/^KNOWN_SLUGS=(/,/)/p' "${PREFLIGHT}")
  printf '%s\n' \"\${KNOWN_SLUGS[@]}\"
" | sort)"

# Every `run_check <slug>` call site; the definition takes "$1" and so never matches.
_registered="$(grep -E '^\s*run_check [a-z0-9-]+ ' "${PREFLIGHT}" \
  | awk '{print $2}' | sort -u)"

t_case "KNOWN_SLUGS is non-empty and run_check sites were found"
t_assert_ok test -n "${_known}"
t_assert_ok test -n "${_registered}"

t_case "every registered run_check slug is in KNOWN_SLUGS"
# LC_ALL=C on both sides: comm needs its inputs sorted in its own collation.
_missing="$(LC_ALL=C comm -13 <(printf '%s\n' "${_known}" | LC_ALL=C sort) <(printf '%s\n' "${_registered}" | LC_ALL=C sort))"
t_assert_eq "" "${_missing}" "registered but not in KNOWN_SLUGS (the stage-graph class):${_missing:+ }${_missing}"

t_case "every KNOWN_SLUGS entry has a run_check registration"
_orphan="$(LC_ALL=C comm -23 <(printf '%s\n' "${_known}" | LC_ALL=C sort) <(printf '%s\n' "${_registered}" | LC_ALL=C sort))"
t_assert_eq "" "${_orphan}" "in KNOWN_SLUGS but never registered (zero-ran no-op class):${_orphan:+ }${_orphan}"


# The doc is the human-facing mirror of KNOWN_SLUGS.
DOC="${TESTS_DIR}/../../../docs/cross-build-verification.md"

t_case "the doc's authority line quotes the count KNOWN_SLUGS actually has"
_doc_count="$(grep -o -E '[0-9]+ slugs\)' "${DOC}" | head -1 | awk '{print $1}')"
t_assert_eq "$(printf '%s\n' "${_known}" | grep -c .)" "${_doc_count}" "doc slug count vs KNOWN_SLUGS"

t_case "the doc's authority line quotes the lines KNOWN_SLUGS actually spans"
_arr_first="$(grep -n -e '^KNOWN_SLUGS=(' "${PREFLIGHT}" | cut -d: -f1)"
_arr_last="$(awk -v s="${_arr_first}" 'NR>=s && /\)$/ {print NR; exit}' "${PREFLIGHT}")"
t_assert_contains "$(cat "${DOC}")" "preflight.sh:${_arr_first}-${_arr_last}"

_doc_slugs="$(awk '/^\| Slug \| Script \| Catches \|/{f=1;next} !f{next} /^\|-/{next} /^\| `/{s=$0;sub(/^\| `/,"",s);sub(/`.*/,"",s);print s;next} {exit}' "${DOC}" | LC_ALL=C sort)"

t_case "every KNOWN_SLUGS entry has a row in the doc's slug table"
_doc_missing="$(LC_ALL=C comm -23 <(printf '%s\n' "${_known}" | LC_ALL=C sort) <(printf '%s\n' "${_doc_slugs}"))"
t_assert_eq "" "${_doc_missing}" "in KNOWN_SLUGS but undocumented:${_doc_missing:+ }${_doc_missing}"

t_case "the doc's slug table invents no slug preflight does not have"
_doc_extra="$(LC_ALL=C comm -13 <(printf '%s\n' "${_known}" | LC_ALL=C sort) <(printf '%s\n' "${_doc_slugs}"))"
t_assert_eq "" "${_doc_extra}" "documented but not a slug:${_doc_extra:+ }${_doc_extra}"

t_summary
