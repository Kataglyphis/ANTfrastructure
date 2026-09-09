#!/usr/bin/env bash
# Tests for check_shared_config, the inline preflight gate: ContainerHub's own
# root .cmake-format.yaml is a consumer copy and must match shared/config's.
#
# WHICH assets the gate looks at now comes from the root
# .containerhub-shared.manifest, not from the `--ignore` list this function used
# to carry. So the manifest is part of the owner-shaped fixture below, and the
# four names with no root copy here are asserted to be ABSENT from the report
# rather than present as SKIP lines -- an undeclared asset is not this
# mechanism's business and is never mentioned. See shared/config/README.md.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
REPO_ROOT="$(cd "${TESTS_DIR}/../../.." && pwd)"

FN_SRC="$(t_fn_src "${REPO_ROOT}/linux/scripts/preflight.sh" check_shared_config)" || exit 1
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
printf '%s\n' "${FN_SRC}" > "${WORK}/guard.sh"

TREE=""
# _tree <name> — an owner-shaped fixture: the real shared/config/ set, the root
# manifest that declares what this repo takes, and the one root copy the gate
# compares. The sync script itself is part of that set: check_shared_config
# shells out to it, so a fixture without it fails at exec.
_tree() {
  TREE="${WORK}/$1"
  mkdir -p "${TREE}/shared/config"
  cp "${REPO_ROOT}"/shared/config/.clang-format \
     "${REPO_ROOT}"/shared/config/.clang-tidy \
     "${REPO_ROOT}"/shared/config/.cmake-format.yaml \
     "${REPO_ROOT}"/shared/config/gcovr.cfg \
     "${REPO_ROOT}"/shared/config/.pre-commit-config.yaml \
     "${REPO_ROOT}"/shared/config/Sync-SharedConfig.ps1 \
     "${REPO_ROOT}"/shared/config/shared-assets.manifest \
     "${REPO_ROOT}"/shared/config/sync-shared-config.sh \
     "${TREE}/shared/config/"
  cp "${REPO_ROOT}/.containerhub-shared.manifest" "${TREE}/.containerhub-shared.manifest"
  cp "${REPO_ROOT}/shared/config/.cmake-format.yaml" "${TREE}/.cmake-format.yaml"
}

OUT=""; rc=0
_guard() {
  OUT="$(cd "${TREE}" && bash -c 'set -u
source "$1"
check_shared_config' _ "${WORK}/guard.sh" 2>&1)"
  rc=$?
}

t_case "a root copy identical to canonical passes; the other four are not mentioned"
_tree clean; _guard
t_assert_eq "0" "${rc}" "identical root copy must be in sync"
t_assert_contains "${OUT}" "Shared config in sync." "the pass must be the script's verdict, not silence"
t_assert_contains "${OUT}" "OK      .cmake-format.yaml" \
  "the one declared asset must be reported, or 'in sync' could be over nothing"
for _n in .clang-format .clang-tidy gcovr.cfg .pre-commit-config.yaml; do
  t_assert_eq "" "$(printf '%s\n' "${OUT}" | grep -F -- "${_n}" || true)" \
    "${_n} is not declared here and must not be mentioned at all -- reporting it as MISSING is what made this gate unrunnable for three of four consumers"
done
t_assert_eq "" "$(printf '%s\n' "${OUT}" | grep -F 'legacy -Ignore list' || true)" \
  "the root manifest must be picked up; falling back to the legacy list would grade four names this repo never took"

t_case "a perturbed root copy is DRIFTED and fails"
_tree drift
printf '# drift\n' >> "${TREE}/.cmake-format.yaml"
_guard
t_assert_eq "1" "${rc}" "printing is not enough; a drifted root copy must fail"
t_assert_contains "${OUT}" "DRIFTED .cmake-format.yaml" "the offender must be named"

t_case "a deleted root copy is MISSING and fails -- .cmake-format.yaml IS declared"
_tree gone
rm "${TREE}/.cmake-format.yaml"
_guard
t_assert_eq "1" "${rc}" "an accidentally deleted root copy must fail, not skip"
t_assert_contains "${OUT}" "MISSING .cmake-format.yaml" "the missing file must be named"

t_case "an undeclared asset is invisible, but a manifest that names it is not"
_tree declared
printf 'gcovr\n' >> "${TREE}/.containerhub-shared.manifest"
_guard
t_assert_eq "1" "${rc}" \
  "declaring an asset this repo has no root copy of must fail -- the declaration is what turns silence into a verdict"
t_assert_contains "${OUT}" "MISSING gcovr.cfg"

t_summary
