#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/cross-env.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/cross-env.sh
fi

: "${APP_WHEELHOUSE_DIR:=/opt/app-wheels}"
: "${APP_WHEELHOUSE_BUILD_ROOT:=/tmp/app-wheelhouse}"
: "${PYTORCH_REF:=v2.12.0}"
: "${PYTORCH_VERSION:=2.12.0}"
: "${TORCHVISION_REF:=v0.27.0}"
: "${PYTORCH_HOST_INDEX_URL:=https://download.pytorch.org/whl/cpu}"
: "${DEFAULT_PYPI_INDEX_URL:=https://pypi.org/simple}"

BUILD_PYTHON=""
TARGET_TORCH_WHEEL=""
TARGET_TORCH_VERSION=""
TORCH_STAGING_DIR=""

shell_quote_args() {
    local quoted=""
    local arg

    for arg in "$@"; do
        quoted+="${quoted:+ }$(printf '%q' "${arg}")"
    done

    printf '%s' "${quoted}"
}

log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

require_host_python() {
    local python_bin=""

    if command -v host_python_bin >/dev/null 2>&1; then
        python_bin="$(host_python_bin 2>/dev/null || true)"
    fi

    if [ -z "${python_bin}" ] || [ ! -x "${python_bin}" ]; then
        python_bin="${MEDIA_HOST_PYTHON:-${UV_PYTHON:-}}"
    fi

    if [ -z "${python_bin}" ] || [ ! -x "${python_bin}" ]; then
        warn "Unable to resolve the host Python interpreter for the app wheelhouse build"
        return 1
    fi

    printf '%s' "${python_bin}"
}

wheel_platform_tag() {
    if ! command -v arch_linux_platform_tag_for >/dev/null 2>&1; then
        return 1
    fi

    arch_linux_platform_tag_for "$(cross_target_arch 2>/dev/null || true)"
}

prepare_workspace() {
    rm -rf "${APP_WHEELHOUSE_BUILD_ROOT}" "${APP_WHEELHOUSE_DIR}"
    mkdir -p "${APP_WHEELHOUSE_BUILD_ROOT}" "${APP_WHEELHOUSE_DIR}"
}

install_build_dependencies() {
    if command -v cross_apt_update >/dev/null 2>&1; then
        cross_apt_update -y
    else
        apt-get update -y
    fi

    if command -v install_host_packages >/dev/null 2>&1; then
        install_host_packages git ninja-build cmake pkg-config unzip rsync
        install_host_packages libopenblas-dev liblapack-dev zlib1g-dev libjpeg-dev libpng-dev libtiff-dev libwebp-dev
        if ! install_target_packages libopenblas-dev liblapack-dev zlib1g-dev libjpeg-dev libpng-dev libtiff-dev libwebp-dev; then
            warn "Some riscv64 target build dependencies are unavailable; continuing with the staged sysroot"
        fi
        return 0
    fi

    apt-get install -y --no-install-recommends \
        git ninja-build cmake pkg-config unzip rsync \
        libopenblas-dev liblapack-dev zlib1g-dev libjpeg-dev libpng-dev libtiff-dev libwebp-dev
}

prepare_build_environment() {
    prepare_workspace

    if ! command -v cross_build_enabled >/dev/null 2>&1 || ! cross_build_enabled; then
        log "Skipping app wheelhouse build outside of amd64-hosted cross mode"
        return 1
    fi

    if ! command -v prepare_cross_target_env >/dev/null 2>&1; then
        warn "Cross environment helpers are unavailable; leaving the app wheelhouse empty"
        return 1
    fi

    prepare_cross_target_env "${TARGET_ARCH:-${TARGETARCH:-riscv64}}" "app wheelhouse"

    if ! command -v cross_target_python_dev_ready >/dev/null 2>&1 || ! cross_target_python_dev_ready; then
        warn "Target Python development files are not staged for $(cross_target_arch 2>/dev/null || echo target); leaving the app wheelhouse empty"
        return 1
    fi

    install_build_dependencies || {
        warn "Failed to install app wheelhouse build dependencies; leaving the app wheelhouse empty"
        return 1
    }

    BUILD_PYTHON="$(require_host_python)" || return 1

    uv pip install --python "${BUILD_PYTHON}" -U \
        "setuptools<82" wheel build cmake ninja numpy packaging pyyaml requests six typing-extensions \
        sympy filelock networkx jinja2
}

append_common_cross_cmake_args() {
    local -n out_args_ref=$1
    local resolved_ar=""
    local resolved_ranlib=""
    local target_python_include=""
    local target_python_arch_include=""
    local target_python_library=""
    local host_numpy_include=""
    local qemu_runner=""

    if command -v append_cmake_cross_args >/dev/null 2>&1; then
        append_cmake_cross_args out_args_ref
    fi

    resolved_ar="$(resolve_cross_gcc_tool ar 2>/dev/null || true)"
    resolved_ranlib="$(resolve_cross_gcc_tool ranlib 2>/dev/null || true)"
    target_python_include="$(cross_target_python_include_dir 2>/dev/null || true)"
    target_python_arch_include="$(cross_target_python_arch_include_dir 2>/dev/null || true)"
    target_python_library="$(cross_target_python_library 2>/dev/null || true)"
    host_numpy_include="$("${BUILD_PYTHON}" -c 'import numpy; print(numpy.get_include())' 2>/dev/null || true)"
    qemu_runner="$(cross_target_qemu_runner 2>/dev/null || true)"

    [ -n "${resolved_ar}" ] && out_args_ref+=("-DCMAKE_AR=${resolved_ar}" "-DCMAKE_C_COMPILER_AR=${resolved_ar}" "-DCMAKE_CXX_COMPILER_AR=${resolved_ar}")
    [ -n "${resolved_ranlib}" ] && out_args_ref+=("-DCMAKE_RANLIB=${resolved_ranlib}" "-DCMAKE_C_COMPILER_RANLIB=${resolved_ranlib}" "-DCMAKE_CXX_COMPILER_RANLIB=${resolved_ranlib}")

    out_args_ref+=(
        "-DPython_EXECUTABLE=${BUILD_PYTHON}"
        "-DPYTHON_EXECUTABLE=${BUILD_PYTHON}"
        "-DPython3_EXECUTABLE=${BUILD_PYTHON}"
        "-DCMAKE_C_FLAGS=-idirafter /usr/include"
        "-DCMAKE_CXX_FLAGS=-idirafter /usr/include"
    )

    [ -n "${target_python_include}" ] && out_args_ref+=("-DPython3_INCLUDE_DIR=${target_python_include}" "-DPYTHON_INCLUDE_DIR=${target_python_include}")
    [ -n "${target_python_arch_include}" ] && out_args_ref+=("-DPython3_INCLUDE_DIRS=${target_python_include};${target_python_arch_include}")
    [ -n "${target_python_library}" ] && out_args_ref+=("-DPython3_LIBRARY=${target_python_library}" "-DPYTHON_LIBRARY=${target_python_library}")
    [ -n "${host_numpy_include}" ] && out_args_ref+=("-DNUMPY_INCLUDE_DIR=${host_numpy_include}")
    [ -n "${qemu_runner}" ] && out_args_ref+=("-DCMAKE_CROSSCOMPILING_EMULATOR=${qemu_runner}")
}

git_clone_ref() {
    local url="$1"
    local ref="$2"
    local dest_dir="$3"
    shift 3

    rm -rf "${dest_dir}"
    git clone "$@" --branch "${ref}" --depth 1 "${url}" "${dest_dir}"
}

parse_wheel_version() {
    local wheel_path="$1"
    local package_name="$2"
    local wheel_basename=""

    wheel_basename="$(basename "${wheel_path}")"
    wheel_basename="${wheel_basename%.whl}"
    wheel_basename="${wheel_basename#${package_name}-}"
    wheel_basename="${wheel_basename%%-cp*}"
    printf '%s' "${wheel_basename}"
}

retag_directory_wheels() {
    local dist_dir="$1"
    local glob_prefix="$2"
    local platform_tag="$3"
    local wheel_path

    shopt -s nullglob
    for wheel_path in "${dist_dir}"/${glob_prefix}-*.whl; do
        "${BUILD_PYTHON}" -m wheel tags --remove --platform-tag="${platform_tag}" "${wheel_path}" >/dev/null || \
            warn "Failed to retag $(basename "${wheel_path}") for ${platform_tag}"
    done
    shopt -u nullglob
}

extract_torch_wheel() {
    TORCH_STAGING_DIR="${APP_WHEELHOUSE_BUILD_ROOT}/torch-staging"
    rm -rf "${TORCH_STAGING_DIR}"
    mkdir -p "${TORCH_STAGING_DIR}"
    unzip -q -o "${TARGET_TORCH_WHEEL}" -d "${TORCH_STAGING_DIR}"
}

build_torch_wheel() {
    local wheel_platform=""
    local src_dir="${APP_WHEELHOUSE_BUILD_ROOT}/pytorch"
    local dist_dir="${APP_WHEELHOUSE_BUILD_ROOT}/dist-torch"
    local -a cmake_args=()
    local -a built_wheels=()
    local cmake_args_string=""
    local target_triplet=""
    local python_sysconfigdata=""
    local python_sysconfig_export=""

    wheel_platform="$(wheel_platform_tag || true)"
    if [ -z "${wheel_platform}" ]; then
        warn "Could not determine the riscv64 wheel platform tag for PyTorch"
        return 1
    fi

    target_triplet="$(cross_target_triplet 2>/dev/null || true)"
    if [ -n "${target_triplet}" ]; then
        python_sysconfigdata="_sysconfigdata__linux_${target_triplet}"
        python_sysconfig_export="export _PYTHON_SYSCONFIGDATA_NAME=${python_sysconfigdata}"
    fi

    git_clone_ref https://github.com/pytorch/pytorch.git "${PYTORCH_REF}" "${src_dir}" --recursive --shallow-submodules || {
        warn "Failed to clone PyTorch ${PYTORCH_REF}"
        return 1
    }

    rm -rf "${dist_dir}"
    mkdir -p "${dist_dir}"

    append_common_cross_cmake_args cmake_args
    cmake_args+=("-DBLAS=OpenBLAS")
    cmake_args_string="$(shell_quote_args "${cmake_args[@]}")"

    if ! (
        cd "${src_dir}" && \
        export CMAKE_GENERATOR=Ninja && \
        export CMAKE_ARGS="${cmake_args_string}" && \
        export _PYTHON_HOST_PLATFORM="${wheel_platform}" && \
        if [ -n "${python_sysconfig_export}" ]; then eval "${python_sysconfig_export}"; fi && \
        export PYTHON_EXECUTABLE="${BUILD_PYTHON}" Python_EXECUTABLE="${BUILD_PYTHON}" Python3_EXECUTABLE="${BUILD_PYTHON}" && \
        export MAX_JOBS="${MAX_JOBS:-$(nproc)}" && \
        export BLAS=OpenBLAS USE_NUMPY=1 && \
        export USE_CUDA=0 USE_CUDNN=0 USE_CUSPARSELT=0 USE_CUDSS=0 USE_CUFILE=0 USE_ROCM=0 USE_XPU=0 && \
        export USE_DISTRIBUTED=0 USE_GLOO=0 USE_MPI=0 USE_TENSORPIPE=0 USE_NCCL=0 && \
        export BUILD_TEST=0 BUILD_BINARY=0 USE_KINETO=0 && \
        export USE_FBGEMM=0 USE_MKLDNN=0 USE_NNPACK=0 USE_QNNPACK=0 USE_PYTORCH_QNNPACK=0 USE_XNNPACK=0 && \
        export USE_FLASH_ATTENTION=0 USE_MEM_EFF_ATTENTION=0 USE_OPENMP=0 && \
        export CFLAGS="${CFLAGS:+${CFLAGS} }-idirafter /usr/include" && \
        export CXXFLAGS="${CXXFLAGS:+${CXXFLAGS} }-idirafter /usr/include" && \
        "${BUILD_PYTHON}" setup.py bdist_wheel --plat-name "${wheel_platform}" -d "${dist_dir}"
    ); then
        warn "PyTorch riscv64 cross wheel build failed; leaving it to the native torch stage"
        return 1
    fi

    retag_directory_wheels "${dist_dir}" torch "${wheel_platform}"

    shopt -s nullglob
    built_wheels=("${dist_dir}"/torch-*.whl)
    shopt -u nullglob
    if [ "${#built_wheels[@]}" -eq 0 ]; then
        warn "PyTorch cross build completed without producing a wheel"
        return 1
    fi

    cp -a "${built_wheels[@]}" "${APP_WHEELHOUSE_DIR}/"

    TARGET_TORCH_WHEEL="${APP_WHEELHOUSE_DIR}/$(basename "${built_wheels[0]}")"
    TARGET_TORCH_VERSION="$(parse_wheel_version "${TARGET_TORCH_WHEEL}" torch)"
    extract_torch_wheel
    log "Built PyTorch cross wheel $(basename "${TARGET_TORCH_WHEEL}")"
}

install_host_torch_for_vision() {
    uv pip install --python "${BUILD_PYTHON}" \
        --default-index "${DEFAULT_PYPI_INDEX_URL}" \
        --index "${PYTORCH_HOST_INDEX_URL}" \
        --reinstall-package torch \
        "torch==${PYTORCH_VERSION}+cpu" pillow
}

patch_torchvision_setup() {
    local setup_py="$1"

    "${BUILD_PYTHON}" - "${setup_py}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
anchor = "from torch.utils.cpp_extension import BuildExtension, CppExtension, CUDA_HOME, CUDAExtension, ROCM_HOME\n"
if "TORCHVISION_TORCH_STAGING" in text:
    raise SystemExit(0)
if anchor not in text:
    raise SystemExit("expected torchvision cpp_extension import not found")
insertion = anchor + """
STAGED_TORCH_ROOT = os.environ.get(\"TORCHVISION_TORCH_STAGING\")
if STAGED_TORCH_ROOT:
    from torch.utils import cpp_extension as _torchvision_cpp_extension

    _staged_torch_root = Path(STAGED_TORCH_ROOT)
    _staged_torch_include = _staged_torch_root / \"torch\" / \"include\"
    _staged_torch_csrc = _staged_torch_include / \"torch\" / \"csrc\" / \"api\" / \"include\"
    _staged_torch_lib = _staged_torch_root / \"torch\" / \"lib\"

    def _staged_include_paths(*args, **kwargs):
        return [str(_staged_torch_include), str(_staged_torch_csrc)]

    def _staged_library_paths(*args, **kwargs):
        return [str(_staged_torch_lib)]

    _torchvision_cpp_extension.include_paths = _staged_include_paths
    _torchvision_cpp_extension.library_paths = _staged_library_paths
"""
path.write_text(text.replace(anchor, insertion, 1), encoding="utf-8")
PY
}

build_torchvision_wheel() {
    local wheel_platform=""
    local src_dir="${APP_WHEELHOUSE_BUILD_ROOT}/vision"
    local dist_dir="${APP_WHEELHOUSE_BUILD_ROOT}/dist-vision"
    local -a cmake_args=()
    local -a built_wheels=()
    local cmake_args_string=""
    local target_torch_include=""
    local target_torch_csrc=""
    local target_torch_lib=""
    local target_triplet=""
    local python_sysconfigdata=""
    local python_sysconfig_export=""

    if [ -z "${TARGET_TORCH_WHEEL}" ] || [ -z "${TORCH_STAGING_DIR}" ]; then
        warn "Skipping torchvision cross wheel build because no target torch wheel is available"
        return 1
    fi

    if ! install_host_torch_for_vision; then
        warn "Failed to install the host torch wheel needed to drive the torchvision build"
        return 1
    fi

    wheel_platform="$(wheel_platform_tag || true)"
    if [ -z "${wheel_platform}" ]; then
        warn "Could not determine the riscv64 wheel platform tag for torchvision"
        return 1
    fi

    target_triplet="$(cross_target_triplet 2>/dev/null || true)"
    if [ -n "${target_triplet}" ]; then
        python_sysconfigdata="_sysconfigdata__linux_${target_triplet}"
        python_sysconfig_export="export _PYTHON_SYSCONFIGDATA_NAME=${python_sysconfigdata}"
    fi

    git_clone_ref https://github.com/pytorch/vision.git "${TORCHVISION_REF}" "${src_dir}" || {
        warn "Failed to clone torchvision ${TORCHVISION_REF}"
        return 1
    }

    patch_torchvision_setup "${src_dir}/setup.py" || {
        warn "Failed to patch torchvision for staged libtorch cross paths"
        return 1
    }

    rm -rf "${dist_dir}"
    mkdir -p "${dist_dir}"

    target_torch_include="${TORCH_STAGING_DIR}/torch/include"
    target_torch_csrc="${target_torch_include}/torch/csrc/api/include"
    target_torch_lib="${TORCH_STAGING_DIR}/torch/lib"

    append_common_cross_cmake_args cmake_args
    cmake_args_string="$(shell_quote_args "${cmake_args[@]}")"

    if ! (
        cd "${src_dir}" && \
        export CMAKE_GENERATOR=Ninja && \
        export CMAKE_ARGS="${cmake_args_string}" && \
        export _PYTHON_HOST_PLATFORM="${wheel_platform}" && \
        if [ -n "${python_sysconfig_export}" ]; then eval "${python_sysconfig_export}"; fi && \
        export FORCE_CUDA=0 FORCE_MPS=0 DEBUG=0 && \
        export PYTORCH_VERSION="${TARGET_TORCH_VERSION}" && \
        export TORCHVISION_TORCH_STAGING="${TORCH_STAGING_DIR}" && \
        export TORCHVISION_INCLUDE="${target_torch_include}:${target_torch_csrc}" && \
        export TORCHVISION_LIBRARY="${target_torch_lib}" && \
        export CFLAGS="${CFLAGS:+${CFLAGS} }-idirafter /usr/include" && \
        export CXXFLAGS="${CXXFLAGS:+${CXXFLAGS} }-idirafter /usr/include" && \
        "${BUILD_PYTHON}" setup.py bdist_wheel --plat-name "${wheel_platform}" -d "${dist_dir}"
    ); then
        warn "torchvision riscv64 cross wheel build failed; leaving it to the native torch stage"
        return 1
    fi

    retag_directory_wheels "${dist_dir}" torchvision "${wheel_platform}"

    shopt -s nullglob
    built_wheels=("${dist_dir}"/torchvision-*.whl)
    shopt -u nullglob
    if [ "${#built_wheels[@]}" -eq 0 ]; then
        warn "torchvision cross build completed without producing a wheel"
        return 1
    fi

    cp -a "${built_wheels[@]}" "${APP_WHEELHOUSE_DIR}/"
    log "Built torchvision cross wheel $(basename "${built_wheels[0]}")"
}

main() {
    prepare_workspace
    if ! prepare_build_environment; then
        return 0
    fi

    if ! build_torch_wheel; then
        warn "Continuing without prebuilt riscv64 torch/vision wheels"
        return 0
    fi

    if ! build_torchvision_wheel; then
        warn "Continuing without a prebuilt riscv64 torchvision wheel"
    fi

    shopt -s nullglob
    local wheel_path
    if compgen -G "${APP_WHEELHOUSE_DIR}/*.whl" >/dev/null 2>&1; then
        for wheel_path in "${APP_WHEELHOUSE_DIR}"/*.whl; do
            log "App wheelhouse artifact: $(basename "${wheel_path}")"
        done
    fi
    shopt -u nullglob
}

main "$@"
