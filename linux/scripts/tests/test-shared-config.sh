#!/usr/bin/env bash
# Tests for check_shared_config, the inline preflight gate: ContainerHub's own
# root .cmake-format.yaml is a consumer copy and must match shared/config's.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
REPO_ROOT="$(cd "${TESTS_DIR}/../../.." && pwd)"

FN_SRC="$(t_fn_src "${REPO_ROOT}/linux/scripts/preflight.sh" check_shared_config)" || exit 1
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
printf '%s\n' "${FN_SRC}" > "${WORK}/guard.sh"

TREE=""
# _tree <name> — an owner-shaped fixture: the real shared/config/ set plus the
# one root copy the gate compares.
_tree() {
  TREE="${WORK}/$1"
  mkdir -p "${TREE}/shared/config"
  cp "${REPO_ROOT}"/shared/config/.clang-format \
     "${REPO_ROOT}"/shared/config/.clang-tidy \
     "${REPO_ROOT}"/shared/config/.cmake-format.yaml \
     "${REPO_ROOT}"/shared/config/gcovr.cfg \
     "${REPO_ROOT}"/shared/config/.pre-commit-config.yaml \
     "${REPO_ROOT}"/shared/config/Sync-SharedConfig.ps1 \
     "${TREE}/shared/config/"
  cp "${REPO_ROOT}/shared/config/.cmake-format.yaml" "${TREE}/.cmake-format.yaml"
}

OUT=""; rc=0
_guard() {
  OUT="$(cd "${TREE}" && bash -c 'set -u
source "$1"
check_shared_config' _ "${WORK}/guard.sh" 2>&1)"
  rc=$?
}

t_case "a root copy identical to canonical passes; the other four are ignored BY NAME"
_tree clean; _guard
t_assert_eq "0" "${rc}" "identical root copy must be in sync"
t_assert_contains "${OUT}" "Shared config in sync." "the pass must be the script's verdict, not silence"
for _n in .clang-format .clang-tidy gcovr.cfg .pre-commit-config.yaml; do
  t_assert_contains "${OUT}" "SKIP  ${_n} (project-owned override)" \
    "${_n} has no root copy here and must be a NAMED skip, not a MISSING failure"
done

t_case "a perturbed root copy is DRIFTED and fails"
_tree drift
printf '# drift\n' >> "${TREE}/.cmake-format.yaml"
_guard
t_assert_eq "1" "${rc}" "printing is not enough; a drifted root copy must fail"
t_assert_contains "${OUT}" "DRIFTED .cmake-format.yaml" "the offender must be named"

t_case "a deleted root copy is MISSING and fails -- .cmake-format.yaml is NOT in the ignore list"
_tree gone
rm "${TREE}/.cmake-format.yaml"
_guard
t_assert_eq "1" "${rc}" "an accidentally deleted root copy must fail, not skip"
t_assert_contains "${OUT}" "MISSING .cmake-format.yaml" "the missing file must be named"

t_summary
