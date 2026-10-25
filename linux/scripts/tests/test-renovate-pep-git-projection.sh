#!/usr/bin/env bash
# The pair/rollback fixture cannot prove PyTorch wheel availability or compatibility beyond the approved versions.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/renovate-fixtures.sh"

PAIR_REPO="$(_repo pep-git-pair)"
PAIR_HUB="$(_init_repo "${WORK}/pep-git-hub")"
mkdir -p "${PAIR_HUB}/linux/scripts/01-core"
cat > "${PAIR_HUB}/linux/scripts/01-core/versions.env" <<'ENV'
PYTORCH_VERSION=v2.15.0
TORCHVISION_VERSION=v0.30.0
ENV
_commit "${PAIR_HUB}"
_add_sub "${PAIR_REPO}" "${PAIR_HUB}" third_party/ANTfrastructure
cat > "${PAIR_REPO}/pyproject.toml" <<'TOML'
[project]
name = "fixture"
version = "0.1.0"

[project.optional-dependencies]
pytorch-cpu = [
  "torch==2.14.1; platform_machine != 'riscv64'",
  "torchvision==0.29.1; platform_machine != 'riscv64'",
  "torch @ git+https://github.com/pytorch/pytorch.git@v2.14.1 ; platform_machine == 'riscv64'",
  "torchvision @ git+https://github.com/pytorch/vision.git@v0.29.1 ; platform_machine == 'riscv64'",
]
pytorch-cu130 = [
  "torch==2.14.1; platform_machine != 'riscv64'",
  "torchvision==0.29.1; platform_machine != 'riscv64'",
  "torch @ git+https://github.com/pytorch/pytorch.git@v2.14.1 ; platform_machine == 'riscv64'",
  "torchvision @ git+https://github.com/pytorch/vision.git@v0.29.1 ; platform_machine == 'riscv64'",
]
pytorch-rocm10 = [
  "torch==2.14.1; platform_machine != 'riscv64'",
  "torchvision==0.29.1; platform_machine != 'riscv64'",
  "torch @ git+https://github.com/pytorch/pytorch.git@v2.14.1 ; platform_machine == 'riscv64'",
  "torchvision @ git+https://github.com/pytorch/vision.git@v0.29.1 ; platform_machine == 'riscv64'",
]
pytorch-custom = [
  "torch==2.14.1; platform_machine != 'riscv64'",
  "torchvision==0.29.1; platform_machine != 'riscv64'",
]

[tool.uv.extra-build-dependencies]
torchvision = [
  "torch==2.14.1; platform_machine != 'riscv64'",
  "torch @ git+https://github.com/pytorch/pytorch.git@v2.14.1 ; platform_machine == 'riscv64'",
]
TOML
"${PY_ABS}" "${TESTS_DIR}/renovate_pep_git_fixture.py" write-lock "${PAIR_REPO}/uv.lock" v2.14.1 v0.29.1
_commit "${PAIR_REPO}"
cp "${PAIR_REPO}/pyproject.toml" "${WORK}/pep-git-base.toml"

PAIR_REPORT="${WORK}/pep-git-report.json"
PAIR_CONFIG="${WORK}/pep-git-config.json"
"${PY_ABS}" "${TESTS_DIR}/renovate_pep_git_fixture.py" create "${PAIR_REPORT}" "${PAIR_CONFIG}"

pin_pair() {
  local versions="${PAIR_REPO}/third_party/ANTfrastructure/linux/scripts/01-core/versions.env"
  printf 'PYTORCH_VERSION=%s\nTORCHVISION_VERSION=%s\n' "$1" "$2" > "${versions}"
  _commit "${PAIR_REPO}/third_party/ANTfrastructure"
  _commit "${PAIR_REPO}"
}

pair_run() {
  RUN_CONFIG="${PAIR_CONFIG}" _run_stubbed "${PAIR_REPO}" "${PAIR_REPORT}" "$@" --managers pep621,regex
}

pair_preview() {
  local expected="$1" why="$2"
  pair_run --apply --dry-run
  t_assert_eq "${expected}" "${RC}" "${why}"
}

uv_stub() {
  "${PY_ABS}" "${TESTS_DIR}/renovate_pep_git_fixture.py" write-uv-stub "${STUBS}/uv" "$1" \
    "${ARGV_LOG}" "${PY_ABS}" "${TESTS_DIR}/renovate_pep_git_fixture.py"
}

pair_pins() {
  local torch_tag="$1" vision_tag="$2" torch_wheel="$3" vision_wheel="$4" why="$5"
  local path="${PAIR_REPO}/pyproject.toml"
  t_assert_eq 4 "$(grep -Fc "git@${torch_tag}" "${path}")" "${why} Torch Git tags"
  t_assert_eq 3 "$(grep -Fc "git@${vision_tag}" "${path}")" "${why} vision Git tags"
  t_assert_eq 5 "$(grep -Fc "==${torch_wheel}" "${path}")" "${why} Torch wheel pins"
  t_assert_eq 4 "$(grep -Fc "==${vision_wheel}" "${path}")" "${why} vision wheel pins"
}

t_case "a complete custom lookup covers the native Git URL skips"
pair_run
t_assert_eq 0 "${RC}" "report-only is complete"
case "${OUT}" in *"NOT CHECKED"*) _unchecked=1 ;; *) _unchecked=0 ;; esac
t_assert_eq 0 "${_unchecked}" "native invalid-value skips are reconciled"

t_case "dry-run plans all four Git tags, three vision tags and nine wheel pins"
pair_preview 0 "the accepted pair can be applied"
t_assert_contains "${OUT}" "uv.lock via uv" "uv lock is in the transaction"
pair_pins v2.14.1 v0.29.1 2.14.1 0.29.1 "dry-run preserved"

t_case "apply writes source and wheel pins together"
uv_stub success
pair_run --apply
t_assert_eq 0 "${RC}" "the accepted pair applies"
pair_pins v2.15.0 v0.30.0 2.15.0 0.30.0 "apply moved"
t_assert_contains "$(cat "${ARGV_LOG}")" "uv | lock" "uv lock was invoked"

t_case "a successful no-op uv command cannot leave the old lock"
git -C "${PAIR_REPO}" restore -- pyproject.toml uv.lock
uv_stub noop
pair_run --apply
t_assert_eq 1 "${RC}" "a stale lock after a successful command is fatal"
t_assert_contains "${OUT}" "uv lock did not refresh" "the lock verdict explains rollback"
pair_pins v2.14.1 v0.29.1 2.14.1 0.29.1 "no-op lock rollback restored"

t_case "a failed uv lock restores the manifest and lockfile"
uv_stub failure
pair_run --apply
t_assert_eq 1 "${RC}" "a lock failure is fatal"
pair_pins v2.14.1 v0.29.1 2.14.1 0.29.1 "rollback restored"
t_assert_contains "$(cat "${PAIR_REPO}/uv.lock")" 'version = "2.14.1"' "the old lock was restored"

t_case "an unapproved or incomplete lookup leaves all pins alone"
"${PY_ABS}" "${TESTS_DIR}/renovate_pep_git_fixture.py" drop-lookup "${PAIR_REPORT}"
pair_run --apply
t_assert_eq 1 "${RC}" "an incomplete lookup fails before writing"
pair_pins v2.14.1 v0.29.1 2.14.1 0.29.1 "incomplete lookup preserved"

t_case "an unapproved candidate is refused without a partial pair"
"${PY_ABS}" "${TESTS_DIR}/renovate_pep_git_fixture.py" create "${PAIR_REPORT}" "${PAIR_CONFIG}"
pin_pair v2.14.1 v0.29.1
pair_preview 2 "a newer GitHub tag without hub approval is refused"
t_assert_contains "${OUT}" "hub-approved Torch/vision pair has not moved" "the refusal names the approval boundary"
pair_pins v2.14.1 v0.29.1 2.14.1 0.29.1 "unapproved candidate preserved"

t_case "an extra Torch declaration and update cannot disappear from the plan"
"${PY_ABS}" "${TESTS_DIR}/renovate_pep_git_fixture.py" create "${PAIR_REPORT}" "${PAIR_CONFIG}"
pin_pair v2.15.0 v0.30.0
"${PY_ABS}" "${TESTS_DIR}/renovate_pep_git_fixture.py" add-uncovered-spec "${PAIR_REPORT}" "${PAIR_REPO}/pyproject.toml"
_commit "${PAIR_REPO}"
pair_run --apply
t_assert_eq 1 "${RC}" "the unclassified declaration is fatal before apply"
t_assert_contains "${OUT}" "outside the checked Git and wheel pins" "the extra declaration is named"
pair_pins v2.14.1 v0.29.1 2.14.1 0.29.1 "unclassified declaration preserved"

t_case "an invalid lookup with no native skip still fails report and apply"
cp "${WORK}/pep-git-base.toml" "${PAIR_REPO}/pyproject.toml"
_commit "${PAIR_REPO}"
"${PY_ABS}" "${TESTS_DIR}/renovate_pep_git_fixture.py" create "${PAIR_REPORT}" "${PAIR_CONFIG}"
"${PY_ABS}" "${TESTS_DIR}/renovate_pep_git_fixture.py" invalidate-lookup "${PAIR_REPORT}"
pair_run
t_assert_eq 1 "${RC}" "report-only refuses the invalid lookup"
t_assert_contains "${OUT}" "Torch/vision Git pair" "the synthetic NOT CHECKED row is visible"
pair_run --apply
t_assert_eq 1 "${RC}" "apply refuses the invalid lookup before writing"
pair_pins v2.14.1 v0.29.1 2.14.1 0.29.1 "invalid lookup preserved"

t_case "a forged package lookup cannot stand in for PyTorch"
"${PY_ABS}" "${TESTS_DIR}/renovate_pep_git_fixture.py" create "${PAIR_REPORT}" "${PAIR_CONFIG}"
"${PY_ABS}" "${TESTS_DIR}/renovate_pep_git_fixture.py" spoof-package "${PAIR_REPORT}"
pair_run
t_assert_eq 1 "${RC}" "the resolved package name must match the Git URL repo"
t_assert_contains "${OUT}" "no successful GitHub tag lookup" "the lookup provenance failure is visible"

t_case "a stale no-update report cannot hide an approved hub pair"
"${PY_ABS}" "${TESTS_DIR}/renovate_pep_git_fixture.py" create "${PAIR_REPORT}" "${PAIR_CONFIG}"
"${PY_ABS}" "${TESTS_DIR}/renovate_pep_git_fixture.py" stale-no-updates "${PAIR_REPORT}"
pair_run
t_assert_eq 1 "${RC}" "report-only detects the unseen approved pair"
t_assert_contains "${OUT}" "GitHub tag candidates differ from the hub-approved" "the mismatch is visible"
pair_run --apply
t_assert_eq 1 "${RC}" "apply refuses even with no update rows"

t_case "a locally edited hub pin is not approval"
"${PY_ABS}" "${TESTS_DIR}/renovate_pep_git_fixture.py" create "${PAIR_REPORT}" "${PAIR_CONFIG}"
HUB_PIN="${PAIR_REPO}/third_party/ANTfrastructure/linux/scripts/01-core/versions.env"
printf 'PYTORCH_VERSION=v2.16.0\nTORCHVISION_VERSION=v0.31.0\n' > "${HUB_PIN}"
pair_run
t_assert_eq 1 "${RC}" "an uncommitted hub file cannot approve a pair"
t_assert_contains "${OUT}" "versions.env differs from the parent-pinned commit" "the parent pin is named"
pair_run --apply --dry-run
t_assert_eq 1 "${RC}" "dry-run also rejects the uncommitted hub file"
git -C "${PAIR_REPO}/third_party/ANTfrastructure" restore -- linux/scripts/01-core/versions.env

t_case "a moved submodule HEAD without a parent gitlink is not approval"
printf 'PYTORCH_VERSION=v2.16.0\nTORCHVISION_VERSION=v0.31.0\n' > "${HUB_PIN}"
_commit "${PAIR_REPO}/third_party/ANTfrastructure"
pair_run
t_assert_eq 1 "${RC}" "a moved submodule HEAD cannot approve a pair"
t_assert_contains "${OUT}" "submodule HEAD differs from the parent gitlink" "the parent gitlink is named"

t_case "a staged gitlink without a parent commit is not approval"
git -C "${PAIR_REPO}" add third_party/ANTfrastructure
pair_run
t_assert_eq 1 "${RC}" "a staged new gitlink cannot approve a pair"
t_assert_contains "${OUT}" "gitlink is staged away from the parent commit" "the index mismatch is visible"

t_summary
