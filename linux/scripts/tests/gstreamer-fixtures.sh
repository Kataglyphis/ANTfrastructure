#!/usr/bin/env bash
# GStreamer configuration suites extract functions without running the build scripts' top-level setup.
gst_test_load_functions() {
  local file="$1" function_name definition
  shift
  for function_name in "$@"; do
    definition="$(t_fn_src "${file}" "${function_name}")" || return 1
    eval "${definition}" || return 1
  done
}

t_source_functions "${_T_SCRIPTS}/01-core/cross-env.sh" export_cargo_compiler_binding cross_collect_target_rust_env
t_source_functions "${_T_SCRIPTS}/01-core/cross-python.sh" cross_collect_python_dev_paths
