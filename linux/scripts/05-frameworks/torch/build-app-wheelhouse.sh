#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/cross-env.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/cross-env.sh
fi

# shell_quote_args lives in common.sh, which cross-env.sh does NOT source.
# Without it both wheel builds died instantly at
# cmake_args_string="$(shell_quote_args ...)" ("command not found"), silently
# absorbed by the best-effort WARN path — the long-standing "riscv64 cross
# wheel build failed" was (at least partly) this.
for _common in \
    "/opt/scripts/core/common.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../../01-core/common.sh"; do
    if [ -f "${_common}" ]; then
        # shellcheck disable=SC1090,SC1091
        source "${_common}"
        break
    fi
done
unset _common

# Source canonical versions.env so PYTORCH_VERSION / TORCHVISION_VERSION are
# always available even when this script is invoked outside the orchestrator
# (which is the typical case in the media app-wheelhouse stage). Fallback paths
# below still exist but now mirror versions.env rather than drifting.
for _evf in \
    "/opt/scripts/core/versions.env" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../../01-core/versions.env"; do
    if [ -f "${_evf}" ]; then
        # shellcheck disable=SC1091
        set -a; source "${_evf}"; set +a
        break
    fi
done
unset _evf

: "${APP_WHEELHOUSE_DIR:=/opt/app-wheels}"
: "${APP_WHEELHOUSE_BUILD_ROOT:=/tmp/app-wheelhouse}"
: "${PYTORCH_REF:=${PYTORCH_VERSION:-v2.12.1}}"
: "${PYTORCH_VERSION:=${PYTORCH_REF#v}}"
: "${TORCHVISION_REF:=${TORCHVISION_VERSION:-v0.27.1}}"
: "${PYTORCH_HOST_INDEX_URL:=https://download.pytorch.org/whl/cpu}"
: "${DEFAULT_PYPI_INDEX_URL:=https://pypi.org/simple}"

if [ -f /opt/scripts/core/parallelism.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/parallelism.sh 2>/dev/null || true
  if declare -F compute_jobs_with_mem_cap >/dev/null 2>&1; then
    MAX_JOBS="${MAX_JOBS:-$(compute_jobs_with_mem_cap "" 2000)}"
  fi
fi
: "${MAX_JOBS:=$(nproc)}"

BUILD_PYTHON=""
TARGET_TORCH_WHEEL=""
TARGET_TORCH_VERSION=""
TORCH_STAGING_DIR=""

if ! command -v log >/dev/null 2>&1; then
  log() { printf '[INFO] %s\n' "$*"; }
fi
if ! command -v warn >/dev/null 2>&1; then
  warn() { printf '[WARN] %s\n' "$*" >&2; }
fi

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
    if command -v cross_wheel_platform_tag >/dev/null 2>&1; then
        cross_wheel_platform_tag
        return $?
    fi
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
        # Target Python stdlib provides /usr/lib/python3.X/_sysconfigdata__linux_<triplet>.py,
        # which resolve_target_python_sysconfig_export needs so the wheel builds
        # use the TARGET Python ABI metadata (correct extension suffixes) instead
        # of falling back to the host sysconfig. Own apt call: best-effort, and
        # install_target_packages groups are all-or-nothing.
        install_target_packages libpython3-stdlib || \
            warn "Target libpython3-stdlib unavailable; wheel builds will use host sysconfig"
        # Target sleef: pytorch's bundled sleef compiles its codegen tools
        # (mkrename/mkdisp) for the TARGET under cross and dies with
        # "Exec format error" when the build runs them on the host. With the
        # target libsleef-dev present, build_torch_wheel sets USE_SYSTEM_SLEEF=1
        # and skips the bundled build entirely. Best-effort (ports coverage).
        install_target_packages libsleef-dev || \
            warn "Target libsleef-dev unavailable; bundled sleef will fail under cross (Exec format error)"
        return 0
    fi

    apt-get install -y --no-install-recommends \
        git ninja-build cmake pkg-config unzip rsync \
        libopenblas-dev liblapack-dev zlib1g-dev libjpeg-dev libpng-dev libtiff-dev libwebp-dev
}

prepare_build_environment() {
    prepare_workspace

    if ! cross_build_is_active; then
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

# pytorch's setup.py does NOT forward our CMAKE_ARGS -D flags into its cmake
# invocation (verified from the logged configure line: none of the cross args
# were present; only CC/CXX env reached the build, so cmake configured as a
# NATIVE x86_64 build with a riscv64 compiler and cpuinfo picked x86 sources).
# CMake >= 3.21 honors the CMAKE_TOOLCHAIN_FILE ENVIRONMENT variable natively
# at project() time — the only reliable way to make a setup.py-driven cmake
# cross-aware. Keep it minimal: system identity only; compilers keep flowing
# via CC/CXX env exactly as they already (working) do.
write_cross_cmake_toolchain_file() {
    local path="${APP_WHEELHOUSE_BUILD_ROOT}/cross-toolchain.cmake"
    local processor="${CMAKE_SYSTEM_PROCESSOR:-}"
    if [ -z "${processor}" ]; then
        case "$(cross_target_arch 2>/dev/null || echo)" in
            riscv64) processor=riscv64 ;;
            arm64)   processor=aarch64 ;;
            *) return 1 ;;
        esac
    fi
    cat > "${path}" <<EOF
# Generated by build-app-wheelhouse.sh — minimal cross identity for
# setup.py-driven cmake builds (compilers come from CC/CXX env).
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR ${processor})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
EOF
    # The toolchain file is also our guaranteed channel for cache variables that
    # pytorch's setup.py won't forward from CMAKE_ARGS: hand ProtoBuf.cmake a
    # HOST-runnable protoc (see build_host_protoc in build_torch_wheel).
    if [ -n "${CROSS_HOST_PROTOC:-}" ] && [ -x "${CROSS_HOST_PROTOC}" ]; then
        printf 'set(CAFFE2_CUSTOM_PROTOC_EXECUTABLE "%s" CACHE FILEPATH "host protoc for cross builds")\n' \
            "${CROSS_HOST_PROTOC}" >> "${path}"
    fi
    printf '%s' "${path}"
}

# Build the sysconfigdata export string for the target Python, but ONLY if the
# module file is actually importable. Setting _PYTHON_SYSCONFIGDATA_NAME
# without providing the module GUARANTEES an instant ModuleNotFoundError in
# setup.py (that's exactly how the wheel builds used to die once they got past
# shell_quote_args). Searches the staged target Python first, then the apt
# target Python. Prints the export string (name + PYTHONPATH) or nothing.
resolve_target_python_sysconfig_export() {
    local target_triplet="" name="" stage_root="" dir="" search_root
    target_triplet="$(cross_target_triplet 2>/dev/null || true)"
    [ -n "${target_triplet}" ] || return 0
    name="_sysconfigdata__linux_${target_triplet}"

    stage_root="$(cross_target_python_root 2>/dev/null || true)"
    for search_root in \
        ${stage_root:+"${stage_root}/lib"} \
        "/usr/lib" ; do
        [ -d "${search_root}" ] || continue
        dir="$(find "${search_root}" -maxdepth 2 -name "${name}.py" -printf '%h\n' -quit 2>/dev/null || true)"
        [ -n "${dir}" ] && break
    done

    if [ -z "${dir}" ]; then
        warn "Target Python sysconfigdata ${name}.py not found under ${stage_root:-<no staged python>}/lib or /usr/lib; building with the HOST sysconfig (extension tags may need retagging)."
        return 0
    fi

    printf 'export _PYTHON_SYSCONFIGDATA_NAME=%q; export PYTHONPATH=%q${PYTHONPATH:+:${PYTHONPATH}}' \
        "${name}" "${dir}"
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
    local python_sysconfig_export=""

    wheel_platform="$(wheel_platform_tag || true)"
    if [ -z "${wheel_platform}" ]; then
        warn "Could not determine the riscv64 wheel platform tag for PyTorch"
        return 1
    fi

    # Export target sysconfigdata ONLY when the module is importable (name +
    # PYTHONPATH together); see resolve_target_python_sysconfig_export.
    python_sysconfig_export="$(resolve_target_python_sysconfig_export)"

    git_clone_ref https://github.com/pytorch/pytorch.git "${PYTORCH_REF}" "${src_dir}" --recursive --shallow-submodules || {
        warn "Failed to clone PyTorch ${PYTORCH_REF}"
        return 1
    }

    rm -rf "${dist_dir}"
    mkdir -p "${dist_dir}"

    # Bundled protobuf builds protoc for the TARGET; onnx codegen then execs it
    # on the HOST -> "Exec format error" (protoc-3.13.0.0). Build the canonical
    # host protoc with pytorch's own helper (scrubbed env: no cross toolchain)
    # and hand it to ProtoBuf.cmake via the generated toolchain file.
    local CROSS_HOST_PROTOC=""
    if [ -f "${src_dir}/scripts/build_host_protoc.sh" ]; then
        log "Building host protoc via scripts/build_host_protoc.sh..."
        if (cd "${src_dir}" && \
            env -u CC -u CXX -u AR -u RANLIB -u LD -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
                -u CMAKE_TOOLCHAIN_FILE -u CMAKE_SYSTEM_NAME -u CMAKE_SYSTEM_PROCESSOR \
                bash scripts/build_host_protoc.sh > /tmp/build_host_protoc.log 2>&1); then
            CROSS_HOST_PROTOC="${src_dir}/build_host_protoc/bin/protoc"
        fi
        if [ -x "${CROSS_HOST_PROTOC}" ]; then
            log "Host protoc ready: ${CROSS_HOST_PROTOC}"
        else
            CROSS_HOST_PROTOC=""
            warn "build_host_protoc.sh failed (tail of /tmp/build_host_protoc.log follows); onnx codegen will hit Exec format error"
            tail -20 /tmp/build_host_protoc.log >&2 || true
        fi
    else
        warn "pytorch has no scripts/build_host_protoc.sh at this ref; onnx codegen will hit Exec format error"
    fi

    # Bundled sleef cross-compiles its host-run codegen tools (mkrename) for
    # the target -> "Exec format error". Use the target's system sleef when the
    # dev package landed (see install_build_dependencies); otherwise keep the
    # bundled build so the failure stays visible in the log.
    local use_system_sleef=0
    if command -v cross_package_files_present >/dev/null 2>&1 && \
       cross_package_files_present "libsleef-dev:$(cross_target_arch 2>/dev/null || echo none)"; then
        use_system_sleef=1
        log "Using target system sleef (libsleef-dev) instead of pytorch's bundled sleef"
    else
        warn "Target libsleef-dev not present; bundled sleef will likely fail (Exec format error on mkrename)"
    fi

    append_common_cross_cmake_args cmake_args
    cmake_args+=("-DBLAS=OpenBLAS")
    cmake_args_string="$(shell_quote_args "${cmake_args[@]}")"

    if ! (
        cd "${src_dir}" && \
        export CMAKE_GENERATOR=Ninja && \
        export CMAKE_ARGS="${cmake_args_string}" && \
        { cross_toolchain_file="$(write_cross_cmake_toolchain_file || true)"; \
          [ -n "${cross_toolchain_file}" ] && export CMAKE_TOOLCHAIN_FILE="${cross_toolchain_file}"; true; } && \
        export _PYTHON_HOST_PLATFORM="${wheel_platform}" && \
        if [ -n "${python_sysconfig_export}" ]; then eval "${python_sysconfig_export}"; fi && \
        export PYTHON_EXECUTABLE="${BUILD_PYTHON}" Python_EXECUTABLE="${BUILD_PYTHON}" Python3_EXECUTABLE="${BUILD_PYTHON}" && \
        export MAX_JOBS="${MAX_JOBS}" && \
        export BLAS=OpenBLAS USE_NUMPY=1 && \
        export USE_CUDA=0 USE_CUDNN=0 USE_CUSPARSELT=0 USE_CUDSS=0 USE_CUFILE=0 USE_ROCM=0 USE_XPU=0 && \
        export USE_DISTRIBUTED=0 USE_GLOO=0 USE_MPI=0 USE_TENSORPIPE=0 USE_NCCL=0 && \
        export BUILD_TEST=0 BUILD_BINARY=0 USE_KINETO=0 && \
        export USE_FBGEMM=0 USE_MKLDNN=0 USE_NNPACK=0 USE_QNNPACK=0 USE_PYTORCH_QNNPACK=0 USE_XNNPACK=0 && \
        export USE_SYSTEM_SLEEF="${use_system_sleef}" && \
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

    bash /opt/scripts/core/apply-patch.sh \
        /opt/scripts/patches/torchvision/001-torch-staging-paths.patch \
        "$(dirname "${setup_py}")" \
        "torchvision setup.py: TORCHVISION_TORCH_STAGING env var support"
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

    # Export target sysconfigdata ONLY when the module is importable (name +
    # PYTHONPATH together); see resolve_target_python_sysconfig_export.
    python_sysconfig_export="$(resolve_target_python_sysconfig_export)"

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
        { cross_toolchain_file="$(write_cross_cmake_toolchain_file || true)"; \
          [ -n "${cross_toolchain_file}" ] && export CMAKE_TOOLCHAIN_FILE="${cross_toolchain_file}"; true; } && \
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
