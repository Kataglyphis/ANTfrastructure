#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/cross-env.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/cross-env.sh
fi

# shell_quote_args lives in common.sh, which cross-env.sh does not source.
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

# QNN SDK helpers (backlog QNN-LINUX): same dual-layout source as common.sh.
for _qnnmod in \
    "/opt/scripts/core/qnn-sdk.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../../01-core/qnn-sdk.sh"; do
    if [ -f "${_qnnmod}" ]; then
        # shellcheck disable=SC1090,SC1091
        source "${_qnnmod}"
        break
    fi
done
unset _qnnmod

# The cp314t twin helpers sit two levels up in the repo and in the RUN's per-file mount alike; a missing one fails the twin pass.
_ftw="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../../03-media/free-threaded-wheels.sh"
if [ -f "${_ftw}" ]; then
    # shellcheck source=../../03-media/free-threaded-wheels.sh
    source "${_ftw}"
fi
unset _ftw

# versions.env directly: the media app-wheelhouse stage runs this outside the orchestrator.
for _lvf in \
    "/opt/scripts/core/load-versions-env.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../../01-core/load-versions-env.sh"; do
    if [ -f "${_lvf}" ]; then
        # shellcheck disable=SC1091
        source "${_lvf}"
        break
    fi
done
unset _lvf
for _evf in \
    "/opt/scripts/core/versions.env" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../../01-core/versions.env"; do
    if [ -f "${_evf}" ]; then
        # Not `set -a; source`: load_versions_env keeps orchestrator-forwarded values.
        load_versions_env "${_evf}"
        break
    fi
done
unset _evf

: "${APP_WHEELHOUSE_DIR:=/opt/app-wheels}"
: "${APP_WHEELHOUSE_FT_DIR:=/opt/app-wheels-cp314t}"
: "${APP_WHEELHOUSE_BUILD_ROOT:=/tmp/app-wheelhouse}"
: "${PYTORCH_REF:=${PYTORCH_VERSION:-v2.13.0}}"
: "${PYTORCH_VERSION:=${PYTORCH_REF#v}}"
: "${TORCHVISION_REF:=${TORCHVISION_VERSION:-v0.28.0}}"
# The fallback only matters without versions.env.
: "${IREE_REF:=${IREE_VERSION:-v3.12.0}}"
: "${PYTORCH_HOST_INDEX_URL:=https://download.pytorch.org/whl/cpu}"
: "${DEFAULT_PYPI_INDEX_URL:=https://pypi.org/simple}"

if [ -f /opt/scripts/core/parallelism.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/parallelism.sh 2>/dev/null || true
  # torch's aten TUs peak ~4 GB per cc1plus, so budget 4 GB per job.
  if declare -F compute_cpp_heavy_jobs >/dev/null 2>&1; then
    MAX_JOBS="${MAX_JOBS:-$(compute_cpp_heavy_jobs "")}"
  elif declare -F compute_jobs_with_mem_cap >/dev/null 2>&1; then
    MAX_JOBS="${MAX_JOBS:-$(compute_jobs_with_mem_cap "" 4096)}"
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
    rm -rf "${APP_WHEELHOUSE_BUILD_ROOT}" "${APP_WHEELHOUSE_DIR}" "${APP_WHEELHOUSE_FT_DIR}"
    mkdir -p "${APP_WHEELHOUSE_BUILD_ROOT}" "${APP_WHEELHOUSE_DIR}" "${APP_WHEELHOUSE_FT_DIR}"
}

install_build_dependencies() {
    if command -v cross_apt_update >/dev/null 2>&1; then
        cross_apt_update -y
    else
        apt-get update -y
    fi

    if command -v install_host_packages >/dev/null 2>&1; then
        # ccache is a host tool; without it the multi-hour cross builds never hit the cache.
        install_host_packages git ninja-build cmake pkg-config unzip rsync ccache sccache
        install_host_packages libopenblas-dev liblapack-dev zlib1g-dev libjpeg-dev libpng-dev libtiff-dev libwebp-dev
        if ! install_target_packages libopenblas-dev liblapack-dev zlib1g-dev libjpeg-dev libpng-dev libtiff-dev libwebp-dev; then
            warn "Some riscv64 target build dependencies are unavailable; continuing with the staged sysroot"
        fi
        # Its sysconfigdata gives the target extension suffixes; own call, as a group is all-or-nothing.
        install_target_packages libpython3-stdlib || \
            warn "Target libpython3-stdlib unavailable; wheel builds will use host sysconfig"
        # Bundled sleef builds its codegen tools for the target and runs them on the host.
        install_target_packages libsleef-dev || \
            warn "Target libsleef-dev unavailable; bundled sleef will fail under cross (Exec format error)"
        return 0
    fi

    apt-get install -y --no-install-recommends \
        git ninja-build cmake pkg-config unzip rsync ccache sccache \
        libopenblas-dev liblapack-dev zlib1g-dev libjpeg-dev libpng-dev libtiff-dev libwebp-dev
}

install_native_build_dependencies() {
    # ccache is the decisive lever: IREE's bundled LLVM is a ~1 h compile.
    apt-get update -y || true
    apt-get install -y --no-install-recommends \
        git ninja-build cmake pkg-config unzip rsync ccache sccache || return 1
}

prepare_build_environment() {
    # main() already ran prepare_workspace, so the wheelhouse exists even when this bails.
    if cross_build_is_active; then
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
    else
        # Native amd64 source-builds only IREE; torch comes from PyPI.
        install_native_build_dependencies || {
            warn "Failed to install native IREE build dependencies; leaving the app wheelhouse empty"
            return 1
        }
    fi

    BUILD_PYTHON="$(require_host_python)" || return 1

    # Build executors are pinned (setuptools below torch's <82 ceiling); data-only deps float.
    uv pip install --python "${BUILD_PYTHON}" -U \
        "setuptools==${PY_SETUPTOOLS_LT82_VERSION:-81.0.0}" \
        "wheel==${PY_WHEEL_VERSION:-0.47.0}" \
        build cmake \
        "ninja==${PY_NINJA_VERSION:-1.13.0}" \
        numpy packaging pyyaml requests six typing-extensions \
        sympy filelock networkx jinja2
}

# torch's setup.py drops CMAKE_ARGS; CMake reads CMAKE_TOOLCHAIN_FILE from the environment instead.
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
    cat > "${path}" <<EOF || return 1
# Generated by build-app-wheelhouse.sh — minimal cross identity for
# setup.py-driven cmake builds (compilers come from CC/CXX env).
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR ${processor})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
EOF
    # The toolchain file is the one channel setup.py cannot drop: hand it a host-runnable protoc.
    if [ -n "${CROSS_HOST_PROTOC:-}" ] && [ -x "${CROSS_HOST_PROTOC}" ]; then
        printf 'set(CAFFE2_CUSTOM_PROTOC_EXECUTABLE "%s" CACHE FILEPATH "host protoc for cross builds")\n' \
            "${CROSS_HOST_PROTOC}" >> "${path}"
    fi
    # Without these pytorch silently turns BUILD_PYTHON off and the link fails on -ltorch_python.
    local py_inc py_lib
    # CROSS_PYTHON_*: the cp314t twin's target 3.14t; else the target GIL Python.
    py_inc="${CROSS_PYTHON_INCLUDE_DIR:-$(cross_target_python_include_dir 2>/dev/null || true)}"
    py_lib="${CROSS_PYTHON_LIBRARY:-$(cross_target_python_library 2>/dev/null || true)}"
    if [ -n "${py_inc}" ] && [ -d "${py_inc}" ] && [ -n "${py_lib}" ] && [ -f "${py_lib}" ]; then
        cat >> "${path}" <<EOF
set(Python_INCLUDE_DIR "${py_inc}" CACHE PATH "target Python include dir")
set(Python_LIBRARY "${py_lib}" CACHE FILEPATH "target Python library")
set(Python3_INCLUDE_DIR "${py_inc}" CACHE PATH "target Python include dir")
set(Python3_LIBRARY "${py_lib}" CACHE FILEPATH "target Python library")
EOF
    fi
    printf '%s' "${path}"
}

# Only when the module exists: _PYTHON_SYSCONFIGDATA_NAME without it is an instant ModuleNotFoundError.
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
    # CROSS_PYTHON_*: the cp314t twin's target 3.14t, whose one include dir holds its pyconfig.h; else the target GIL Python.
    if [ -n "${CROSS_PYTHON_INCLUDE_DIR:-}" ]; then
        target_python_include="${CROSS_PYTHON_INCLUDE_DIR}"
        target_python_library="${CROSS_PYTHON_LIBRARY:-}"
    else
        target_python_include="$(cross_target_python_include_dir 2>/dev/null || true)"
        target_python_arch_include="$(cross_target_python_arch_include_dir 2>/dev/null || true)"
        target_python_library="$(cross_target_python_library 2>/dev/null || true)"
    fi
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
    # Explicit: an empty qemu_runner would make the && list above the exit status.
    return 0
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

extract_torch_wheel() {
    TORCH_STAGING_DIR="${APP_WHEELHOUSE_BUILD_ROOT}/torch-staging"
    rm -rf "${TORCH_STAGING_DIR}"
    mkdir -p "${TORCH_STAGING_DIR}"
    unzip -q -o "${TARGET_TORCH_WHEEL}" -d "${TORCH_STAGING_DIR}"
}

# A cross bdist_wheel can drop torch._C; inject the cmake-built one and repack. No-op on a healthy wheel.
_torch_ensure_c_extension() {
    local dist_dir="$1"
    local wheel_path built_c_ext staging suffix triplet pyabi listing dest_name
    local build_torch_dir
    shopt -s nullglob
    local -a wheels=("${dist_dir}"/torch-*.whl)
    shopt -u nullglob
    [ "${#wheels[@]}" -gt 0 ] || return 0
    wheel_path="${wheels[0]}"

    # Read first: `unzip -l | grep -q` dies of SIGPIPE, which pipefail reports as absent.
    if ! listing="$(unzip -l "${wheel_path}" 2>/dev/null)"; then
        warn "cannot list ${wheel_path} (unzip failed); skipping the torch _C extension check"
        return 0
    fi
    # Already carries the top-level compiled extension? nothing to do.
    if grep -qE ' torch/_C[^/]*\.so$' <<<"${listing}"; then
        return 0
    fi

    # cmake links the ABI-mangled name; a literal torch/_C.so never appears. The wheel's own ABI, as the cp314t twin's tree holds both.
    build_torch_dir="${APP_WHEELHOUSE_BUILD_ROOT}/pytorch/torch"
    pyabi="$(basename "${wheel_path}" | sed -nE 's/.*-cp[0-9]+-cp([0-9]+t?)-.*/\1/p')"
    [ -n "${pyabi}" ] || pyabi="314"
    shopt -s nullglob
    local -a built_c_exts=("${build_torch_dir}"/_C.cpython-"${pyabi}"-*.so)
    shopt -u nullglob
    # nullglob cannot drop a metacharacter-free word, so test the plain name.
    [ ! -f "${build_torch_dir}/_C.so" ] || built_c_exts+=("${build_torch_dir}/_C.so")
    if [ "${#built_c_exts[@]}" -eq 0 ]; then
        warn "torch wheel lacks torch/_C*.so and no cmake-built ${build_torch_dir}/_C*.so exists; import torch WILL fail (missing C extension)"
        return 0
    fi
    built_c_ext="${built_c_exts[0]}"

    # Keep an ABI-mangled name, else synthesise one from the wheel's -cpXYZ- tag.
    dest_name="$(basename "${built_c_ext}")"
    if [ "${dest_name}" = "_C.so" ]; then
        triplet="$(cross_target_triplet 2>/dev/null || echo riscv64-linux-gnu)"
        suffix="cpython-${pyabi}-${triplet}.so"
        dest_name="_C.${suffix}"
    fi

    staging="${APP_WHEELHOUSE_BUILD_ROOT}/torch-cext-repack"
    rm -rf "${staging}"
    mkdir -p "${staging}"
    unzip -q -o "${wheel_path}" -d "${staging}"
    cp "${built_c_ext}" "${staging}/torch/${dest_name}"
    log "Injected missing torch/${dest_name} into $(basename "${wheel_path}") (pytorch ${PYTORCH_REF} cross bdist_wheel dropped the compiled C extension)"

    rm -f "${wheel_path}"
    if ! ( cd "${staging}" && "${BUILD_PYTHON}" -m wheel pack . -d "${dist_dir}" ); then
        warn "wheel pack failed while repackaging the torch _C extension"
        return 1
    fi
}

# build_torch_wheel's phase helpers read its locals by dynamic scope; call them only from there.
# shellcheck disable=SC2154

# Bundled protobuf builds protoc for the target, which onnx codegen then runs on the host.
_torch_build_host_protoc() {
    CROSS_HOST_PROTOC=""
    if [ ! -f "${src_dir}/scripts/build_host_protoc.sh" ]; then
        warn "pytorch has no scripts/build_host_protoc.sh at this ref; onnx codegen will hit Exec format error"
        return 0
    fi
    log "Building host protoc via scripts/build_host_protoc.sh..."
    # CMAKE_POLICY_VERSION_MINIMUM: cmake 4 refuses protobuf 3.13's cmake_minimum_required(<3.5).
    if (cd "${src_dir}" && \
        env -u AR -u RANLIB -u LD -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
            -u CMAKE_TOOLCHAIN_FILE -u CMAKE_SYSTEM_NAME -u CMAKE_SYSTEM_PROCESSOR \
            CC=gcc CXX=g++ \
            bash scripts/build_host_protoc.sh \
                --other-flags "-DCMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM:-3.5}" > /tmp/build_host_protoc.log 2>&1); then
        CROSS_HOST_PROTOC="${src_dir}/build_host_protoc/bin/protoc"
    fi
    # Run it, not just -x: a cross-built protoc is executable on disk only.
    if [ -n "${CROSS_HOST_PROTOC}" ] && "${CROSS_HOST_PROTOC}" --version >/dev/null 2>&1; then
        log "Host protoc ready: ${CROSS_HOST_PROTOC} ($("${CROSS_HOST_PROTOC}" --version 2>/dev/null))"
    else
        CROSS_HOST_PROTOC=""
        warn "build_host_protoc.sh failed or produced a non-host binary (tail of /tmp/build_host_protoc.log follows); onnx codegen will hit Exec format error"
        tail -20 /tmp/build_host_protoc.log >&2 || true
    fi
}

# Bundled sleef runs target-built codegen on the host; else keep it so the failure stays visible.
_torch_detect_system_sleef() {
    use_system_sleef=0
    if command -v cross_package_status_present >/dev/null 2>&1 && \
       cross_package_status_present "libsleef-dev:$(cross_target_arch 2>/dev/null || echo none)"; then
        use_system_sleef=1
        log "Using target system sleef (libsleef-dev) instead of pytorch's bundled sleef"
    else
        warn "Target libsleef-dev not present; bundled sleef will likely fail (Exec format error on mkrename)"
    fi
}

# pip wheel, not setup.py bdist_wheel: PyTorch 2.14 moved to scikit-build-core and removed that path.
_torch_run_setup_py() {
    (
        cd "${src_dir}" && \
        export CMAKE_GENERATOR=Ninja && \
        export CMAKE_ARGS="${cmake_args_string}" && \
        { cross_toolchain_file="$(write_cross_cmake_toolchain_file || true)"; \
          [ -n "${cross_toolchain_file}" ] || { warn "no cross toolchain file for torch; cmake would configure a NATIVE build with the cross compiler"; return 1; }; \
          export CMAKE_TOOLCHAIN_FILE="${cross_toolchain_file}"; } && \
        export _PYTHON_HOST_PLATFORM="${wheel_platform}" && \
        if [ -n "${python_sysconfig_export}" ]; then eval "${python_sysconfig_export}"; fi && \
        export PYTHON_EXECUTABLE="${BUILD_PYTHON}" Python_EXECUTABLE="${BUILD_PYTHON}" Python3_EXECUTABLE="${BUILD_PYTHON}" && \
        export MAX_JOBS="${MAX_JOBS}" && \
        export CCACHE_DIR="${CCACHE_DIR:-/var/cache/ccache}" CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-64G}" CCACHE_COMPRESS=1 && \
        export BLAS=OpenBLAS USE_NUMPY=1 && \
        export USE_CUDA=0 USE_CUDNN=0 USE_CUSPARSELT=0 USE_CUDSS=0 USE_CUFILE=0 USE_ROCM=0 USE_XPU=0 && \
        export USE_DISTRIBUTED=0 USE_GLOO=0 USE_MPI=0 USE_TENSORPIPE=0 USE_NCCL=0 && \
        export BUILD_TEST=0 BUILD_BINARY=0 USE_KINETO=0 && \
        export USE_FBGEMM=0 USE_MKLDNN=0 USE_NNPACK=0 USE_QNNPACK=0 USE_PYTORCH_QNNPACK=0 USE_XNNPACK=0 && \
        export USE_SYSTEM_SLEEF="${use_system_sleef}" && \
        # No OpenMP: the riscv64 cross GCC's libgomp is not reliably coinstallable in the sysroot.
        export USE_FLASH_ATTENTION=0 USE_MEM_EFF_ATTENTION=0 USE_OPENMP=0 && \
        export CFLAGS="${CFLAGS:+${CFLAGS} }-idirafter /usr/include" && \
        export CXXFLAGS="${CXXFLAGS:+${CXXFLAGS} }-idirafter /usr/include" && \
        "${BUILD_PYTHON}" -m pip install --quiet --disable-pip-version-check \
            "scikit-build-core>=1.0" "setuptools>=77.0.0,<82" numpy "packaging>=24.2" pyyaml && \
        "${BUILD_PYTHON}" -m pip wheel --no-build-isolation --no-deps \
            --wheel-dir "${dist_dir}" .
    )
}

# Sets the TARGET_TORCH_WHEEL/TARGET_TORCH_VERSION globals and extracts the wheel.
_collect_torch_wheel() {
    local -a built_wheels=()
    # Before the retag, so the repaired wheel takes the normal path.
    _torch_ensure_c_extension "${dist_dir}"
    retag_directory_wheels "${dist_dir}" torch "${wheel_platform}" "${BUILD_PYTHON}"

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
    extract_torch_wheel || return 1
    log "Built PyTorch cross wheel $(basename "${TARGET_TORCH_WHEEL}")"
}

build_torch_wheel() {
    local wheel_platform=""
    local src_dir="${APP_WHEELHOUSE_BUILD_ROOT}/pytorch"
    local dist_dir="${APP_WHEELHOUSE_BUILD_ROOT}/dist-torch"
    local -a cmake_args=()
    local cmake_args_string=""
    local python_sysconfig_export=""
    local CROSS_HOST_PROTOC=""   # set by _torch_build_host_protoc; read by toolchain file
    local use_system_sleef=0     # set by _torch_detect_system_sleef

    wheel_platform="$(wheel_platform_tag || true)"
    if [ -z "${wheel_platform}" ]; then
        warn "Could not determine the riscv64 wheel platform tag for PyTorch"
        return 1
    fi

    python_sysconfig_export="$(resolve_target_python_sysconfig_export)"

    git_clone_ref https://github.com/pytorch/pytorch.git "${PYTORCH_REF}" "${src_dir}" --recursive --shallow-submodules || {
        warn "Failed to clone PyTorch ${PYTORCH_REF}"
        return 1
    }

    rm -rf "${dist_dir}"
    mkdir -p "${dist_dir}"

    _torch_build_host_protoc
    _torch_detect_system_sleef

    _torch_cmake_args cmake_args
    cmake_args_string="$(shell_quote_args "${cmake_args[@]}")"

    if ! _torch_run_setup_py; then
        warn "PyTorch riscv64 cross wheel build failed; leaving it to the native torch stage"
        return 1
    fi

    _collect_torch_wheel || return 1
    _torch_build_free_threaded_wheel
}

# <array name>: torch's CMAKE_ARGS for BUILD_PYTHON and the target Python (CROSS_PYTHON_* for the twin).
_torch_cmake_args() {
    local -n _tca_ref="$1"
    local _cc_l
    append_common_cross_cmake_args _tca_ref
    _tca_ref+=("-DBLAS=OpenBLAS")
    # Cache the multi-hour aten compile; without a launcher the build runs plain.
    compiler_cache_launcher_env 2>/dev/null || true
    _cc_l="$(compiler_cache_launcher 2>/dev/null || true)"
    if [ -n "${_cc_l}" ]; then
        _tca_ref+=("-DCMAKE_C_COMPILER_LAUNCHER=${_cc_l}" "-DCMAKE_CXX_COMPILER_LAUNCHER=${_cc_l}")
    fi
    return 0
}

# The torch twin, gated by FT_TORCH_TWIN through its table row: the warm tree again on a cp314t venv, so only what sees Python rebuilds.
_torch_build_free_threaded_wheel() {
    local venv="${APP_WHEELHOUSE_BUILD_ROOT}/torch-ft-venv" t0
    declare -F ft_twin_start >/dev/null || { warn "torch: free-threaded-wheels.sh is not mounted; its RUN needs the per-file mount"; return 1; }
    ft_twin_start torch "${venv}" "${BUILD_PYTHON}" pip setuptools wheel numpy packaging pyyaml typing-extensions six \
        || { [ $? -eq 1 ] && return 0; return 1; }
    t0="$(date +%s)"
    local BUILD_PYTHON="${venv}/bin/python" dist_dir="${APP_WHEELHOUSE_BUILD_ROOT}/dist-torch-cp314t"
    local python_sysconfig_export cmake_args_string
    local CROSS_PYTHON_INCLUDE_DIR="${FT_TARGET_INCLUDE}" CROSS_PYTHON_LIBRARY="${FT_TARGET_LIBRARY}"
    local -a cmake_args=()
    python_sysconfig_export="$(ft_target_env)"
    # Built afresh, not the GIL pass's string plus overrides: its -DPYTHON_INCLUDE_DIR heads torch_python's include path (CON79 1b).
    _torch_cmake_args cmake_args
    # On the command line: the toolchain file's CACHE sets cannot move the GIL pass's cached Python, nor its FindPython results.
    cmake_args+=("-U" "_Python*" "-U" "Python_NumPy*" "-U" "Python3_NumPy*"
        "-DPython_INCLUDE_DIR=${FT_TARGET_INCLUDE}" "-DPython3_INCLUDE_DIRS=${FT_TARGET_INCLUDE}" "-DPython_LIBRARY=${FT_TARGET_LIBRARY}")
    cmake_args_string="$(shell_quote_args "${cmake_args[@]}")"
    rm -rf "${dist_dir}"; mkdir -p "${dist_dir}"
    # The GIL pass's module would otherwise ride into the twin, as IREE's did.
    rm -f "${src_dir}"/torch/_C.cpython-*.so
    if ! _torch_run_setup_py; then
        warn "torch: the cp314t pass over ${src_dir} failed"
        return 1
    fi
    log "torch: the cp314t pass took $(( $(date +%s) - t0 ))s in the warm tree"
    _torch_ensure_c_extension "${dist_dir}" || return 1
    retag_directory_wheels "${dist_dir}" torch "${wheel_platform}" "${BUILD_PYTHON}"
    ft_twin_store_built "${dist_dir}" "${APP_WHEELHOUSE_FT_DIR}" || return 1
    rm -rf "${venv}" "${dist_dir}"
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

# build_torchvision_wheel's phase helpers read its locals by dynamic scope; call them only from there.
# shellcheck disable=SC2154

# -O3 -DNDEBUG explicitly: a set $CFLAGS replaces sysconfig's, which left every extension at -O0.
_torchvision_run_setup_py() {
    (
        cd "${src_dir}" && \
        export CMAKE_GENERATOR=Ninja && \
        export CMAKE_ARGS="${cmake_args_string}" && \
        { cross_toolchain_file="$(write_cross_cmake_toolchain_file || true)"; \
          [ -n "${cross_toolchain_file}" ] || { warn "no cross toolchain file for torchvision; cmake would configure a NATIVE build with the cross compiler"; return 1; }; \
          export CMAKE_TOOLCHAIN_FILE="${cross_toolchain_file}"; } && \
        export _PYTHON_HOST_PLATFORM="${wheel_platform}" && \
        if [ -n "${python_sysconfig_export}" ]; then eval "${python_sysconfig_export}"; fi && \
        export FORCE_CUDA=0 FORCE_MPS=0 DEBUG=0 && \
        export PYTORCH_VERSION="${TARGET_TORCH_VERSION}" && \
        export TORCHVISION_TORCH_STAGING="${TORCH_STAGING_DIR}" && \
        export TORCHVISION_INCLUDE="${target_torch_include}:${target_torch_csrc}" && \
        export TORCHVISION_LIBRARY="${target_torch_lib}" && \
        _vis_multiarch="$(cross_target_triplet 2>/dev/null || true)" && \
        export CFLAGS="${CFLAGS:+${CFLAGS} }-O3 -DNDEBUG ${_vis_multiarch:+-idirafter /usr/include/${_vis_multiarch} }-idirafter /usr/include" && \
        export CXXFLAGS="${CXXFLAGS:+${CXXFLAGS} }-O3 -DNDEBUG ${_vis_multiarch:+-idirafter /usr/include/${_vis_multiarch} }-idirafter /usr/include" && \
        "${BUILD_PYTHON}" -m pip install --quiet --disable-pip-version-check \
            "scikit-build-core>=1.0" "setuptools>=77.0.0,<82" numpy "packaging>=24.2" pyyaml && \
        "${BUILD_PYTHON}" -m pip wheel --no-build-isolation --no-deps \
            --wheel-dir "${dist_dir}" .
    )
}

# cpp_extension swallows ninja's output; rerun ninja to surface the real compiler error.
_torchvision_ninja_diagnostic() {
    local _vis_ninja_dir
    _vis_ninja_dir="$(find "${src_dir}/build" -name build.ninja -printf '%h\n' -quit 2>/dev/null || true)"
    if [ -n "${_vis_ninja_dir}" ]; then
        warn "torchvision ninja diagnostic (${_vis_ninja_dir}):"
        (cd "${_vis_ninja_dir}" && ninja -v 2>&1 | tail -60) >&2 || true
    fi
}

# Retag, collect, install the built torchvision wheel. Reads dist_dir + wheel_platform.
_collect_torchvision_wheel() {
    local -a built_wheels=()
    retag_directory_wheels "${dist_dir}" torchvision "${wheel_platform}" "${BUILD_PYTHON}"

    shopt -s nullglob
    built_wheels=("${dist_dir}"/torchvision-*.whl)
    shopt -u nullglob
    if [ "${#built_wheels[@]}" -eq 0 ]; then
        warn "torchvision cross build completed without producing a wheel"
        return 1
    fi

    cp -a "${built_wheels[@]}" "${APP_WHEELHOUSE_DIR}/" || return 1
    log "Built torchvision cross wheel $(basename "${built_wheels[0]}")"
}

build_torchvision_wheel() {
    local wheel_platform=""
    local src_dir="${APP_WHEELHOUSE_BUILD_ROOT}/vision"
    local dist_dir="${APP_WHEELHOUSE_BUILD_ROOT}/dist-vision"
    local -a cmake_args=()
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

    if ! _torchvision_run_setup_py; then
        warn "torchvision riscv64 cross wheel build failed; leaving it to the native torch stage"
        _torchvision_ninja_diagnostic
        return 1
    fi

    _collect_torchvision_wheel
}

# IREE stages. See docs/iree-two-stage-build.md

# Sets wheel_platform. Returns 1 when IREE cannot be built at all.
_iree_check_prereqs() {
    command -v cmake >/dev/null 2>&1 || { warn "cmake absent; skipping IREE riscv64 runtime wheel"; return 1; }
    command -v ninja >/dev/null 2>&1 || { warn "ninja absent; skipping IREE riscv64 runtime wheel"; return 1; }

    wheel_platform="$(wheel_platform_tag || true)"
    [ -n "${wheel_platform}" ] || { warn "no riscv64 wheel platform tag; skipping IREE"; return 1; }
}

# IREE's own LLVM fork takes ~1 h, so cache it; sets ccache_cmake_args/_iree_launcher, so nothing here is local.
_iree_setup_compiler_cache() {
    if command -v ccache >/dev/null 2>&1; then
        export CCACHE_DIR="${CCACHE_DIR:-/var/cache/ccache}"
        export CCACHE_MAXSIZE="${IREE_CCACHE_MAXSIZE:-64G}"
        export CCACHE_COMPRESS=1
        export CCACHE_SLOPPINESS="pch_defines,time_macros,include_file_mtime,include_file_ctime"
        mkdir -p "${CCACHE_DIR}" 2>/dev/null || true
        # Report the limit the cache really carries, so the log proves it.
        ccache -M "${CCACHE_MAXSIZE}" 2>/dev/null || warn "could not set ccache max size to ${CCACHE_MAXSIZE}"
        echo "[INFO] IREE ccache limit now: $(ccache -p 2>/dev/null | awk '/max_size/{print $2, $3}' || echo unknown)"
        # sccache ignores `-M`: its cap comes from SCCACHE_CACHE_SIZE, which mirrors the override below.
        compiler_cache_launcher_env 2>/dev/null || true
        _iree_launcher="$(compiler_cache_launcher 2>/dev/null || echo ccache)"
        case "${_iree_launcher}" in *sccache*)
            # Quiet by default; IREE_SCCACHE_LOG=sccache=info brings the client log back.
            export SCCACHE_LOG="${IREE_SCCACHE_LOG:-}"
            export SCCACHE_ERROR_LOG="${SCCACHE_ERROR_LOG:-/tmp/sccache-iree.log}" ;;
        esac
        case "${_iree_launcher}" in *sccache*)
            export SCCACHE_CACHE_SIZE="${IREE_CCACHE_MAXSIZE:-64G}"
            echo "[INFO] IREE sccache cap: SCCACHE_CACHE_SIZE=${SCCACHE_CACHE_SIZE}" ;;
        esac
        ccache_cmake_args=("-DCMAKE_C_COMPILER_LAUNCHER=${_iree_launcher}" "-DCMAKE_CXX_COMPILER_LAUNCHER=${_iree_launcher}")
        echo "[INFO] IREE ccache ON: CCACHE_DIR=${CCACHE_DIR} MAXSIZE=${CCACHE_MAXSIZE} (LLVM rebuild is one-time; reruns cache-hit)"
    else
        warn "ccache not found — IREE bundled LLVM will rebuild from scratch every run (no cross-run cache)"
    fi
}

# Fetch the pinned IREE tree into src_dir. Returns 1 on clone/submodule failure.
_iree_fetch_source() {
    # All submodules: the compiler ships the stablehlo and torch input dialects, not just TOSA/linalg.
    rm -rf "${src_dir}"
    if ! git clone --branch "${IREE_REF}" --depth 1 https://github.com/iree-org/iree.git "${src_dir}"; then
        warn "IREE clone ${IREE_REF} failed"; return 1
    fi
    if ! ( cd "${src_dir}" && git submodule update --init --recursive --depth 1 ); then
        warn "IREE submodule init failed"; return 1
    fi
}

# Defeat IREE's abi3 wheel tagging in the freshly cloned tree (src_dir).
_iree_patch_setup_py_abi3() {
    # setup.py stamps abi3 with no escape hatch; the configure's STABLE_ABI=OFF is the other half.
    local _sp
    for _sp in "${src_dir}/runtime/setup.py" "${src_dir}/compiler/setup.py"; do
        if [ -f "${_sp}" ]; then
            sed -i 's/sys\.version_info >= (3, 12) and not /False and /' "${_sp}"
        fi
    done
}

# <log> <cmake args>...: configures twice, because IREE links iree::base before the libbacktrace subdirectory caches its target.
_iree_configure_settled() {
    local log="$1"
    shift
    cmake "$@" > "${log}" 2>&1 || return 1
    cmake "$@" >> "${log}" 2>&1
}

# See docs/iree-two-stage-build.md § Stage 1 — the native amd64 host tools
_iree_build_host_stage() {
    # See docs/iree-two-stage-build.md § The host tools stage 2 needs from IREE_HOST_BIN_DIR
    local -a host_required_tools=(iree-c-embed-data iree-flatcc-cli)
    local -a host_compiler_modes=(OFF ON)
    # A COMPILER=OFF target imports iree-tblgen from the host, and only an ON host build installs it.
    case "${IREE_CROSS_BUILD_COMPILER}" in
      ON|on|1|true|TRUE|yes|YES) : ;;
      *)
        host_required_tools+=(iree-tblgen)
        host_compiler_modes=(ON)
        ;;
    esac
    local host_stage_ok=0 host_compiler_mode="" host_tool="" host_tools_missing=""
    for host_compiler_mode in "${host_compiler_modes[@]}"; do
        rm -rf "${host_build}" "${host_install}"
        log "IREE host stage: configuring with IREE_BUILD_COMPILER=${host_compiler_mode}"
        if ! env -u CC -u CXX -u CPP -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
                 -u AR -u RANLIB -u CMAKE_TOOLCHAIN_FILE -u CMAKE_ARGS \
                cmake -G Ninja -S "${src_dir}" -B "${host_build}" \
                "${ccache_cmake_args[@]}" \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_C_COMPILER="${host_cc}" \
                -DCMAKE_CXX_COMPILER="${host_cxx}" \
                -DIREE_BUILD_COMPILER="${host_compiler_mode}" \
                -DIREE_BUILD_PYTHON_BINDINGS=OFF \
                -DIREE_BUILD_SAMPLES=OFF \
                -DIREE_BUILD_TESTS=OFF \
                -DIREE_ENABLE_WERROR_FLAG=OFF \
                -DCMAKE_INSTALL_PREFIX="${host_install}" \
                -DPython_EXECUTABLE="${BUILD_PYTHON}" \
                -DPython3_EXECUTABLE="${BUILD_PYTHON}"; then
            warn "IREE host configure (IREE_BUILD_COMPILER=${host_compiler_mode}) failed"
            continue
        fi
        # BuildKit collapses ninja's output, so the log tail is the only way to see the error.
        if ! env -u CC -u CXX -u CPP -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
                 -u AR -u RANLIB -u CMAKE_TOOLCHAIN_FILE -u CMAKE_ARGS \
                cmake --build "${host_build}" --target install -- -j"${MAX_JOBS}" \
                > "${host_build}.log" 2>&1; then
            warn "IREE host build (IREE_BUILD_COMPILER=${host_compiler_mode}) failed"
            echo "----- IREE host build: last 80 log lines -----"
            tail -n 80 "${host_build}.log" 2>/dev/null
            echo "----- end IREE host build log -----"
            # No escalation: ON's graph is a superset of OFF's and would fail the same way hours later.
            warn "not escalating to IREE_BUILD_COMPILER=ON: its build graph is a superset of this one, so it would fail the same way after a multi-hour LLVM compile"
            break
        fi
        host_tools_missing=""
        for host_tool in "${host_required_tools[@]}"; do
            [ -x "${host_install}/bin/${host_tool}" ] || host_tools_missing+=" ${host_tool}"
        done
        if [ -z "${host_tools_missing}" ]; then
            log "IREE host stage OK (IREE_BUILD_COMPILER=${host_compiler_mode}); IREE_HOST_BIN_DIR tools present: ${host_required_tools[*]}"
            host_stage_ok=1
            break
        fi
        warn "IREE host stage (IREE_BUILD_COMPILER=${host_compiler_mode}) left ${host_install}/bin missing:${host_tools_missing} — retrying with the full host compiler"
    done
    if [ "${host_stage_ok}" != "1" ]; then
        warn "IREE host stage failed in both COMPILER=OFF and COMPILER=ON modes; cannot build the target IREE wheels"
        return 1
    fi
}

# See docs/iree-two-stage-build.md § Stage 2 — cross the runtime and the Python bindings
_iree_build_target_cross() {
    toolchain_file="$(write_cross_cmake_toolchain_file || true)"
    [ -n "${toolchain_file}" ] || { warn "no cross toolchain file for IREE; skipping"; return 1; }
    append_common_cross_cmake_args cmake_args

    # LLVM takes its default triple from the build host; unpinned, a target iree-compile emits x86_64 code.
    iree_target_triple="$(cross_target_triplet 2>/dev/null || true)"
    if [ -n "${iree_target_triple}" ]; then
        cmake_args+=(
            "-DLLVM_HOST_TRIPLE=${iree_target_triple}"
            "-DLLVM_DEFAULT_TARGET_TRIPLE=${iree_target_triple}"
        )
    fi

    # Target SOABI for the nanobind modules; set only now, so the stage-1 host tools kept the host config.
    local iree_sysconfig_export=""
    iree_sysconfig_export="$(resolve_target_python_sysconfig_export)"
    if [ -n "${iree_sysconfig_export}" ]; then eval "${iree_sysconfig_export}"; fi

    # LLVM's NATIVE tblgen sub-build defaults to the cross compilers; ';' is CMake's list separator.
    local native_flags="-DCMAKE_C_COMPILER=${host_cc};-DCMAKE_CXX_COMPILER=${host_cxx}"
    if [ "${#ccache_cmake_args[@]}" -gt 0 ]; then
        native_flags="${native_flags};-DCMAKE_C_COMPILER_LAUNCHER=${_iree_launcher:-ccache};-DCMAKE_CXX_COMPILER_LAUNCHER=${_iree_launcher:-ccache}"
    fi

    rm -rf "${target_build}"
    # Runtime-only unless IREE_CROSS_BUILD_COMPILER=ON, so expect only the wheels it builds.
    case "${IREE_CROSS_BUILD_COMPILER}" in
      [Oo][Nn]|1|[Tt][Rr][Uu][Ee]) iree_wheel_projects=(compiler runtime) ;;
      *)                           iree_wheel_projects=(runtime) ;;
    esac
    if ! _iree_configure_settled "${target_build}.cfg.log" -G Ninja -S "${src_dir}" -B "${target_build}" \
            -DCMAKE_TOOLCHAIN_FILE="${toolchain_file}" \
            "${cmake_args[@]}" \
            "${ccache_cmake_args[@]}" \
            -DCROSS_TOOLCHAIN_FLAGS_NATIVE="${native_flags}" \
            -DIREE_HOST_BIN_DIR="${host_install}/bin" \
            -DIREE_BUILD_COMPILER="${IREE_CROSS_BUILD_COMPILER}" \
            -DIREE_BUILD_PYTHON_BINDINGS=ON \
            -DIREE_ENABLE_PYTHON_STABLE_ABI=OFF \
            -DIREE_BUILD_SAMPLES=OFF \
            -DIREE_BUILD_TESTS=OFF \
            -DIREE_OUTPUT_FORMAT_C=OFF \
            -DIREE_ENABLE_WERROR_FLAG=OFF \
            -DIREE_HAL_DRIVER_LOCAL_SYNC=ON \
            -DIREE_HAL_DRIVER_LOCAL_TASK=ON \
            -DCMAKE_BUILD_TYPE=Release; then
        warn "IREE riscv64 runtime configure failed (best-effort); continuing without it"
        echo "----- IREE target configure: last 80 log lines -----"
        tail -n 80 "${target_build}.cfg.log" 2>/dev/null
        echo "----- end IREE target configure log -----"
        return 1
    fi
    if ! cmake --build "${target_build}" -- -j"${MAX_JOBS}" > "${target_build}.log" 2>&1; then
        warn "IREE riscv64 runtime build failed (best-effort); continuing without it"
        echo "----- IREE target build: last 80 log lines -----"
        tail -n 80 "${target_build}.log" 2>/dev/null
        echo "----- end IREE target build log -----"
        return 1
    fi
}

# Native amd64: one stage, no host/target split; leaves iree_wheel_projects empty, so both wheels.
_iree_build_target_native() {
    local native_cc="" native_cxx=""
    for native_cc in /usr/bin/gcc /usr/bin/cc /usr/bin/clang; do [ -x "${native_cc}" ] && break; done
    for native_cxx in /usr/bin/g++ /usr/bin/c++ /usr/bin/clang++; do [ -x "${native_cxx}" ] && break; done
    rm -rf "${target_build}"
    if ! _iree_configure_settled "${target_build}.cfg.log" -G Ninja -S "${src_dir}" -B "${target_build}" \
            "${ccache_cmake_args[@]}" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_C_COMPILER="${native_cc}" \
            -DCMAKE_CXX_COMPILER="${native_cxx}" \
            -DIREE_BUILD_COMPILER=ON \
            -DIREE_BUILD_PYTHON_BINDINGS=ON \
            -DIREE_ENABLE_PYTHON_STABLE_ABI=OFF \
            -DIREE_BUILD_SAMPLES=OFF \
            -DIREE_BUILD_TESTS=OFF \
            -DIREE_OUTPUT_FORMAT_C=OFF \
            -DIREE_ENABLE_WERROR_FLAG=OFF \
            -DIREE_HAL_DRIVER_LOCAL_SYNC=ON \
            -DIREE_HAL_DRIVER_LOCAL_TASK=ON \
            -DPython_EXECUTABLE="${BUILD_PYTHON}" \
            -DPython3_EXECUTABLE="${BUILD_PYTHON}"; then
        warn "IREE native configure failed"
        echo "----- IREE native configure: last 80 log lines -----"
        tail -n 80 "${target_build}.cfg.log" 2>/dev/null
        echo "----- end IREE native configure log -----"
        return 1
    fi
    if ! cmake --build "${target_build}" -- -j"${MAX_JOBS}" > "${target_build}.log" 2>&1; then
        warn "IREE native build failed"
        echo "----- IREE native build: last 80 log lines -----"
        tail -n 80 "${target_build}.log" 2>/dev/null
        echo "----- end IREE native build log -----"
        return 1
    fi
}

# Empty iree_wheel_projects means both, and the cp314t pass after it reads the list this sets.
_iree_package_wheels() {
    rm -rf "${dist_dir}"; mkdir -p "${dist_dir}"
    local _proj _pkg
    [ "${#iree_wheel_projects[@]}" -gt 0 ] || iree_wheel_projects=(compiler runtime)
    for _proj in "${iree_wheel_projects[@]}"; do
        _pkg="iree_base_${_proj}"
        if [ ! -d "${target_build}/${_proj}" ]; then
            warn "IREE target build produced no ${_proj}/ wheel project"; return 1
        fi
        if ! "${BUILD_PYTHON}" -m pip wheel "${target_build}/${_proj}" -w "${dist_dir}" --no-deps --no-build-isolation > "${target_build}.${_proj}-wheel.log" 2>&1; then
            warn "IREE riscv64 ${_proj} wheel packaging failed"
            echo "----- IREE ${_proj} wheel: last 60 log lines -----"
            tail -n 60 "${target_build}.${_proj}-wheel.log" 2>/dev/null
            echo "----- end IREE ${_proj} wheel log -----"
            return 1
        fi
        retag_directory_wheels "${dist_dir}" "${_pkg}" "${wheel_platform}" "${BUILD_PYTHON}"
    done

    shopt -s nullglob
    local -a wheels=("${dist_dir}"/iree_base_compiler-*.whl "${dist_dir}"/iree_base_runtime-*.whl "${dist_dir}"/iree-*.whl)
    shopt -u nullglob
    if [ "${#wheels[@]}" -lt "${#iree_wheel_projects[@]}" ]; then
        warn "IREE build produced ${#wheels[@]} wheel(s), expected ${#iree_wheel_projects[@]} (${iree_wheel_projects[*]})"; return 1
    fi
    cp -a "${wheels[@]}" "${APP_WHEELHOUSE_DIR}/"
    log "Built IREE wheels: $(cd "${dist_dir}" && echo iree_base_*-*.whl)"
}

# The wheels again on a cp314t venv in the warm target tree, so only the nanobind modules rebuild.
_iree_package_free_threaded_wheels() {
    local venv="${APP_WHEELHOUSE_BUILD_ROOT}/iree-ft-venv" ft_dist="${APP_WHEELHOUSE_BUILD_ROOT}/dist-iree-cp314t"
    local _proj t0
    declare -F ft_twin_start >/dev/null || { warn "IREE: free-threaded-wheels.sh is not mounted; its RUN needs the per-file mount"; return 1; }
    ft_twin_start iree-base-runtime "${venv}" "${BUILD_PYTHON}" pip setuptools wheel numpy || { [ $? -eq 1 ] && return 0; return 1; }
    t0="$(date +%s)"
    _iree_free_threaded_rebuild "${venv}/bin/python" || return 1
    log "IREE: the free-threaded rebuild took $(( $(date +%s) - t0 ))s in the warm ${target_build}"
    rm -rf "${ft_dist}"
    for _proj in "${iree_wheel_projects[@]}"; do
        ft_twin_wanted "iree-base-${_proj}" || return 1
        # setup.py installs into the build/ beside it, where the GIL pass's modules would ride into the cp314t wheel.
        rm -rf "${target_build:?}/${_proj}/build"
        if ! "${venv}/bin/python" -m pip wheel "${target_build}/${_proj}" -w "${ft_dist}/${_proj}" --no-deps --no-build-isolation \
                > "${target_build}.${_proj}-ft-wheel.log" 2>&1; then
            warn "IREE ${_proj} cp314t wheel packaging failed"
            tail -n 60 "${target_build}.${_proj}-ft-wheel.log" 2>/dev/null
            return 1
        fi
        retag_directory_wheels "${ft_dist}/${_proj}" "iree_base_${_proj}" "${wheel_platform}" "${venv}/bin/python"
        ft_twin_store_built "${ft_dist}/${_proj}" "${APP_WHEELHOUSE_FT_DIR}" || return 1
    done
}

# <free-threaded python>: reconfigure the target tree onto it and rebuild; what does not see Python stays built.
_iree_free_threaded_rebuild() {
    local -a py_args=("-DPython_EXECUTABLE=$1" "-DPython3_EXECUTABLE=$1")
    if [ -n "${FT_TARGET_INCLUDE:-}" ]; then
        # The GIL configure cached the target GIL headers for both FindPython spellings; the twin moves both and drops their results.
        py_args+=("-U" "_Python*" "-U" "Python_NumPy*" "-U" "Python3_NumPy*"
                  "-DPython_INCLUDE_DIR=${FT_TARGET_INCLUDE}" "-DPython3_INCLUDE_DIR=${FT_TARGET_INCLUDE}" "-DPYTHON_INCLUDE_DIR=${FT_TARGET_INCLUDE}" "-DPython3_INCLUDE_DIRS=${FT_TARGET_INCLUDE}"
                  "-DPython_LIBRARY=${FT_TARGET_LIBRARY}" "-DPython3_LIBRARY=${FT_TARGET_LIBRARY}" "-DPYTHON_LIBRARY=${FT_TARGET_LIBRARY}")
        eval "$(ft_target_env)"
    fi
    if ! cmake -S "${src_dir}" -B "${target_build}" "${py_args[@]}" \
            > "${target_build}.ft-cfg.log" 2>&1 \
       || ! cmake --build "${target_build}" -- -j"${MAX_JOBS}" > "${target_build}.ft.log" 2>&1; then
        warn "IREE free-threaded rebuild failed"
        tail -n 80 "${target_build}.ft-cfg.log" "${target_build}.ft.log" 2>/dev/null
        return 1
    fi
}

build_iree_wheels() {
    # Defaulted here, not at file scope: the stage suites extract this block alone.
    : "${IREE_CROSS_BUILD_COMPILER:=OFF}"
    # Set by the cross branch; declared here so set -u holds on the native path.
    local -a iree_wheel_projects=()
    local src_dir="${APP_WHEELHOUSE_BUILD_ROOT}/iree"
    local host_build="${APP_WHEELHOUSE_BUILD_ROOT}/iree-build-host"
    local host_install="${host_build}/install"
    local target_build="${APP_WHEELHOUSE_BUILD_ROOT}/iree-build-target"
    local dist_dir="${APP_WHEELHOUSE_BUILD_ROOT}/dist-iree"
    local wheel_platform="" toolchain_file="" iree_target_triple=""
    local -a cmake_args=()

    _iree_check_prereqs || return 1

    # Declared here, not in the helper, or the build steps below can't see it.
    local -a ccache_cmake_args=()
    _iree_setup_compiler_cache

    _iree_fetch_source || return 1
    _iree_patch_setup_py_abi3
    # No QNN flags: IREE has no such options and no Qualcomm NPU path.

    if cross_build_is_active; then
        # Stage 1 builds with the host compilers, stage 2 pins LLVM's NATIVE sub-build to them.
        local host_cc="" host_cxx=""
        for host_cc in /usr/bin/gcc /usr/bin/cc /usr/bin/clang; do [ -x "${host_cc}" ] && break; done
        for host_cxx in /usr/bin/g++ /usr/bin/c++ /usr/bin/clang++; do [ -x "${host_cxx}" ] && break; done
        _iree_build_host_stage || return 1
        _iree_build_target_cross || return 1
    else
        # ===== amd64 NATIVE: single-stage build =====
        _iree_build_target_native || return 1
    fi

    _iree_package_wheels || return 1
    _iree_package_free_threaded_wheels
}

main() {
    prepare_workspace
    if ! prepare_build_environment; then
        # Deliberate: an empty wheelhouse, not a failed media build.
        warn "app wheelhouse: environment not ready (see the warning above) — shipping an EMPTY wheelhouse"
        return 0
    fi

    # Best-effort riscv64-only torch/vision: a failure must not skip the required IREE build.
    if [ "$(cross_target_arch 2>/dev/null || echo)" = "riscv64" ]; then
        if ! build_torch_wheel; then
            warn "riscv64 torch cross-wheel failed — native torch stage is the fallback; continuing to IREE"
        fi
        if ! build_torchvision_wheel; then
            warn "Continuing without a prebuilt riscv64 torchvision wheel"
        fi
    fi

    # IREE is required on every arch; ALLOW_IREE_BUILD_FAIL=1 only for a deliberate IREE-less image.
    if ! build_iree_wheels; then
        if [ "${ALLOW_IREE_BUILD_FAIL:-0}" = "1" ]; then
            warn "IREE build failed but ALLOW_IREE_BUILD_FAIL=1 set — continuing without it"
        else
            err "IREE build FAILED — IREE is required (see the dumped build log above). Set ALLOW_IREE_BUILD_FAIL=1 only for a deliberate IREE-less image."
        fi
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
