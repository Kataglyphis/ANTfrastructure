#!/usr/bin/env bash
# Tests for the two `uv sync --all-extras` conflict helpers in 01-core/python_uv.sh.
# `uv` refuses --all-extras outright on a project declaring [tool.uv] conflicts, so
# this greedy first-declared-wins picker is what keeps every CI lane installable.
# Both functions are extracted, not sourced: python_uv.sh sets -euo pipefail.
# docs/refactoring-backlog.md CL6
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
UV_SH="${TESTS_DIR}/../01-core/python_uv.sh"

_src="$(t_fn_src "${UV_SH}" _uv_conflict_groups)" || exit 1
eval "${_src}"
_src="$(t_fn_src "${UV_SH}" _uv_extras_to_exclude)" || exit 1
eval "${_src}"

# _pyproject <group>... — a pyproject whose [tool.uv] conflicts declare one pair
# per argument, e.g. "ml-ai ml-ai-cuda", in uv's own multi-line layout.
_pyproject() {
  local d g a b; d="$(mktemp -d)"
  { printf '[project]\nname = "p"\n\n[tool.uv]\nconflicts = [\n'
    for g in "$@"; do
      a="${g%% *}"; b="${g##* }"
      printf '  [\n    { extra = "%s" },\n    { extra = "%s" },\n  ],\n' "${a}" "${b}"
    done
    printf ']\n'
  } > "${d}/pyproject.toml"
  printf '%s' "${d}/pyproject.toml"
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

t_case "KNOWN GAP: a group written on ONE line is not seen"
# The scanner closes the group on the `]` it meets in the same character walk it
# gathers extras after, so an inline `[ { extra = "a" }, { extra = "b" } ]` — legal
# TOML that uv accepts — yields no group and excludes nothing. Pinned, not endorsed.
_p="$(mktemp -d)/pyproject.toml"
printf '[project]\nname = "p"\n\n[tool.uv]\nconflicts = [\n  [ { extra = "a" }, { extra = "b" } ],\n]\n' > "${_p}"
t_assert_eq "" "$(_uv_conflict_groups "${_p}")"

t_case "the decision is order-dependent, and the order is DECLARATION order"
_p="$(_pyproject "b a")"
t_assert_eq "a" "$(_uv_extras_to_exclude "${_p}")" "declaring b first keeps b"

t_summary
