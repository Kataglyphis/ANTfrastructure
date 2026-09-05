#!/usr/bin/env bash
# Tests for verify-patch-integrity.sh. A patch only detonates hours into a cross
# build, so the two things this gate must actually do are go RED on a malformed
# diff and RED on an orphaned one -- and stay ADVISORY about the apply site, which
# is the distinction a stricter rewrite would silently lose.
# docs/code-quality-tooling.md#patch-integrity-patch-integrity
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/gate-tree.sh"
GATE="${TESTS_DIR}/../verify-patch-integrity.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# _tree: a throwaway repo root with the gate at its real depth; it resolves both
# the patch dir and the script corpus from its own location.
_tree() {
  local d; d="$(gate_tree_here "${_work}" "${GATE}" linux/scripts/verify-patch-integrity.sh)"
  mkdir -p "${d}/linux/scripts/patches"
  printf '%s' "${d}"
}

# _patch <tree> <name> <shape>: good | no-hunk | no-minus | no-plus
_patch() {
  local f="$1/linux/scripts/patches/$2"
  : > "${f}"
  [ "$3" = "no-minus" ] || printf -- '--- a/src/file.c\n' >> "${f}"
  [ "$3" = "no-plus" ]  || printf -- '+++ b/src/file.c\n' >> "${f}"
  [ "$3" = "no-hunk" ]  || printf -- '@@ -1,3 +1,3 @@\n-old\n+new\n' >> "${f}"
}

# _apply_site <tree> <file> <patch name> <helper|raw>
_apply_site() {
  local f="$1/linux/scripts/$2"
  if [ "$4" = helper ]; then
    printf 'bash /opt/scripts/apply-patch.sh "%s"\n' "$3" > "${f}"
  else
    printf 'git apply "%s"\n' "$3" > "${f}"
  fi
}

_gate() { bash "$1/linux/scripts/verify-patch-integrity.sh"; }

t_case "a well-formed patch with an apply site passes"
fix="$(_tree)"; _patch "${fix}" good.patch good; _apply_site "${fix}" use.sh good.patch helper
_out="$(t_out _gate "${fix}")"
t_assert_eq "0" "$(t_rc _gate "${fix}")" "the gate must be able to be green, or every red below proves nothing"
t_assert_contains "${_out}" "referenced via apply-patch helper: good.patch"
t_assert_contains "${_out}" "0 failed"

t_case "a truncated diff with no hunk header FAILS"
fix="$(_tree)"; _patch "${fix}" broken.patch no-hunk; _apply_site "${fix}" use.sh broken.patch helper
t_assert_eq "1" "$(t_rc _gate "${fix}")" "a hand-mangled patch must not reach apply-patch.sh mid-build"
t_assert_contains "$(t_out _gate "${fix}")" "not a valid unified diff"

t_case "a diff missing its --- or +++ header FAILS too"
fix="$(_tree)"; _patch "${fix}" a.patch no-minus; _apply_site "${fix}" ua.sh a.patch helper
t_assert_eq "1" "$(t_rc _gate "${fix}")" "all three markers are required, not any one of them"
fix="$(_tree)"; _patch "${fix}" b.patch no-plus; _apply_site "${fix}" ub.sh b.patch helper
t_assert_eq "1" "$(t_rc _gate "${fix}")"

t_case "an ORPHANED patch fails: its fix has quietly stopped being applied"
fix="$(_tree)"; _patch "${fix}" lonely.patch good
t_assert_eq "1" "$(t_rc _gate "${fix}")"
t_assert_contains "$(t_out _gate "${fix}")" "orphaned patch — no build script references lonely.patch"

t_case "a reference from something that is not a build script does not count"
# The corpus is *.sh on purpose: a patch named only in a doc or a changelog is
# still not applied by anything.
fix="$(_tree)"; _patch "${fix}" doc-only.patch good
printf 'we used to apply doc-only.patch here\n' > "${fix}/linux/scripts/notes.md"
t_assert_eq "1" "$(t_rc _gate "${fix}")"
t_assert_contains "$(t_out _gate "${fix}")" "orphaned patch"

t_case "a raw apply site is ADVISORY: reported as INFO, and still passes"
# Some sites pre-date the idempotent helper. Turning this into a failure is the
# tempting tightening that would break a green tree for no build reason.
fix="$(_tree)"; _patch "${fix}" raw.patch good; _apply_site "${fix}" raw-use.sh raw.patch raw
_out="$(t_out _gate "${fix}")"
t_assert_eq "0" "$(t_rc _gate "${fix}")" "the advisory must not be an exit code"
t_assert_contains "${_out}" "INFO: applied without the idempotent apply-patch.sh helper"
t_assert_contains "${_out}" "referenced: raw.patch"

t_case "one bad patch among several still fails the whole run"
fix="$(_tree)"
_patch "${fix}" ok1.patch good; _apply_site "${fix}" u1.sh ok1.patch helper
_patch "${fix}" ok2.patch good; _apply_site "${fix}" u2.sh ok2.patch helper
_patch "${fix}" bad.patch no-hunk; _apply_site "${fix}" u3.sh bad.patch helper
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")" "a per-file loop that forgets its failure counter reports and exits 0"
t_assert_contains "${_out}" "1 failed"

t_case "no patches at all is not a failure"
fix="$(_tree)"
t_assert_eq "0" "$(t_rc _gate "${fix}")"
t_assert_contains "$(t_out _gate "${fix}")" "no *.patch files found"

t_case "the REAL patches directory is clean today"
t_assert_eq "0" "$(t_rc bash "${GATE}")"

t_summary
