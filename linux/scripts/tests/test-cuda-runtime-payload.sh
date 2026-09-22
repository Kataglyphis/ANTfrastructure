#!/usr/bin/env bash
# The GPU variant's CUDA/cuDNN/NCCL carry-over into the runtime package image.
# Nothing copied them past the artifact boundary, so every CUDA-built library
# reached the runtime image without libcudart/libcudnn and could not load.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PAY="${TESTS_DIR}/../06-packaging/copy-media-payloads.sh"
PKG="${TESTS_DIR}/../../Dockerfile.package"

_FNS='warn() { printf "[WARN] %s\n" "$*" >&2; }'$'\n'
for _fn in _dest copy_path copy_glob copy_cuda_payload; do
  _FNS+="$(t_fn_src "${PAY}" "${_fn}")"$'\n' || exit 1
done

# An artifact tree shaped like the media image: the toolkit under a versioned
# dir, cuda/cuda-13 as ABSOLUTE alternatives links (they dangle through a bind
# mount), cuDNN/NCCL in the multiarch dir with relative soname chains.
_mk_artifact() {
  local a="$1"
  mkdir -p "${a}/usr/local/cuda-13.3/bin" "${a}/usr/local/cuda-13.3/targets/sbsa-linux/lib" \
    "${a}/usr/lib/aarch64-linux-gnu" "${a}/usr/include/aarch64-linux-gnu" "${a}/usr/include/nccl_device"
  echo nvcc > "${a}/usr/local/cuda-13.3/bin/nvcc"
  echo rt > "${a}/usr/local/cuda-13.3/targets/sbsa-linux/lib/libcudart.so.13"
  ln -s /etc/alternatives/cuda "${a}/usr/local/cuda"
  ln -s /etc/alternatives/cuda-13 "${a}/usr/local/cuda-13"
  echo dnn > "${a}/usr/lib/aarch64-linux-gnu/libcudnn.so.9.26.0"
  ln -s libcudnn.so.9.26.0 "${a}/usr/lib/aarch64-linux-gnu/libcudnn.so.9"
  echo nccl > "${a}/usr/lib/aarch64-linux-gnu/libnccl.so.2.31.2"
  echo static > "${a}/usr/lib/aarch64-linux-gnu/libnccl_static.a"
  echo h > "${a}/usr/include/aarch64-linux-gnu/cudnn_v9.h"
  echo h > "${a}/usr/include/nccl.h"
}

_run() {  # <ENABLE_NVIDIA> <src> <dst>
  ENABLE_NVIDIA="$1" SRCPREFIX="$2" COPY_TARGET_DIR="$3" \
    bash -c "set -euo pipefail"$'\n'"${_FNS}"$'\ncopy_cuda_payload' 2>&1
}

t_case "ENABLE_NVIDIA=true carries the toolkit, cuDNN, NCCL and their headers"
_SRC="$(mktemp -d)"; _DST="$(mktemp -d)"
_mk_artifact "${_SRC}"
_run true "${_SRC}" "${_DST}" >/dev/null; t_assert_eq 0 $? "a complete artifact copies cleanly"
t_assert_eq nvcc "$(cat "${_DST}/usr/local/cuda-13.3/bin/nvcc" 2>/dev/null)" "the toolkit dir is copied"
t_assert_eq rt "$(cat "${_DST}/usr/local/cuda/targets/sbsa-linux/lib/libcudart.so.13" 2>/dev/null)" \
  "/usr/local/cuda resolves INSIDE the image, not through /etc/alternatives"
t_assert_eq cuda-13.3 "$(readlink "${_DST}/usr/local/cuda-13")" "cuda-MAJOR is relinked relatively"
t_assert_eq dnn "$(cat "${_DST}/usr/lib/aarch64-linux-gnu/libcudnn.so.9" 2>/dev/null)" \
  "the cuDNN soname chain survives"
t_assert_eq nccl "$(cat "${_DST}/usr/lib/aarch64-linux-gnu/libnccl.so.2.31.2" 2>/dev/null)" "NCCL is copied"
t_assert_eq "" "$(compgen -G "${_DST}/usr/lib/aarch64-linux-gnu/*static*")" "static archives stay behind"
t_assert_eq h "$(cat "${_DST}/usr/include/aarch64-linux-gnu/cudnn_v9.h" 2>/dev/null)" "cuDNN headers are copied"
t_assert_eq yes "$([ -d "${_DST}/usr/include/nccl_device" ] && echo yes)" "NCCL's header dir is copied"

t_case "a CPU image copies nothing, and a GPU image without a toolkit is fatal"
_DST2="$(mktemp -d)"
_run false "${_SRC}" "${_DST2}" >/dev/null; t_assert_eq 0 $? "ENABLE_NVIDIA=false is a no-op"
t_assert_eq "" "$(ls -A "${_DST2}")" "and leaves the image untouched"
_EMPTY="$(mktemp -d)"; _DST3="$(mktemp -d)"
_out="$(_run true "${_EMPTY}" "${_DST3}")"; _rc=$?
t_assert_eq 1 "${_rc}" "a GPU build that lost its toolkit must not ship silently"
t_assert_contains "${_out}" "no /usr/local/cuda-X.Y" "and says what is missing"

t_case "Dockerfile.package hands the switch and the environment to the image"
t_assert_contains "$(cat "${PKG}")" 'ENABLE_NVIDIA="${ENABLE_NVIDIA:-false}" SRCPREFIX=/artifact-src bash /tmp/copy-media-payloads.sh' \
  "the payload RUN receives ENABLE_NVIDIA (an undeclared ARG reaches no RUN)"
t_assert_contains "$(cat "${PKG}")" ':/usr/local/cuda/bin:' "nvcc is on the shipped PATH"
t_assert_contains "$(cat "${PKG}")" 'NVCC_PREPEND_FLAGS=-allow-unsupported-compiler' \
  "nvcc accepts the image's GCC"
t_assert_contains "$(t_fn_src "${PAY}" copy_media_payloads)" $'\n  copy_cuda_payload\n' \
  "the payload copy actually runs it (the suite above calls it directly)"
t_assert_contains "$(cat "${PAY}")" $'  copy_media_payloads "${1:-}"\n  publish_cuda_ld_path' \
  "the toolkit's targets/<arch>/lib reaches the loader"

t_case "the torch pin enforcement installs from the SELECTED backend's index"
# Stubs: python3 reports the app lock's 2.13/0.28, uname says arm64, uv logs.
_PB="$(mktemp -d)"
printf '#!/usr/bin/env bash\ncase "$*" in *torchvision*) echo 0.28.0;; *) echo 2.13.0+cu130;; esac\n' > "${_PB}/python3"
printf '#!/usr/bin/env bash\necho aarch64\n' > "${_PB}/uname"
printf '#!/usr/bin/env bash\necho "uv $*"\n' > "${_PB}/uv"
chmod +x "${_PB}"/*
_ENF="$(t_fn_src "${TESTS_DIR}/../03-media/runtime/assemble-torch-app.sh" enforce_torch_version_pins)" || exit 1
_enforce() {
  PATH="${_PB}:${PATH}" PYTORCH_VERSION=v2.14.0 TORCHVISION_VERSION=v0.29.0 \
    bash -c "${_ENF}"$'\nenforce_torch_version_pins' 2>&1
}
_out="$(PYTORCH_EXTRA=pytorch-cu130 _enforce)"
t_assert_contains "${_out}" "--index-url https://download.pytorch.org/whl/cu130" \
  "a CUDA torch stays CUDA (the CPU index swapped it back to CPU)"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -e '--no-deps')" \
  "and brings its own nvidia-cudnn/nccl/triton pins along"
_out="$(PYTORCH_EXTRA=pytorch-cpu _enforce)"
t_assert_contains "${_out}" "--force-reinstall --no-deps --index-url https://download.pytorch.org/whl/cpu" \
  "the CPU path is unchanged"
rm -rf "${_PB}"

rm -rf "${_SRC}" "${_DST}" "${_DST2}" "${_EMPTY}" "${_DST3}"
t_summary
