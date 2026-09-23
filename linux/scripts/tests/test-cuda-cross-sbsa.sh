#!/usr/bin/env bash
# Tests for the CUDA cross target (arm64 on an amd64 build host). The facts
# they encode were probed against NVIDIA's live repo on 2026-09-23 and are
# written up in docs/linux-accelerator-images.md § NVIDIA on arm64: a FLAT
# cross repo (hence the trailing " /"), Architecture: all debs landing in
# targets/sbsa-linux, a cross nvcc package with no executable in it, and no
# NCCL cross package at any version.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CORE="${TESTS_DIR}/../01-core"
REPO_SH="${CORE}/setup-cuda-repo.sh"
STACK_SH="${CORE}/install-cuda-stack.sh"

t_case "the repo component follows the BUILD arch, and the cross repo the TARGET"
eval "$(t_fn_src "${REPO_SH}" cuda_repo_component)"
eval "$(t_fn_src "${REPO_SH}" cuda_cross_repo_component)"
t_assert_eq "x86_64" "$(cuda_repo_component amd64)" "the host's own tools come from its own component"
t_assert_eq "sbsa"   "$(cuda_repo_component arm64)" "a NATIVE arm64 build uses sbsa, as before"
t_assert_eq "" "$(cuda_cross_repo_component amd64 amd64)" "a native build adds no cross repo"
t_assert_eq "" "$(cuda_cross_repo_component arm64 arm64)" "nor does a native arm64 one"
t_assert_eq "cross-linux-sbsa" "$(cuda_cross_repo_component amd64 arm64)" \
  "arm64 on an amd64 host is the case this whole path exists for"
t_assert_eq "" "$(cuda_cross_repo_component amd64 riscv64)" \
  "NVIDIA publishes no riscv64 cross repo; silence beats a 404 mid-build"

t_case "the cross sources line is flat-repo shaped and pinned to the keyring"
_src="$(cat "${REPO_SH}")"
t_assert_contains "${_src}" 'signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg' \
  "the cross repo rides the SAME trust anchor, not apt's global keyring"
t_assert_contains "${_src}" '/%s/ /\n' "a flat repo needs the trailing ' /' or apt looks for dists/"
t_assert_eq "" "$(printf '%s\n' "${_src}" | grep 'trusted=yes')" "never trusted=yes"

t_case "the cross package set is the target's libraries — and NCCL is absent on purpose"
eval "$(t_fn_src "${STACK_SH}" cuda_cross_packages)"
_pkgs="$(cuda_cross_packages 13-4 13)"
t_assert_contains "${_pkgs}" "cuda-cross-sbsa-13-4" "the meta package pulls cudart/nvcc-crt/nvrtc/cupti"
for _lib in cublas cufft cusparse curand cusolver npp; do
  t_assert_contains "${_pkgs}" "lib${_lib}-cross-sbsa-13-4" "${_lib} is a math library the EP links"
done
t_assert_contains "${_pkgs}" "libcudnn9-cross-sbsa-cuda-13" "cuDNN 9 for the CUDA 13 line"
t_assert_eq "" "$(printf '%s\n' "${_pkgs}" | grep -i nccl)" \
  "there is NO nccl cross package; asking for one fails the whole apt transaction"
t_assert_eq "8" "$(printf '%s\n' "${_pkgs}" | grep -c .)" "eight packages, all Architecture: all"
t_assert_eq "1" "$(cuda_cross_packages '' 13 >/dev/null 2>&1; echo $?)" "an empty version is refused"

t_case "the cross install verifies the ELF machine, and the host set stays"
_stack="$(cat "${STACK_SH}")"
t_assert_contains "${_stack}" 'readelf -h' "an x86-64 lib under targets/sbsa-linux must fail HERE"
t_assert_contains "${_stack}" "is not AArch64 — the cross repo served host packages" \
  "and say what actually went wrong"
t_assert_contains "${_stack}" 'NCCL has no cross package' "the gap is stated, not silently shipped"
t_assert_contains "${_stack}" 'cuda-toolkit-${CUDA_VERSION_MAJOR_MINOR}' \
  "the HOST toolkit still installs: nvcc, ptxas and cicc have to execute here"
_cross_block="$(printf '%s\n' "${_stack}" | sed -n '/cross target (arm64 on an amd64 host)/,/^fi$/p')"
t_assert_contains "${_cross_block}" 'if [ -n "${CUDA_CROSS_TARGET_DIR:-}" ]; then' \
  "every cross action hangs off that one variable, so a native build is untouched"

t_case "Dockerfile.nvidia maps TARGET_ARCH to the target dir, and refuses what it cannot build"
_df="$(cat "${TESTS_DIR}/../../Dockerfile.nvidia")"
t_assert_contains "${_df}" "ARG TARGET_ARCH" "the stage takes the target arch (stage-defs already passes it)"
t_assert_contains "${_df}" 'arm64) _cuda_cross_dir="sbsa-linux" ;;' "arm64 is the one cross target NVIDIA ships"
t_assert_contains "${_df}" 'no CUDA cross target for TARGET_ARCH=' \
  "any other foreign arch fails at the install, not hours later in the media build"
t_assert_contains "${_df}" 'CUDA_CROSS_TARGET_DIR="${_cuda_cross_dir}"' "and the decision reaches the script"

t_summary
