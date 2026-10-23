#!/usr/bin/env bash
# Local cache fixtures cover checkout readiness and eviction, not remote fetches or compilation.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
eval "$(t_fn_src "${TESTS_DIR}/../01-core/common.sh" llvm_prepare_source_checkout)"
w="$(mktemp -d)"
trap 'rm -rf "${w}"' EXIT
root="${w}/source cache"
selected="${root}/llvm-project-current"
other="${root}/llvm-project-previous"
ready=9
cache_log() { printf '%s\n' "$*" >> "${w}/log"; }
reset_cache() {
  command rm -rf "${root}"
  mkdir -p "${selected}/llvm" "${other}" "${root}/unrelated"
  touch "${root}/llvm-project-file"
  : > "${w}/log"
}

t_case "a valid checkout preserves its build input and sibling caches"
reset_cache
git init -q "${selected}"
touch "${selected}/llvm/CMakeLists.txt"
git -C "${selected}" add llvm/CMakeLists.txt
git -C "${selected}" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
llvm_prepare_source_checkout ready "${root}" "${selected}" llvmorg-fixture cache_log
t_assert_eq 1 "${ready}"
t_assert_ok test -d "${selected}/.git"
t_assert_ok test -d "${other}"
t_assert_eq '' "$(cat "${w}/log")"

t_case "missing HEAD or missing LLVM tree evicts only LLVM checkout directories"
for state in missing-head missing-tree missing-git; do
  reset_cache
  if [ "${state}" != missing-git ]; then git init -q "${selected}"; fi
  if [ "${state}" != missing-tree ]; then touch "${selected}/llvm/CMakeLists.txt"; fi
  if [ "${state}" = missing-tree ]; then
    git -C "${selected}" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm fixture
  fi
  ready=9
  llvm_prepare_source_checkout ready "${root}" "${selected}" llvmorg-fixture cache_log
  t_assert_eq 0 "${ready}"
  t_assert_ok test ! -e "${selected}"
  t_assert_ok test ! -e "${other}"
  t_assert_ok test -d "${root}/unrelated"
  t_assert_ok test -f "${root}/llvm-project-file"
  t_assert_eq 'Evicting stale llvm checkout llvm-project-previous (superseded by llvmorg-fixture)' "$(cat "${w}/log")"
done

t_case "eviction errors remain fatal when the caller handles the function status"
reset_cache
rm() { return 37; }
ready=9
rc=0
llvm_prepare_source_checkout ready "${root}" "${selected}" llvmorg-fixture cache_log || rc=$?
unset -f rm
t_assert_eq 1 "${rc}"
t_assert_eq 0 "${ready}"
t_assert_ok test -d "${selected}"
t_assert_ok test -d "${other}"
t_case "selected-checkout removal also propagates its failure"
reset_cache
command rm -rf "${other}"
rm() { return 37; }
ready=9
rc=0
llvm_prepare_source_checkout ready "${root}" "${selected}" llvmorg-fixture cache_log || rc=$?
unset -f rm
t_assert_eq 37 "${rc}"
t_assert_eq 0 "${ready}"
t_assert_ok test -d "${selected}"
t_summary
