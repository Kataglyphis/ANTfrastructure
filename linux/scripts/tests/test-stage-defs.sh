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
CROSS_TARGETS="amd64,arm64,riscv64"

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
t_assert_eq "1" "$(PARALLEL_ARCHS=1 TARGET_ARCHES=amd64,arm64,riscv64 MAX_PARALLEL_ARCHS=3 cross_build_mem_divisor shared)" \
  "shared stages (base/compiler) run alone -> divisor 1 (PAR4-amend 2026-08-19)"

t_case "cross_build_mem_divisor is STATIC: only its env inputs move it (PAR5 verdict)"
# Tripwire, not a feature test. PAR5 (2026-08-23) tried to shrink the divisor as
# sibling lanes retired, by having this function count live-lane marker files in
# PARALLEL_LOOP_FLAGDIR. It was REVERTED: the clamp could not fire where it was
# meant to (all lane markers exist before any lane retires, and the divisor is
# read once per lane at lane start), and where it could fire it made a RAM budget
# depend on wall-clock sibling timing and could clamp DOWN below the PAR4 value —
# the overcommit direction that OOM-killed cc1plus. The divisor must stay a pure
# function of PARALLEL_ARCHS/TARGET_ARCHES/MAX_PARALLEL_ARCHS/PAR_INTRA_STEP_BUDGET.
# See docs/build-parallelism-memory-tuning.md § PAR5 before re-attempting.
_static_dir="$(mktemp -d)"
: > "${_static_dir}/lane.amd64"
t_assert_eq "6" "$(PARALLEL_LOOP_FLAGDIR="${_static_dir}" PARALLEL_ARCHS=1 TARGET_ARCHES=amd64,arm64,riscv64 MAX_PARALLEL_ARCHS=3 cross_build_mem_divisor)" \
  "flag-dir state must NOT reach the divisor -- it stays 3 x budget(2)"
rm -rf "${_static_dir}"

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

# ── GCC_PARALLEL_TARGETS: the launch-time flag must reach the compiler stage ──
# This used to be DROPPED here (no --build-arg, no ARG in Dockerfile.toolchain),
# so GCC_PARALLEL_TARGETS=1 on the launch command silently did nothing and the
# sequential GCC path won every validation (backlog GCC_PARALLEL_TARGETS).
t_case "cross_stage_build_args forwards GCC_PARALLEL_TARGETS to compiler only when set"
_args=()
unset GCC_PARALLEL_TARGETS GCC_HOST_BOOTSTRAP GCC_CANADIAN_CROSS_SKIP_ON_LINK_FAILURE || true
cross_stage_build_args _args compiler
case " ${_args[*]} " in
  *"GCC_PARALLEL_TARGETS"*) t_assert_eq "absent" "present" "unset knob must not be forwarded" ;;
  *) t_assert_eq "ok" "ok" ;;
esac
_args=()
GCC_PARALLEL_TARGETS=1 cross_stage_build_args _args compiler
t_assert_contains "${_args[*]}" "GCC_PARALLEL_TARGETS=1" "set knob must reach the compiler stage"
_args=()
GCC_HOST_BOOTSTRAP=0 cross_stage_build_args _args compiler
t_assert_contains "${_args[*]}" "GCC_HOST_BOOTSTRAP=0" "GCC_HOST_BOOTSTRAP now forwarded when set"
_args=()
GCC_PARALLEL_TARGETS=1 cross_stage_build_args _args media arm64
case " ${_args[*]} " in
  *"GCC_PARALLEL_TARGETS"*) t_assert_eq "absent" "present" "compiler-only knob must NOT leak to media" ;;
  *) t_assert_eq "ok" "ok" ;;
esac

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
