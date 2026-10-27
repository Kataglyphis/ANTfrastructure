#!/usr/bin/env bash
# The cross-PE tests need a host LLVM with both target backends, independent of the family image.

pe_icon_find_tool() {
  local tool="$1" path
  for path in "/usr/local/llvm-target/bin/${tool}" "/usr/bin/${tool}" /usr/lib/llvm-*/bin/"${tool}"; do
    if [ -x "${path}" ]; then printf '%s' "${path}"; return 0; fi
  done
  command -v "${tool}" 2>/dev/null
}

pe_icon_find_clang() {
  local path targets
  for path in "$(command -v clang-22 2>/dev/null || true)" "$(command -v clang 2>/dev/null || true)" /usr/lib/llvm-*/bin/clang; do
    [ -x "${path}" ] || continue
    targets="$("${path}" --print-targets 2>/dev/null)" || continue
    case "${targets}" in *aarch64*x86-64*|*x86-64*aarch64*) printf '%s' "${path}"; return 0 ;; esac
  done
  return 1
}
