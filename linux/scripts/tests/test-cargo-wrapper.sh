#!/usr/bin/env bash
# _cargo_wrapper.sh's safe.directory guard against a real git in a throwaway HOME, and that every cargo_*.sh driver sources it.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
RUST_DIR="$(cd "${TESTS_DIR}/../02-toolchain/rust" && pwd)"

_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT

# _safe_dirs [VAR=value...]: sources the wrapper twice in a fresh HOME and prints the safe.directory entries git holds.
_safe_dirs() {
  local home; home="$(mktemp -d "${_WORK}/home.XXXXXX")"
  # MSYS_NO_PATHCONV: Git Bash would rewrite /workspace into a Windows path on its way to git.exe.
  env HOME="${home}" XDG_CONFIG_HOME="${home}/xdg" GIT_CONFIG_NOSYSTEM=1 CARGO_HOME="${home}/cargo-home" MSYS_NO_PATHCONV=1 "$@" bash -c '
    source "$1/_cargo_wrapper.sh" >/dev/null 2>&1
    source "$1/_cargo_wrapper.sh" >/dev/null 2>&1
    git config --global --get-all safe.directory | tr "\n" " "
  ' _ "${RUST_DIR}" 2>/dev/null
}

t_case "the default is /workspace, the bind mount the family images use"
t_assert_eq "/workspace " "$(_safe_dirs)"

t_case "CARGO_SAFE_DIRECTORY names another checkout"
t_assert_eq "/src/oxidant " "$(_safe_dirs CARGO_SAFE_DIRECTORY=/src/oxidant)"

t_case "an empty value opts out, as CMAKE_BUILD_SAFE_DIRECTORY does"
t_assert_eq "" "$(_safe_dirs CARGO_SAFE_DIRECTORY=)"

t_case "sourcing it again adds nothing: every driver run would otherwise grow the global gitconfig"
t_assert_eq "1" "$(_safe_dirs | wc -w | tr -d ' ')"

t_case "every cargo_*.sh driver goes through the wrapper"
for driver in "${RUST_DIR}"/cargo_*.sh; do
  t_assert_eq "1" "$(grep -c '_cargo_wrapper\.sh"' "${driver}")" "$(basename "${driver}") must source _cargo_wrapper.sh, or it skips the guards"
done

t_summary
