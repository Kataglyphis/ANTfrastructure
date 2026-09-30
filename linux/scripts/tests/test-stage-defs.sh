#!/usr/bin/env bash
# stage-defs.sh with the real tag modules, the only suite that runs real tag resolution; others stub cross_stage_tag.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# The default chain only: an inherited ENABLE_NVIDIA would move every tag (test-gpu-variant.sh owns variants).
unset CROSS_VARIANT ENABLE_NVIDIA ENABLE_AMD
source "${TESTS_DIR}/../01-core/platform.sh"
source "${TESTS_DIR}/../01-core/build-helpers.sh"
source "${TESTS_DIR}/../01-core/tag-naming.sh"
source "${TESTS_DIR}/../01-core/stage-defs.sh"

IMAGE_REPO="example.io/repo"
CROSS_TARGETS="amd64,arm64,riscv64"

t_case "cross_stage_tag resolves every stage through the real tag functions"
t_assert_eq "example.io/repo:base"                 "$(BUILDARCH=amd64 cross_stage_tag base)"
# BUILDARCH pinned: the compiler tag follows the build host's arch.
t_assert_eq "example.io/repo:cross-compiler-amd64" "$(BUILDARCH=amd64 cross_stage_tag compiler)"
t_assert_eq "example.io/repo:cross-sdk-arm64"      "$(cross_stage_tag sdk arm64)"
t_assert_eq "example.io/repo:cross-media-riscv64"  "$(cross_stage_tag media riscv64)"
# The android tag carries a build-host infix (x86_64-only NDK); sdk/media stay unpinned to prove they do not.
t_assert_eq "example.io/repo:cross-android-amd64"  "$(BUILDARCH=amd64 cross_stage_tag android amd64)"
t_assert_eq "example.io/repo:cross-android-hostarm64-riscv64" \
  "$(BUILDARCH=arm64 cross_stage_tag android riscv64)"

t_case "cross_stage_tag rejects unknown stages"
t_assert_fails cross_stage_tag no-such-stage

t_case "cross_build_mem_divisor: serial default is 1"
unset PARALLEL_ARCHS TARGET_ARCHES MAX_PARALLEL_ARCHS || true
t_assert_eq "1" "$(cross_build_mem_divisor)"

t_case "cross_build_mem_divisor: min(arches, max) x intra-step budget (PAR4)"
# buildkitd runs several heavy steps per build, hence the PAR_INTRA_STEP_BUDGET multiplier.
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
# Tripwire: the divisor must stay a pure function of its env inputs; see docs/build-parallelism-memory-tuning.md § PAR5
_static_dir="$(mktemp -d)"
: > "${_static_dir}/lane.amd64"
t_assert_eq "6" "$(PARALLEL_LOOP_FLAGDIR="${_static_dir}" PARALLEL_ARCHS=1 TARGET_ARCHES=amd64,arm64,riscv64 MAX_PARALLEL_ARCHS=3 cross_build_mem_divisor)" \
  "flag-dir state must NOT reach the divisor -- it stays 3 x budget(2)"
rm -rf "${_static_dir}"

t_case "stage graph validates clean"
t_assert_ok cross_stage_validate_graph

# Perturbs the parent map in a subshell, so the real graph survives for the next case.
# shellcheck disable=SC2034  # the subshell assignment IS the input to the callee
_validate_with() { ( CROSS_STAGE_PARENT_MAP["$1"]="$2"; cross_stage_validate_graph ); }

t_case "a parent that names no stage is refused, not walked"
t_assert_eq "1" "$(t_rc _validate_with media ghost)"
t_assert_contains "$(t_out _validate_with media ghost)" 'unknown parent "ghost"'

t_case "a cycle is refused by the depth cap, and the walk still terminates"
t_assert_eq "1" "$(t_rc _validate_with base android)"
t_assert_contains "$(t_out _validate_with base android)" "Cycle detected"

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

# GCC_PARALLEL_TARGETS: the launch-time flag must reach the compiler stage
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

# Concurrent apt runs in the parallel GCC driver collide on the dpkg lock.
t_case "parallel GCC driver exports GCC_SKIP_BUILD_DEPS + build-gcc.sh honors it"
t_assert_contains "$(grep -A8 'export GCC_SKIP_BUILD_DEPS=1' "${TESTS_DIR}/../02-toolchain/gcc.sh" || true)" \
  "GCC_SKIP_BUILD_DEPS=1" "parallel driver must skip build deps (they are preinstalled)"
t_assert_contains "$(sed -n '/GCC_SKIP_BUILD_DEPS=1 skips this/,/^fi$/p' "${TESTS_DIR}/../02-toolchain/build-gcc.sh" || true)" \
  'if [ "${GCC_SKIP_BUILD_DEPS:-0}" != "1" ]; then' \
  "build-gcc.sh apt step must be gated on GCC_SKIP_BUILD_DEPS"
t_assert_contains "$(sed -n '/GCC_SKIP_BUILD_DEPS=1 skips this/,/^fi$/p' "${TESTS_DIR}/../02-toolchain/build-gcc.sh" || true)" \
  "apt_install" "gated block must still contain the apt_install"

# XC2: runtime-lane ancestry graph
t_case "runtime_stage_parent extends the graph one lane past android"
t_assert_eq "android" "$(runtime_stage_parent package)"
t_assert_eq "package" "$(runtime_stage_parent wrapper)"
t_assert_eq ""        "$(runtime_stage_parent android)"

t_case "runtime_stage_tag resolves runtime roles + the android handoff"
RUNTIME_IMAGE_PREFIX="example.io/repo:runtime"
t_assert_eq "example.io/repo:runtime-base-arm64"    "$(runtime_stage_tag base arm64)"
t_assert_eq "example.io/repo:runtime-package-arm64" "$(runtime_stage_tag package arm64)"
t_assert_eq "example.io/repo:runtime-arm64"         "$(runtime_stage_tag wrapper arm64)"
# BUILDARCH pinned: cross_android_tag carries the build-host infix.
t_assert_eq "example.io/repo:cross-android-arm64" \
  "$(BUILDARCH=amd64 runtime_stage_tag android arm64)"
t_assert_eq "example.io/repo:cross-android-hostarm64-arm64" \
  "$(BUILDARCH=arm64 runtime_stage_tag android arm64)"
t_assert_fails runtime_stage_tag no-such-stage arm64

t_case "cross_stage_is_per_arch does not clobber the caller's loop variable"
# Called inside _disk_guard_protected_slugs' own `for s` loop, so it needs `local s`.
_seen=""
for s in base compiler runtime; do
  cross_stage_is_per_arch "${s}" || true
  _seen="${_seen}${_seen:+ }${s}"
done
t_assert_eq "base compiler runtime" "${_seen}" \
  "the caller's s must survive every call, including the return-1 path"

t_summary
