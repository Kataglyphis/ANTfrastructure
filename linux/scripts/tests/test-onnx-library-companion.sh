#!/usr/bin/env bash
# The extracted ORT dependency guard proves required library traversal visibility, not image filesystem contents.
set -eu
source "$(dirname "${BASH_SOURCE[0]}")/test-harness.sh"
source_file="${_T_SCRIPTS}/03-media/build/onnxruntime/build/lib/common.sh"
guard="$(sed -n '/^for _req_fn in /,/^unset _req_fn$/p' "$source_file")"
t_case 'ORT bootstrap refuses a missing shared library action'
output=''; status=0
t_capture_command output status bash -eu -c '
  for name in info warn err arch_oci cross_build_enabled host_python_bin host_python_major_minor resolve_qnn_sdk stage_qnn_runtime; do eval "$name() { :; }"; done
  eval "$1"
' _ "$guard"
t_assert_eq 1 "$status"
t_assert_contains "$output" 'required helper apply_shared_library_action is undefined'
t_case 'ORT bootstrap accepts the actual copied companion'
t_assert_eq 0 "$(t_rc bash -eu -c '
  for name in info warn err arch_oci cross_build_enabled host_python_bin host_python_major_minor resolve_qnn_sdk stage_qnn_runtime; do eval "$name() { :; }"; done
  source "$2"
  eval "$1"
' _ "$guard" "${_T_SCRIPTS}/01-core/elf-strip.sh")"
t_summary
