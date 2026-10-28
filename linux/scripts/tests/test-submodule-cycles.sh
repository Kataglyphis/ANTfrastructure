#!/usr/bin/env bash
# verify_submodule_cycles.py over fixture trees; the real graph is checked by linux-x64.yml's recursive checkout job.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GATE="${TESTS_DIR}/../verify_submodule_cycles.py"
_w="$(mktemp -d)"
trap 'rm -rf "${_w}"' EXIT

# _repo <dir> [path=url...]: a checkout whose .gitmodules declares each pair.
_repo() {
  local dir="$1" pair
  shift
  mkdir -p "${dir}"
  git -C "${dir}" init -q
  : > "${dir}/.gitmodules"
  for pair in "$@"; do
    printf '[submodule "%s"]\n\tpath = %s\n\turl = %s\n' "${pair%%=*}" "${pair%%=*}" "${pair#*=}" >> "${dir}/.gitmodules"
  done
}

# _hub <name> <smile url>: the hub, its docs repo and a theme below it, the theme naming <smile url>.
_hub() {
  local root="${_w}/$1"
  _repo "${root}" "third_party/Docs=https://github.com/Kataglyphis/DocumANTation.git"
  git -C "${root}" remote add origin git@github.com:Kataglyphis/ANTfrastructure.git
  _repo "${root}/third_party/Docs" "lib/smile=https://github.com/Kataglyphis/smile"
  _repo "${root}/third_party/Docs/lib/smile" "third_party/hub=$2"
  [ "$2" = none ] && : > "${root}/third_party/Docs/lib/smile/.gitmodules"
  printf '%s' "${root}"
}

t_case "a graph with no way back to the root passes"
_root="$(_hub clean none)"
t_assert_rc 0 python3 "${GATE}" --root "${_root}"

t_case "a theme two levels down that vendors the root fails and names the path"
_root="$(_hub cycle https://github.com/Kataglyphis/ANTfrastructure.git)"
t_assert_rc 1 python3 "${GATE}" --root "${_root}"
t_assert_contains "$(t_out python3 "${GATE}" --root "${_root}")" \
  "third_party/Docs/lib/smile/third_party/hub -> https://github.com/Kataglyphis/ANTfrastructure.git vendors kataglyphis/antfrastructure again"

t_case "the ssh spelling and case of the root's URL do not hide it"
t_assert_rc 1 python3 "${GATE}" --root "$(_hub spelled git@github.com:kataglyphis/antfrastructure)"

t_case "a declared submodule with no checkout fails instead of passing unread"
_root="$(_hub unread none)"
rm -rf "${_root}/third_party/Docs/lib/smile"
t_assert_rc 1 python3 "${GATE}" --root "${_root}"
t_assert_contains "$(t_out python3 "${GATE}" --root "${_root}")" "third_party/Docs/lib/smile is not checked out"

t_case "--forbid names the repository when the root has no origin"
_root="$(_hub forbid https://github.com/Kataglyphis/smile.git)"
t_assert_rc 1 python3 "${GATE}" --root "${_root}" --forbid Kataglyphis/smile

t_case "a malformed .gitmodules cannot pass"
_root="$(_hub broken none)"
printf '[submodule "x"]\n\turl = https://example.invalid/x\n' > "${_root}/third_party/Docs/.gitmodules"
t_assert_rc 2 python3 "${GATE}" --root "${_root}"

t_summary
