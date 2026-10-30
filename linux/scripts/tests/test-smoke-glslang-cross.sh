#!/usr/bin/env bash
# The media smoke's glslangValidator step under a cross build; see docs/linux-accelerator-images.md § phases C and D
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SMOKE="${TESTS_DIR}/../06-packaging/smoke-media.sh"
COMMON="${TESTS_DIR}/../06-packaging/smoke-common.sh"

t_case "the archdir's glslangValidator is the target's binary: cross builds report presence instead of executing it"
_src="$(cat "${SMOKE}")"
t_assert_contains "${_src}" 'smoke_native_dispatch glslangValidator "${_vk_glslang}" _smoke_glslang_version' \
  "dispatched like gst-inspect (the arm64 nvidia media smoke failed with Exec format error on 2026-10-29: no binfmt in the sandbox)"
t_assert_no_grep "${SMOKE}" "host binary — works on all arches" "the wrong premise is gone"

eval "$(t_fn_src "${COMMON}" smoke_cross_presence_gate)"
eval "$(t_fn_src "${COMMON}" smoke_native_dispatch)"
eval "$(t_fn_src "${SMOKE}" _smoke_glslang_version)"
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; }
_vk_glslang="/opt/vulkan/x/aarch64/bin/glslangValidator"

cross_build_is_active() { return 0; }
_out="$(smoke_native_dispatch glslangValidator "${_vk_glslang}" _smoke_glslang_version)"
t_assert_contains "${_out}" "PASS glslangValidator binary present at ${_vk_glslang} (cross build — execution skipped)" "cross: presence"
t_assert_eq "0" "$(printf '%s\n' "${_out}" | grep -c FAIL)" "and nothing executed"

cross_build_is_active() { return 1; }
_out="$(smoke_native_dispatch glslangValidator "${_vk_glslang}" _smoke_glslang_version)"
t_assert_contains "${_out}" "FAIL glslangValidator found but --version failed: ${_vk_glslang}" "native: the binary must run"

t_summary
