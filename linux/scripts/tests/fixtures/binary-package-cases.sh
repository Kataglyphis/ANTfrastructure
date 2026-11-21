#!/usr/bin/env bash
# Selected-member controls prove exact comparison, not binary provenance or loader compatibility.
t_binary_package_cases() {
  local checker="$1" root="$2" package
  shift 2
  local -a requirements=(--require "app/onnxruntime_providers_cuda.dll=$root/provider.dll")
  if [ "${1:-}" = --multiple ]; then
    requirements+=(--require "app/shared.dll=$root/shared.dll")
    shift
  fi
  for package in "$@"; do
    t_assert_ok python3 -I "$checker" "$root/$package" "${requirements[@]}"
    t_assert_fails python3 -I "$checker" "$root/$package" --require "app/onnxruntime_providers_cuda.dll=$root/wrong.dll"
    t_assert_fails python3 -I "$checker" "$root/$package" --require "app/missing.dll=$root/provider.dll"
  done
}
