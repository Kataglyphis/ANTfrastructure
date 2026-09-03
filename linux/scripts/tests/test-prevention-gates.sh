#!/usr/bin/env bash
# Tests for the prevention gates added 2026-09-01: comment-size (owner directive 6)
# and masked-decls. Both derive their root from their own path, so every negative
# case copies the gate into a throwaway tree, plants a subject.sh the gate MUST
# reject with rc 1, and checks the clean counterpart it must accept with rc 0.
# docs/code-quality-tooling.md#proving-a-gate-can-go-red
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PY="${PREFLIGHT_PYTHON:-python3}"
S="${TESTS_DIR}/.."

OVER="$(seq 11 | sed 's/^/# note /'; echo ':')"
FITS="$(seq 10 | sed 's/^/# note /'; echo ':')"
# printf, not a literal block: a real `local x="$(cmd)"` line here would be a new
# offender for the very gate under test.
MASKED="$(printf 'f() {\n  local x="$(date)"\n  echo "${x}"\n}')"
SPLIT="$(printf 'f() {\n  local x\n  local y="plain"\n  x="$(date)" || return 1\n  echo "${x}${y}"\n}')"
COMMENT_KEY=$'linux/scripts/subject.sh\t# note 1'
MASKED_KEY=$'linux/scripts/subject.sh\tx'

# _verdict <gate.py> <allow-name> <subject.sh> [frozen row...] -> output plus `rc=<n>`
_verdict() {
  local d out rc
  d="$(mktemp -d)"
  mkdir -p "${d}/linux/scripts"
  cp "${S}/$1" "${S}/quality_allow.py" "${d}/linux/scripts/"
  printf '%s\n' "$3" > "${d}/linux/scripts/subject.sh"
  [ "$#" -lt 4 ] || printf '%s\n' "${@:4}" > "${d}/linux/scripts/$2"
  out="$("${PY}" "${d}/linux/scripts/$1" 2>&1)"; rc=$?
  rm -rf "${d}"
  printf '%s\nrc=%s\n' "${out}" "${rc}"
}
_size()   { _verdict verify_comment_size.py comment-size.allow "$@"; }
_masked() { _verdict verify_masked_assignments.py masked-assignments.allow "$@"; }

# _freeze_contract <fn> <offender> <clean> <frozen row>: the two-way allowlist
# contract -- the offender frozen at its own key passes, that row against the
# clean subject is STALE.
_freeze_contract() {
  local out
  t_assert_contains "$("$1" "$2" "$4")" "rc=0" "frozen at its own key it passes"
  out="$("$1" "$3" "$4")"
  t_assert_contains "${out}" "STALE entr" "the offender is gone"
  t_assert_contains "${out}" "rc=1" "a stale freeze is a failure, not a warning"
}

t_case "the gate passes on the frozen tree"
t_assert_ok "${PY}" "${S}/verify_comment_size.py"

t_case "it is registered in preflight"
t_assert_contains "$(cat "${S}/preflight.sh")" "comment-size" "an unwired gate is not a gate"

t_case "a key that truncates onto whitespace still survives the allowlist"
# The first freeze broke on exactly this: a 60-char cut ending in a space, which
# the allowlist reader then stripped, so the block was NEW and STALE at once.
t_assert_contains "$(cat "${S}/verify_comment_size.py")" ".rstrip()" \
  "truncate first, then rstrip"

t_case "the comment allowlist keys on text, not line number"
t_assert_eq "0" "$(grep -c -E '\t[0-9]+$' "${S}/comment-size.allow")" \
  "a line number would re-flag every block whenever something above it moves"

t_case "an oversized comment block fails, and says where"
_out="$(_size "${OVER}")"
t_assert_contains "${_out}" "NEW oversized comment block" "the heading names the class"
t_assert_contains "${_out}" "linux/scripts/subject.sh:1  11 lines" "file, start line and size"
t_assert_contains "${_out}" "rc=1" "printing the block is not enough; it must exit non-zero"

t_case "a block at the limit passes"
_out="$(_size "${FITS}")"
t_assert_contains "${_out}" "OK: no new oversized comment blocks"
t_assert_contains "${_out}" "rc=0" "ten lines is not over a ten-line limit"

t_case "a frozen block passes, and a stale freeze fails"
_freeze_contract _size "${OVER}" "${FITS}" "${COMMENT_KEY}"

t_case "a masked declaration fails, and says which variable"
_out="$(_masked "${MASKED}")"
t_assert_contains "${_out}" "NEW masked declaration" "the heading names the class"
t_assert_contains "${_out}" "linux/scripts/subject.sh:2  x" "file, line and variable"
t_assert_contains "${_out}" "rc=1" "printing the site is not enough; it must exit non-zero"

t_case "the split form passes, and so does a literal-valued declaration"
_out="$(_masked "${SPLIT}")"
t_assert_contains "${_out}" "OK: no new masked declarations"
t_assert_contains "${_out}" "  0 \`local/export x=\$(...)\` site(s)" \
  "a declaration with no command substitution masks nothing"
t_assert_contains "${_out}" "rc=0" "declare first, assign second, check the status"

t_case "a frozen site passes, and a stale freeze fails"
_freeze_contract _masked "${MASKED}" "${SPLIT}" "${MASKED_KEY}"

t_summary
