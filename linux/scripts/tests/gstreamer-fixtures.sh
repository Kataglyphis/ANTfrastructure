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
