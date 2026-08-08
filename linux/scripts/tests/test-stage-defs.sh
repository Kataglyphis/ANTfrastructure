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

t_case "cross_build_mem_divisor: parallel divides by min(arches, max)"
t_assert_eq "2" "$(PARALLEL_ARCHS=1 TARGET_ARCHES=arm64,riscv64 MAX_PARALLEL_ARCHS=4 cross_build_mem_divisor)" \
  "2 arches under max=4 -> divide by 2"
t_assert_eq "2" "$(PARALLEL_ARCHS=1 TARGET_ARCHES=amd64,arm64,riscv64 MAX_PARALLEL_ARCHS=2 cross_build_mem_divisor)" \
  "3 arches capped by max=2"

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

t_summary
