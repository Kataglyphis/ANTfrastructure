#!/usr/bin/env bash
# The CUDA cross target (arm64 on an amd64 host); see docs/linux-accelerator-images.md § NVIDIA on arm64
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

t_case "the pinned cuDNN tier pins the headers package too"
# Without it apt picks the newest headers, -dev's exact dependency fails, and the unpinned tier installs a newer cuDNN (9.27 for a 9.26 pin, 2026-10-01).
t_assert_contains "$(cat "${STACK_SH}")" '"libcudnn${CUDNN_MAJOR}-headers-cuda-${CUDA_MAJOR}=${CUDNN_VERSION}*"; } || \' \
  "the headers pin sits in the same apt call as the -dev pin"

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
_cross_block="$(printf '%s\n' "${_stack}" | sed -n '/^cuda_cross_packages() {/,/^fi$/p')"
t_assert_contains "${_cross_block}" 'if [ -n "${CUDA_CROSS_TARGET_DIR:-}" ]; then' \
  "every cross action hangs off that one variable, so a native build is untouched"

t_case "cross cuDNN is pinned to the host's, and gets the links the -dev package would have provided"
t_assert_contains "${_stack}" 'libcudnn9-cross-sbsa-cuda-${CUDA_MAJOR}=${CUDNN_VERSION}*' \
  "the host headers ORT probes and the target libs it links must be one cuDNN (unpinned, the cross set drifted)"
_links="$(t_fn_src "${STACK_SH}" cuda_cross_cudnn_links)"
t_assert_contains "${_links}" 'ln -sfn "$(basename "${f}")" "${base}.so.9"' "the cross deb ships libcudnn*.so.9.X.Y only: no soname link"
t_assert_contains "${_links}" '"${f%_v9.h}.h"' "and cudnn*_v9.h only: no cudnn.h for the ORT header probe"

t_case "NCCL and nvcc have no cross package: the target's own debs are staged at the HOST's versions"
_stage="$(t_fn_src "${STACK_SH}" cuda_cross_stage_target_debs)"
t_assert_contains "${_stage}" 'deb [arch=%s signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg]' "the sbsa repo rides the same keyring, arch-restricted"
t_assert_contains "${_stage}" 'apt-get download "${pkg}:${arch}=${host_ver}"' "download, never install: a foreign libnccl2 must not replace the host's"
t_assert_contains "${_stage}" '[ "${deb_ver}" = "${host_ver}" ]' "one CUDA, two architectures"
t_assert_contains "${_stage}" 'dpkg-deb -x "${deb}" "${root}"' "unpacked into the staging root the package stage copies"
eval "$(t_fn_src "${STACK_SH}" cuda_cross_target_runtime_packages)"
_rt="$(cuda_cross_target_runtime_packages 13-4)"
for _p in libnccl2 libnccl-dev cuda-nvcc-13-4 cuda-crt-13-4 libnvvm-13-4 libnvptxcompiler-13-4 cuda-cudart-13-4 cuda-nvrtc-13-4 libcublas-13-4 libcufft-13-4 libcurand-13-4 libcusolver-13-4 libcusparse-13-4 libnpp-13-4 libnvjpeg-13-4 libnvjitlink-13-4; do
  t_assert_contains "${_rt}" "${_p}" "staged: ${_p} (the cross debs carry the math libs as stubs and static archives only, 2026-10-28)"
done
t_assert_eq "19" "$(printf '%s\n' "${_rt}" | grep -c .)" "the runtime set the amd64 payload ships, as arm64 debs"

t_case "the ELF gate covers every target library and tool, and the stage writes a descriptor for later RUNs"
_gate="$(t_fn_src "${STACK_SH}" cuda_cross_elf_gate)"; _files="$(t_fn_src "${STACK_SH}" _cuda_cross_elf_files)"
t_assert_contains "${_files}" "-name 'lib*.so*' -o -name nvcc -o -name ptxas -o -name cicc -o -name nvlink" "libs AND the staged binaries"
t_assert_contains "${_files}" "-maxdepth 1 \\( -name 'libcudnn*.so*' -o -name 'libnvinfer*.so*'" \
  "only the GPU libs in the multiarch dir: binutils' bfd-plugins/libdep.so there is x86-64 (2026-10-28)"
t_assert_contains "${_gate}" '[ "${n}" -gt 0 ] ||' "an empty gate is a failed gate"
t_assert_contains "${_stack}" 'CUDA_CROSS_TARGET_DIR=%s\nCUDA_CROSS_TARGET_ARCH=%s\nCUDA_CROSS_TARGET_TRIPLET=%s\nCUDA_CROSS_TARGET_STAGING=%s\nCUDA_CROSS_TARGET_ROOT=%s\nCUDA_CROSS_STUB_LIBCUDA=%s\nCUDA_CROSS_CUDNN_HOME=%s\nCUDA_CROSS_TENSORRT_HOME=%s\n' \
  "install-tensorrt.sh, verify-cuda-stack.sh, cross-cuda.sh and the package stage read cross-target.env instead of re-deriving the target"
t_assert_contains "${_links}" 'ln -sfn /usr/lib/"${triplet}"/libcudnn*.so* "/usr/local/cudnn-${2}/lib/"' \
  "one cuDNN root with include/ and lib/: ORT's CUDNN_PATH, OpenCV's CUDNN_LIBRARY and TVM's USE_CUDNN=<dir> all take that shape"

t_case "cross-cuda.sh: what media's CUDA consumers read from the gpu stage's descriptor"
CC_SH="${CORE}/cross-cuda.sh"; _M="${TESTS_DIR}/.."; ORT_B="${_M}/03-media/build/onnxruntime/build"
t_assert_eq "4" "$(grep -l 'source_module cross-cuda.sh' "${ORT_B}/lib/common.sh" "${_M}/03-media/build/opencv/build-opencv.sh" \
  "${_M}/03-media/build/ffmpeg/build-ffmpeg.sh" "${_M}/05-frameworks/tvm.sh" | wc -l | tr -d ' ')" \
  "the four CUDA consumers opt in; cross-env.sh stays untouched (layer rule, web-lane closure, Dockerfile mounts)"
t_assert_eq "" "$(grep -F 'cross-cuda.sh' "${CORE}/cross-env.sh")" "cross-env.sh does not aggregate it"
_ccl="$(t_fn_src "${CC_SH}" cuda_cross_load)"
t_assert_contains "${_ccl}" 'export CUDAHOSTCXX="${CXX}"' "CMake's CUDAHOSTCXX is nvcc's -ccbin: the target's g++ compiles the host half of every .cu"
t_assert_contains "${_ccl}" '--target-directory=${CUDA_CROSS_TARGET_DIR}' "and the target directory rides CUDAFLAGS into every nvcc call, device links included"
t_assert_eq "0" "$(printf '%s\n' "${_ccl}" | grep -c -- '-target-dir \${')" "in the long = form: sccache reads '-target-dir X' as a second input file and caches nothing (CON175, 609 kernels uncached on 2026-10-29)"
t_assert_contains "${_ccl}" 'export CUDA_LIB_PATH="${CUDA_CROSS_TARGET_ROOT}/lib/stubs"' "and finds the driver stub only through CUDA_LIB_PATH (OpenCV's cudacodec links it)"
_dev="$(t_fn_src "${STACK_SH}" cuda_cross_dev_links)"
t_assert_contains "${_dev}" 'ln -s "$(basename "${f}")" "${base}.so"' "cuBLAS/cuFFT/NPP cross debs ship sonames only; FindCUDA and -lcublas need the unversioned dev links (2026-10-28)"
t_assert_contains "${_ccl}" 'export CUDA_TOOLKIT_ROOT="${CUDA_HOME:-/usr/local/cuda}"' "CMake's classic FindCUDA (OpenCV) takes the toolkit root from this env when cross-compiling, or CUDA_TOOLKIT_ROOT_DIR stays unset (2026-10-28)"
_acca="$(t_fn_src "${CC_SH}" append_cmake_cuda_cross_args)"
t_assert_contains "${_acca}" '"-DCUDA_CUDA_LIBRARY=${CUDA_CROSS_STUB_LIBCUDA}"' "build.py and OpenCV default the driver stub to the host's lib64/stubs"
t_assert_contains "${_acca}" '"-DCMAKE_CUDA_HOST_COMPILER=${CXX}"' "the -D form for consumers that pass defines, not env"
t_assert_contains "${_acca}" '"-DCMAKE_CUDA_COMPILER=${CUDA_HOME:-/usr/local/cuda}/bin/nvcc"' "OpenCV's check_language(CUDA) found no compiler under the cross toolchain (2026-10-28)"
_ort="$(cat "${ORT_B}/30-build-native-nvidia.sh")"
t_assert_contains "${_ort}" 'export CUDNN_PATH="${CUDA_CROSS_CUDNN_HOME}"' "ORT's cuDNN.cmake HINTS come from CUDNN_PATH; the host's x86_64-linux-gnu header must not win"
t_assert_contains "${_ort}" 'append_onnx_wheel_mode_args BUILD_ARGS' "the GPU build takes the CPU build's cross toolchain defines and wheel rule from one helper"
t_assert_contains "$(cat "${ORT_B}/30-build-native.sh")" 'append_onnx_wheel_mode_args BUILD_ARGS' "the CPU build uses the same helper (code-dupes gate, 2026-10-28)"
_wheel="$(t_fn_src "${ORT_B}/lib/common.sh" append_onnx_wheel_mode_args)"
t_assert_contains "${_wheel}" 'cross_target_python_dev_ready; then' "cross: a wheel only with the target's Python dev files"
t_assert_contains "${_wheel}" 'append_onnx_cross_cmake_build_args "$1"' "and the cross toolchain defines"
t_assert_contains "$(cat "${ORT_B}/60-build-genai.sh")" '_genai_dist="onnxruntime_genai_cuda"' \
  "the GPU GenAI wheel is onnxruntime_genai_cuda-*: the cross-wheel gate globbed the CPU name and failed a built wheel (2026-10-28)"
_tvm="$(t_fn_src "${_M}/05-frameworks/tvm-config.sh" _tvm_emit_cuda_cross_args)"
t_assert_contains "${_tvm}" '-DUSE_CUDA="${CUDA_CROSS_TARGET_ROOT}"' "TVM's FindCUDA hard-codes targets/x86_64-linux: directory mode names the target root"
t_assert_contains "${_tvm}" '-DUSE_CUDNN="${CUDA_CROSS_CUDNN_HOME}"' "and the cuDNN root"
_ff="$(t_fn_src "${_M}/03-media/build/ffmpeg/build-ffmpeg.sh" _ffmpeg_hwaccel_args)"
t_assert_contains "${_ff}" '_ff_cuda_lib="${CUDA_CROSS_TARGET_ROOT}/lib"' "ffmpeg linked -L the host's lib64"
_sd="$(cat "${CORE}/stage-defs.sh")"
t_assert_contains "${_sd}" 'append_optional_build_arg _csba_out ENABLE_DEEPSTREAM false' "DeepStream has no SBSA runtime: a foreign target gets it off, whatever the chain set"
t_assert_contains "$(cat "${_M}/05-frameworks/deepstream.sh")" 'ds_arch_problem "${TARGET_ARCH:-$(dpkg --print-architecture)}"' "and the script judges the target, since dpkg says amd64 in a cross build"

t_case "TensorRT follows: the same twelve packages as -cross-sbsa, pinned, in their own farm, AArch64-checked"
TRT_SH="${CORE}/install-tensorrt.sh"
eval "$(t_fn_src "${TRT_SH}" trt_packages)"; eval "$(t_fn_src "${TRT_SH}" trt_cross_packages)"
_trt_cross="$(trt_cross_packages "$(trt_packages 11 11.4.0.106-1+cuda13.4)")"
t_assert_eq "12" "$(printf '%s\n' "${_trt_cross}" | grep -c .)" "twelve, like the host set"
t_assert_contains "${_trt_cross}" "libnvinfer11-cross-sbsa=11.4.0.106-1+cuda13.4" "the runtime lib"
t_assert_contains "${_trt_cross}" "libnvinfer-headers-dev-cross-sbsa=11.4.0.106-1+cuda13.4" "the headers ORT's EP builds against"
t_assert_eq "0" "$(printf '%s\n' "${_trt_cross}" | grep -vc -- '-cross-sbsa=')" "every name carries the suffix"
_trt_main="$(t_fn_src "${TRT_SH}" trt_cross_main)"
t_assert_contains "${_trt_main}" '[ -f "${env}" ] || return 0' "a native build is untouched"
t_assert_contains "${_trt_main}" 'farm="/usr/local/tensorrt-${CUDA_CROSS_TARGET_DIR}"' "never the host farm: TENSORRT_HOME/lib is on LD_LIBRARY_PATH"
t_assert_contains "${_trt_main}" 'not AArch64' "the gate"
t_assert_contains "$(cat "${TRT_SH}")" $'trt_main "$@"\n  trt_cross_main' "and it runs after the host install, in the same RUN"

t_case "verify-cuda-stack.sh checks the target half, including a device-less nvcc cross compile"
_verify="$(cat "${CORE}/verify-cuda-stack.sh")"
t_assert_contains "${_verify}" 'nvcc -allow-unsupported-compiler -ccbin "${_cuda_cross_cxx}" "--target-directory=${CUDA_CROSS_TARGET_DIR}" -c' \
  "the flags every media consumer will need, proven in the gpu stage"
t_assert_contains "${_verify}" "readelf -h \"\${_cuda_cross_tmp}/t.o\" | grep -q 'AArch64'" "and the object must be AArch64"
t_assert_contains "${_verify}" 'libnccl.so.2" ] || _cuda_warn' "the staging root is part of the stack"
t_assert_contains "${_verify}" 'stubs/libcublas.so" ] && [ -e "${_cuda_cross_lib}/stubs/libnppc.so" ]' "cuBLAS/NPP cross = link stubs, so the verifier looks there, not for dev links (strict gate 2026-10-29)"
t_assert_contains "${_verify}" "-name 'libcublas.so.*' -type f" "and the staged shared runtime is required"

t_case "Dockerfile.nvidia maps TARGET_ARCH to the target dir, and refuses what it cannot build"
_df="$(cat "${TESTS_DIR}/../../Dockerfile.nvidia")"
t_assert_contains "${_df}" "ARG TARGET_ARCH" "the stage takes the target arch (stage-defs already passes it)"
t_assert_contains "${_df}" 'arm64) _cuda_cross_dir="sbsa-linux" ;;' "arm64 is the one cross target NVIDIA ships"
t_assert_contains "${_df}" 'no CUDA cross target for TARGET_ARCH=' \
  "any other foreign arch fails at the install, not hours later in the media build"
t_assert_contains "${_df}" 'CUDA_CROSS_TARGET_DIR="${_cuda_cross_dir}"' "and the decision reaches the script"


# --- OpenCV cross: the multiarch libstdc++.so link is repinned before the CUDA link line's explicit -lstdc++ (lld rejects the host's) ---
_ocv_src="$(cat "${TESTS_DIR}/../03-media/build/opencv/build-opencv.sh")"
t_case "OpenCV cross repins the target libstdc++ link"
t_assert_contains "${_ocv_src}" 'media_pin_target_libstdcxx_if_available _opencv_pin_available _opencv_pin_target_libstdcxx' "OpenCV pins GCC's target libstdc++ like ffmpeg and GStreamer do"
t_assert_contains "${_ocv_src}" 'pin_target_libstdcxx "$(cross_target_arch)"' "for the cross target arch"

t_summary
