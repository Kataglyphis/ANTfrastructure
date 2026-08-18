#!/usr/bin/env bash
# Tests for 01-core/stage-defs.sh — the stage graph the orchestrator walks.
# Uses the REAL modules (tag-naming, build-helpers, platform), not hand-stubs:
# test-disk-guard/test-ancestry stub cross_stage_tag for isolation, so until
# this suite existed the real tag resolution was never executed by any test.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/platform.sh"
source "${TESTS_DIR}/../01-core/build-helpers.sh"
source "${TESTS_DIR}/../01-core/tag-naming.sh"
source "${TESTS_DIR}/../01-core/stage-defs.sh"

IMAGE_REPO="example.io/repo"

t_case "cross_stage_tag resolves every stage through the real tag functions"
t_assert_eq "example.io/repo:base"                 "$(cross_stage_tag base)"
t_assert_eq "example.io/repo:cross-compiler-amd64" "$(cross_stage_tag compiler)"
t_assert_eq "example.io/repo:cross-sdk-arm64"      "$(cross_stage_tag sdk arm64)"
t_assert_eq "example.io/repo:cross-media-riscv64"  "$(cross_stage_tag media riscv64)"
t_assert_eq "example.io/repo:cross-android-amd64"  "$(cross_stage_tag android amd64)"

t_case "cross_stage_tag rejects unknown stages"
t_assert_fails cross_stage_tag no-such-stage

t_case "cross_build_mem_divisor: serial default is 1"
unset PARALLEL_ARCHS TARGET_ARCHES MAX_PARALLEL_ARCHS || true
t_assert_eq "1" "$(cross_build_mem_divisor)"

t_case "cross_build_mem_divisor: min(arches, max) x intra-step budget (PAR4)"
# PAR4 (2026-08-18): buildkitd max-parallelism runs several heavy steps PER
# build, so the divisor multiplies the arch count by PAR_INTRA_STEP_BUDGET
# (default 2) — the un-multiplied divisor OOM'd the first post-PAR2 run.
t_assert_eq "4" "$(PARALLEL_ARCHS=1 TARGET_ARCHES=arm64,riscv64 MAX_PARALLEL_ARCHS=4 cross_build_mem_divisor)" \
  "2 arches under max=4 -> 2 x budget(2) = 4"
t_assert_eq "4" "$(PARALLEL_ARCHS=1 TARGET_ARCHES=amd64,arm64,riscv64 MAX_PARALLEL_ARCHS=2 cross_build_mem_divisor)" \
  "3 arches capped by max=2 -> 2 x budget(2) = 4"
t_assert_eq "6" "$(PARALLEL_ARCHS=1 TARGET_ARCHES=amd64,arm64,riscv64 MAX_PARALLEL_ARCHS=3 cross_build_mem_divisor)" \
  "3-way -> 3 x budget(2) = 6 (the wave3b-OOM configuration, now sized)"
t_assert_eq "9" "$(PARALLEL_ARCHS=1 TARGET_ARCHES=amd64,arm64,riscv64 MAX_PARALLEL_ARCHS=3 PAR_INTRA_STEP_BUDGET=3 cross_build_mem_divisor)" \
  "budget knob raises the divisor (escalation path)"

t_case "stage graph validates clean"
t_assert_ok cross_stage_validate_graph

t_case "cross_stage_build_args forwards ENABLE_NVIDIA to media only when set"
_args=()
unset ENABLE_NVIDIA ENABLE_AMD || true
cross_stage_build_args _args media arm64
case " ${_args[*]} " in
  *"ENABLE_NVIDIA"*) t_assert_eq "absent" "present" "unset toggle must not be forwarded" ;;
  *) t_assert_eq "ok" "ok" ;;
esac
_args=()
ENABLE_NVIDIA=true cross_stage_build_args _args media arm64
t_assert_contains "${_args[*]}" "ENABLE_NVIDIA=true" "set toggle must reach the media stage"

# ── XC2: runtime-lane ancestry graph ───────────────────────────────────────────
t_case "runtime_stage_parent extends the graph one lane past android"
t_assert_eq "android" "$(runtime_stage_parent package)"
t_assert_eq "package" "$(runtime_stage_parent wrapper)"
t_assert_eq ""        "$(runtime_stage_parent android)"

t_case "runtime_stage_tag resolves runtime roles + the android handoff"
RUNTIME_IMAGE_PREFIX="example.io/repo:runtime"
t_assert_eq "example.io/repo:runtime-base-arm64"    "$(runtime_stage_tag base arm64)"
t_assert_eq "example.io/repo:runtime-package-arm64" "$(runtime_stage_tag package arm64)"
t_assert_eq "example.io/repo:runtime-arm64"         "$(runtime_stage_tag wrapper arm64)"
t_assert_eq "example.io/repo:cross-android-arm64"   "$(runtime_stage_tag android arm64)"
t_assert_fails runtime_stage_tag no-such-stage arm64

t_summary
