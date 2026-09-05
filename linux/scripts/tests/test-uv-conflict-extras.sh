#!/usr/bin/env bash
# Tests for the two `uv sync --all-extras` conflict helpers in 01-core/python_uv.sh.
# `uv` refuses --all-extras outright on a project declaring [tool.uv] conflicts, so
# this greedy first-declared-wins picker is what keeps every CI lane installable.
# Both functions are extracted, not sourced: python_uv.sh sets -euo pipefail.
# docs/python-ci.md#trap-1----all-extras-is-fatal-with-declared-conflicts
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
UV_SH="${TESTS_DIR}/../01-core/python_uv.sh"

_src="$(t_fn_src "${UV_SH}" _uv_conflict_groups)" || exit 1
eval "${_src}"
_src="$(t_fn_src "${UV_SH}" _uv_extras_to_exclude)" || exit 1
eval "${_src}"

# _write_pyproject <conflicts-open> <group-fmt> <group>... — a pyproject whose
# [tool.uv] conflicts declare one pair per argument, e.g. "ml-ai ml-ai-cuda", in
# whichever TOML layout the caller asks for. The layout is the ONLY difference
# between the fixtures, so it is the only thing they pass.
_write_pyproject() {
  local open="$1" fmt="$2"; shift 2
  local d g a b; d="$(mktemp -d)"
  { printf '[project]\nname = "p"\n\n[tool.uv]\n'
    # shellcheck disable=SC2059  # the layout IS the parameter
    printf "${open}"
    for g in "$@"; do
      a="${g%% *}"; b="${g##* }"
      # shellcheck disable=SC2059
      printf "${fmt}" "${a}" "${b}"
    done
    printf ']\n'
  } > "${d}/pyproject.toml"
  printf '%s' "${d}/pyproject.toml"
}

_pyproject() {
  _write_pyproject 'conflicts = [\n' \
    '  [\n    { extra = "%s" },\n    { extra = "%s" },\n  ],\n' "$@"
}

t_case "a project with no conflicts block excludes nothing"
_p="$(mktemp -d)/pyproject.toml"; printf '[project]\nname = "p"\n' > "${_p}"
t_assert_eq "" "$(_uv_conflict_groups "${_p}")"
t_assert_eq "" "$(_uv_extras_to_exclude "${_p}")"

t_case "a missing pyproject is not an error"
t_assert_eq "" "$(_uv_extras_to_exclude /nonexistent/pyproject.toml)"
t_assert_eq "0" "$(t_rc _uv_extras_to_exclude /nonexistent/pyproject.toml)"

t_case "each declared pair is read back as one group"
_p="$(_pyproject "ml-ai ml-ai-cuda" "pytorch-cpu pytorch-cu130")"
t_assert_eq "ml-ai ml-ai-cuda
pytorch-cpu pytorch-cu130" "$(_uv_conflict_groups "${_p}")"

t_case "the FIRST-declared member of each family survives (the CI choice)"
t_assert_eq "ml-ai-cuda pytorch-cu130" "$(_uv_extras_to_exclude "${_p}")"

t_case "a three-member family keeps one and drops the other two"
_p="$(_pyproject "a b" "a c" "b c")"
t_assert_eq "b c" "$(_uv_extras_to_exclude "${_p}")"

t_case "an extra that conflicts with a DROPPED one is still kept"
# b is dropped against a; c conflicts only with b, so nothing kept excludes it.
_p="$(_pyproject "a b" "b c")"
t_assert_eq "b" "$(_uv_extras_to_exclude "${_p}")"

t_case "families are independent: two disjoint pairs drop one member each"
_p="$(_pyproject "a b" "c d")"
t_assert_eq "b d" "$(_uv_extras_to_exclude "${_p}")"

# ── layout independence: the scanner reads TOML, not one indentation style ──
# It used to gather extras from a line only AFTER the character walk had already
# closed the group on that line's `]`, so an inline group -- legal TOML that uv
# accepts -- yielded nothing and excluded nothing, and `uv sync --all-extras`
# failed with the original conflict error. The group text is now accumulated
# during the same walk and read at the `]` that closes it.
_inline_pyproject() {
  _write_pyproject 'conflicts = [ ' '[ { extra = "%s" }, { extra = "%s" } ], ' "$@"
}

t_case "a group written on ONE line is read exactly like the multi-line layout"
_p="$(_inline_pyproject "ml-ai ml-ai-cuda" "pytorch-cpu pytorch-cu130")"
t_assert_eq "ml-ai ml-ai-cuda
pytorch-cpu pytorch-cu130" "$(_uv_conflict_groups "${_p}")"
t_assert_eq "ml-ai-cuda pytorch-cu130" "$(_uv_extras_to_exclude "${_p}")" \
  "no group means no exclusion, and --all-extras then dies on the conflict uv already declared"

t_case "the whole block on one line is read too"
_p="$(mktemp -d)/pyproject.toml"
printf '[project]\nname = "p"\n\n[tool.uv]\nconflicts = [ [ { extra = "a" }, { extra = "b" } ] ]\n' > "${_p}"
t_assert_eq "a b" "$(_uv_conflict_groups "${_p}")" \
  "the outer ] arrives on the same line as the inner one that closes the group"

t_case "the two layouts MIXED in one file both read"
_p="$(mktemp -d)/pyproject.toml"
printf '[project]\nname = "p"\n\n[tool.uv]\nconflicts = [\n  [ { extra = "a" }, { extra = "b" } ],\n  [\n    { extra = "c" },\n    { extra = "d" }, { extra = "e" },\n  ],\n]\n' > "${_p}"
t_assert_eq "a b
c d e" "$(_uv_conflict_groups "${_p}")" \
  "a three-member group split across lines must still arrive as one group"

t_case "the scanner stops at the end of the conflicts block"
_p="$(mktemp -d)/pyproject.toml"
printf '[project]\nname = "p"\n\n[tool.uv]\nconflicts = [ [ { extra = "a" }, { extra = "b" } ] ]\n\n[tool.other]\nconflicts = [ [ { extra = "zz" }, { extra = "yy" } ] ]\n' > "${_p}"
t_assert_eq "a b" "$(_uv_conflict_groups "${_p}")" \
  "the first block is the [tool.uv] one; reading past it would invent extras"

t_case "the decision is order-dependent, and the order is DECLARATION order"
_p="$(_pyproject "b a")"
t_assert_eq "a" "$(_uv_extras_to_exclude "${_p}")" "declaring b first keeps b"

t_summary
