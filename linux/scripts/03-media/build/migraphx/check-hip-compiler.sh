#!/usr/bin/env bash
# An offline device object proves one HIP compilation, not linking, all GPU targets or hardware inference.
set -euo pipefail
# shellcheck source=linux/scripts/03-media/build/migraphx/native-check-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/native-check-common.sh" "$@"
source "${SCRIPT_DIR}/../../../06-packaging/smoke-common.sh"
config_status=0
"${clang_root}/bin/llvm-config" --targets-built > "${work}/backends.txt" 2> "${work}/backends-stderr.txt" || config_status=$?
if [[ "${config_status}" -ne 0 ]]; then cat "${work}/backends-stderr.txt" >&2; exit "${config_status}"; fi
grep -Eq '(^|[[:space:]])AMDGPU([[:space:]]|$)' "${work}/backends.txt" || {
  printf 'Pinned source LLVM lacks the AMDGPU backend; rebuild the native compiler\n' >&2
  exit 1
}

migraphx_hip_compile() {
  [[ "$1" == -x && "$2" == c ]] || return 2
  shift 2
  local hip_status=0
  local -a hip_args=("${clang_root}/bin/clang++" "--gcc-toolchain=${gcc_root}"
    "--rocm-path=${rocm}" "-I${rocm}/include" -D__HIP_PLATFORM_AMD__=1
    --offload-arch=gfx1030 --cuda-device-only --no-gpu-bundle-output -std=c++17 -x hip "$@")
  printf '%s\0' "${hip_args[@]}" > "${work}/hip-argv.nul" || return
  "${hip_args[@]}" > "${work}/hip-stdout.txt" 2> "${work}/hip-stderr.txt" || hip_status=$?
  printf '%s\n' "${hip_status}" > "${work}/hip-status.txt" || return
  return "${hip_status}"
}

migraphx_hip_verify() {
  local hip_machine
  hip_machine="$(elf_machine_name "$1")" || { printf 'HIP probe output is not a readable ELF device object\n' >&2; return 1; }
  printf '%s\n' "${hip_machine}" > "${work}/hip-machine.txt" || return
  [[ "${hip_machine}" == 'AMD GPU' ]] || { printf 'HIP probe did not emit an AMDGPU ELF object\n' >&2; return 1; }
  cp -- "$1" "${work}/hip-device.o" || return
  sha256sum "${work}/hip-device.o" > "${work}/hip-object.sha256"
}

status=0
program="$(cat "${SCRIPT_DIR}/hip-compiler-probe.hip")"
smoke_with_compiled_object migraphx_hip_compile "${program}" hip-device.o migraphx_hip_verify || status=$?
if [[ "${status}" -ne 0 ]]; then
  if [[ -f "${work}/hip-status.txt" ]]; then
    compile_status="$(cat "${work}/hip-status.txt")"
    cat "${work}/hip-stderr.txt" >&2
    if [[ "${compile_status}" -ne 0 ]]; then exit "${compile_status}"; fi
  fi
  exit "${status}"
fi
printf 'HIP DEVICE COMPILER PASSED: pinned source LLVM, gfx1030 AMDGPU object; backend build and GPU acceptance remain required\n'
