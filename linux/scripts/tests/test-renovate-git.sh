#!/usr/bin/env bash
# Tests local Git discovery; it does not fetch, initialize or update submodules.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../renovate-say.sh" git-test
source "${TESTS_DIR}/../renovate-git.sh"
w="$(mktemp -d)"
trap 'rm -rf "${w}"' EXIT
git -C "${w}" init -q

root_result() (
  local resolved="$1"
  resolve_renovate_root resolved
  printf '%s\n' "${resolved}"
)
record_module() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4"; }

t_case "root resolution preserves subdirectories, whitespace and the PWD default"
mkdir "${w}/sub directory"
t_assert_eq "${w}/sub directory" "$(root_result "${w}/sub directory")"
t_assert_eq "${w}" "$(cd "${w}" && root_result '')"
t_assert_fails root_result "${w}/missing"
t_assert_fails root_result /dev

t_case "missing and empty submodule files produce no callbacks"
t_assert_eq '' "$(for_each_renovate_submodule "${w}" record_module marker)"
: > "${w}/.gitmodules"
t_assert_eq '' "$(for_each_renovate_submodule "${w}" record_module marker)"

t_case "submodule iteration retains section names, path spaces, order and callback context"
git -C "${w}" config -f .gitmodules 'submodule.first module.path' 'path with spaces'
git -C "${w}" config -f .gitmodules submodule.second.path nested/child
git -C "${w}" config -f .gitmodules submodule.empty.path ''
git -C "${w}" config -f .gitmodules submodule.url-only.url https://example.invalid/repo
t_assert_eq "${w}|first module|path with spaces|marker
${w}|second|nested/child|marker" "$(for_each_renovate_submodule "${w}" record_module marker)"
t_case "duplicate declarations retain Git's last-value lookup semantics"
git -C "${w}" config -f .gitmodules --add submodule.second.path 'last path'
t_assert_eq "${w}|first module|path with spaces|marker
${w}|second|last path|marker
${w}|second|last path|marker" "$(for_each_renovate_submodule "${w}" record_module marker)"
t_summary
