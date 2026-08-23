#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# build-litert.sh - Build and install LiteRT from source
# ==============================================================================
#
# Build Acceleration:
#   USE_CCACHE=true     Enable ccache for faster rebuilds (default: true)
#   USE_LLD=true        Use lld linker for faster linking (default: true)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../core/common.sh"
media_common_init "${SCRIPT_DIR}"

case "${1:-}" in
  -h|--help)
    echo "Usage: $0 [version]"
    echo ""
    echo "Build and install LiteRT (TensorFlow Lite) from source."
    echo ""
    echo "Arguments:"
    echo "  version  LiteRT release tag (default: v2.1.6 or \$LITERT_VERSION)"
    echo ""
    echo "Environment:"
    echo "  LITERT_PREFIX   Install prefix (default: /usr/local)"
    echo "  BUILD_TYPE      Release | Debug (default: Release)"
    echo "  FORCE_REBUILD=1 Force rebuild even if already installed"
    echo "  USE_CCACHE      Enable ccache (default: true)"
    echo "  USE_LLD         Use lld linker (default: true)"
    exit 0
    ;;
esac

LITERT_VERSION="${LITERT_VERSION:-${1:-v2.1.6}}"
: "${LITERT_SRC:=${TMPDIR:-/tmp}/litert-$$}"
: "${LITERT_PREFIX:=/usr/local}"
: "${BUILD_TYPE:=Release}"
# LiteRT-LM compiles PyTorch (torch_cpu); its aten/autograd translation units peak
# at ~4GB per cc1plus -- far above the ~2GB/job that media_jobs assumes. At nproc-
# scale parallelism (-j30 on a 32-core host) that OOM-kills cc1plus and can stall/
# cancel the whole buildkit solve, especially under other memory load (e.g. a
# Folding@home core). compute_cpp_heavy_jobs budgets ~4GB/job for exactly this
# class of build; falls back to media_jobs if the helper is somehow unavailable.
# Override with PARALLEL_JOBS=N or NPROC=N.
: "${NPROC:=$(compute_cpp_heavy_jobs "" 2>/dev/null || media_jobs)}"
: "${SKIP_DEP_INSTALL:=false}"

setup_host_python_with_major_minor

info Building LiteRT ${LITERT_VERSION}
info Using JOBS=${NPROC}
info Install prefix: ${LITERT_PREFIX}

fetch_litert() {
    info Fetching LiteRT ${LITERT_VERSION} source...
    retry 3 10 "LiteRT git clone" clone_or_update_repo "https://github.com/google-ai-edge/LiteRT.git" "${LITERT_SRC}" "${LITERT_VERSION}"
    cd "${LITERT_SRC}"
    info LiteRT version: $(git describe --tags 2>/dev/null || echo 'unknown')
}

resolve_host_compiler() {
    local lang="$1"
    resolve_host_compiler_for_lang "${lang}"
}

# prepare_host_compiler_wrapper is provided by 01-core/compiler-resolution.sh
# (loaded via media_common_init). The canonical version is a superset of the
# former local copy — it falls back to a hand-written wrapper when
# make_named_host_compiler_wrapper is unavailable.

resolve_litert_tflite_host_tools_dir() {
    local candidate=""

    for candidate in \
        "${LITERT_SRC}/host_flatc_build/_deps/flatbuffers-build" \
        "${LITERT_SRC}/litert/host_flatc_build/_deps/flatbuffers-build" \
        "${LITERT_SRC}/litert/cmake_build/flatbuffers-flatc/bin" \
        "${LITERT_SRC}/litert/cmake_build/_deps/flatbuffers-build"; do
        if [ -x "${candidate}/flatc" ]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done

    candidate="$(command -v flatc 2>/dev/null || true)"
    if [ -n "${candidate}" ]; then
        dirname "${candidate}"
        return 0
    fi

    return 1
}

append_litert_preferred_cmake_compiler_args() {
  local -n out_args_ref=$1
  local native_clang=""
  local native_clangxx=""

  if cross_build_is_active; then
      return 0
  fi

  # Native/amd64 artifact builds should prefer the source-built Clang from the
  # toolchain image. GCC 16 currently ICEs in LiteRT's Samsung vendor code.
  if [ -x /usr/local/bin/clang ] && [ -x /usr/local/bin/clang++ ]; then
      native_clang="/usr/local/bin/clang"
      native_clangxx="/usr/local/bin/clang++"
  else
      native_clang="$(command -v clang 2>/dev/null || true)"
      native_clangxx="$(command -v clang++ 2>/dev/null || true)"
  fi

  if [ -n "${native_clang}" ] && [ -n "${native_clangxx}" ]; then
      out_args_ref+=(
          "-DCMAKE_C_COMPILER=${native_clang}"
          "-DCMAKE_CXX_COMPILER=${native_clangxx}"
          "-DCMAKE_ASM_COMPILER=${native_clang}"
          "-DCMAKE_C_FLAGS=-Wno-c2y-extensions"
          "-DCMAKE_CXX_FLAGS=-Wno-c2y-extensions"
      )
      info Using native Clang toolchain for LiteRT: ${native_clang} / ${native_clangxx}
      info Disabling Clang C2y extension pedantic errors for bundled googlebenchmark
  fi
}

append_litert_cache_linker_args() {
  append_cmake_cache_linker_args "$@"
}

# EIGEN-NET (2026-08-21): mirrored eigen fetch (LITERT_EIGEN_FETCH_FLAGS +
# litert_eigen_fetch_flags_str). Defined ONCE in the file below and sourced by
# both LiteRT builds -- the flags used to be duplicated verbatim here and in the
# android lane, which is exactly how a mirror silently goes missing from one of
# them. That file sits under android/ because it is the only directory both
# images ship (see its header); Dockerfile.media bind-mounts this whole litert
# tree, so it is always next to us. Hard source: if it is ever missing, the
# build stops here instead of quietly configuring without the fallback mirror.
# shellcheck source=android/litert-eigen-fetch.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/android/litert-eigen-fetch.sh"

litert_cross_wheel_platform_tag() {
    if command -v cross_wheel_platform_tag >/dev/null 2>&1; then
        cross_wheel_platform_tag
        return $?
    fi
    # Fallback when cross_wheel_platform_tag isn't sourced: reuse the canonical
    # arch->wheel-tag map instead of a private copy. LiteRT only targets
    # amd64/arm64/riscv64, all covered by arch_linux_platform_tag_for.
    if command -v arch_linux_platform_tag_for >/dev/null 2>&1 \
       && command -v cross_target_arch >/dev/null 2>&1; then
        arch_linux_platform_tag_for "$(cross_target_arch)"
        return $?
    fi
    return 1
}

# GCC 16.1.0 ICEs on LiteRT's Samsung vendor code. The ICE is triggered by the
# cross-compiler toolchain used in cross builds; on native amd64 we keep the
# sources and use clang instead (see append_litert_preferred_cmake_compiler_args).
# Replace the vendor sources with a stub CMakeLists so the build proceeds. Track
# the upstream GCC bug and revisit once 16.x is fixed or pinned to an older minor.
_litert_disable_samsung_vendor() {
    local arch="${TARGET_ARCH:-${TARGETARCH:-amd64}}"
    info "Removing Samsung vendor sources to avoid GCC 16.1.0 ICE in cross builds (arch=${arch})"
    rm -rf "${LITERT_SRC}/litert/vendors/samsung" 2>/dev/null || true
    mkdir -p "${LITERT_SRC}/litert/vendors/samsung"
    cat > "${LITERT_SRC}/litert/vendors/samsung/CMakeLists.txt" <<CMAKE_EOF
message(STATUS "Samsung vendor disabled for ${arch}")
CMAKE_EOF
}

# Cross builds only: wire the cross archiver and protect LiteRT's nested host-only
# FlatBuffers/flatc build from the target toolchain env, pointing it at host
# compilers. Appends -DLITERT_HOST_* to the caller's cmake_args array (nameref);
# host_cc/host_cxx are passed by value (wrapping is internal, not needed back).
_litert_configure_cross_host_flatbuffers() {
    local -n _lcf_args="$1"
    local host_cc="$2" host_cxx="$3"

    if command -v append_cmake_cross_archiver_args >/dev/null 2>&1; then
        append_cmake_cross_archiver_args _lcf_args resolve_cross_archive_tool
    fi

    # Do not let the target-side toolchain/cache/linker environment leak into the
    # host probe, or CMake's simple compiler checks can fail.
    unset CC CXX AR AS LD NM RANLIB STRIP OBJCOPY
    unset CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER CMAKE_ASM_COMPILER_LAUNCHER
    unset CMAKE_EXE_LINKER_FLAGS CMAKE_SHARED_LINKER_FLAGS CMAKE_MODULE_LINKER_FLAGS
    unset LDFLAGS
    [ -z "${host_cc}" ]  || host_cc="$(prepare_host_compiler_wrapper "${host_cc}" host-gcc)"
    [ -z "${host_cxx}" ] || host_cxx="$(prepare_host_compiler_wrapper "${host_cxx}" host-g++)"
    info Using host C compiler for flatbuffers: ${host_cc:-unresolved}
    info Using host C++ compiler for flatbuffers: ${host_cxx:-unresolved}
    [ -z "${host_cc}" ]  || _lcf_args+=("-DLITERT_HOST_C_COMPILER=${host_cc}")
    [ -z "${host_cxx}" ] || _lcf_args+=("-DLITERT_HOST_CXX_COMPILER=${host_cxx}")
    info Using cross archive tool: ${cross_ar:-unresolved}
    info Using cross ranlib tool: ${cross_ranlib:-unresolved}
}

configure_litert() {
    info Configuring LiteRT build...

    cd "${LITERT_SRC}/litert"

    local host_cc host_cxx
    host_cc="$(resolve_host_compiler c)"
    host_cxx="$(resolve_host_compiler cxx)"

    local preset="default"
    [ "${BUILD_TYPE}" = "Debug" ] && preset="default-debug"
    info Using preset: ${preset}

    # Enable ruy but keep its profiler/instrumentation disabled to avoid linking
    # against ruy_profiler_instrumentation (absent in some build environments /
    # submodule combinations): RUY_PROFILER=0 disables the profiler, ruy stays on.
    local cmake_args=(
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
        "-DRUY_PROFILER=0"
        "-DRUY_ENABLE_INSTRUMENTATION=OFF"
        "-DRUY_PROFILER_INSTRUMENTATION=OFF"
        "-DRUY_BUILD_TOOLS=OFF"
        "-DRUY_BUILD_TESTING=OFF"
        "-DCMAKE_INSTALL_PREFIX=${LITERT_PREFIX}"
        "-DCMAKE_INSTALL_LIBDIR=lib"
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
        "-DLITERT_AUTO_BUILD_TFLITE=ON"
        "-DLITERT_ENABLE_GPU=OFF"
        "-DLITERT_ENABLE_NPU=OFF"
        "-DTFLITE_ENABLE_XNNPACK=ON"
        "-DTFLITE_ENABLE_RUY=ON"
        "-DPython3_EXECUTABLE=${HOST_PYTHON_BIN}"
    )

    # EIGEN-NET: mirrored eigen fetch (this path still git-cloned it from gitlab).
    cmake_args+=("${LITERT_EIGEN_FETCH_FLAGS[@]}")

    append_litert_preferred_cmake_compiler_args cmake_args
    if command -v append_cmake_cross_args >/dev/null 2>&1; then
        append_cmake_cross_args cmake_args
    fi

    # Only cross builds hit the GCC 16.1.0 ICE; native amd64 keeps the Samsung
    # vendor sources and builds them with clang (see comment above
    # _litert_disable_samsung_vendor). Gating on `command -v cross_target_arch`
    # was always true after media_common_init, stubbing native builds too.
    if cross_build_is_active; then
        _litert_disable_samsung_vendor
    fi

    if cross_build_is_active; then
        _litert_configure_cross_host_flatbuffers cmake_args "${host_cc}" "${host_cxx}"
    fi

    append_litert_cache_linker_args cmake_args

    info LiteRT CMake args: ${cmake_args[*]}
    cmake --preset "${preset}" "${cmake_args[@]}"
}

# Single source of truth for the CMake build subdirectory name, which encodes
# the Debug/Release convention. Used bare (relative to litert/) and joined onto
# ${LITERT_SRC}/litert/ by the install paths below.
litert_build_subdir() {
    [ "${BUILD_TYPE}" = "Debug" ] && printf 'cmake_build_debug' || printf 'cmake_build'
}

build_litert() {
    info Building LiteRT with ${NPROC} parallel jobs...

    cd "${LITERT_SRC}/litert"
    run_cmake_build_with_fallback "$(litert_build_subdir)" "${NPROC}"
}

# The C API CMakeLists expects TF_SOURCE_DIR to contain tensorflow/lite, but
# LiteRT lays out sources under tflite/. Create the compatibility symlink.
_tflite_c_prepare_symlink() {
    info Creating tensorflow/lite symlink for C API build compatibility...
    mkdir -p "${LITERT_SRC}/tensorflow"
    ln -snf "${LITERT_SRC}/tflite" "${LITERT_SRC}/tensorflow/lite"
}

# Assemble the TFLite C API CMake args into the caller's array (nameref),
# including cross compiler/archiver args and the host flatc tools dir.
_tflite_c_cmake_args() {
    local -n _tca_args="$1"
    _tca_args=(
        "-DCMAKE_BUILD_TYPE=${BUILD_TYPE}"
        "-DCMAKE_INSTALL_PREFIX=${LITERT_PREFIX}"
        "-DCMAKE_INSTALL_LIBDIR=lib"
        "-DTFLITE_C_BUILD_SHARED_LIBS=ON"
        "-DTF_SOURCE_DIR=${LITERT_SRC}"
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    )

    # EIGEN-NET: the TO_URL knob used to live inline here; it now ships with its
    # mirror fallback.
    _tca_args+=("${LITERT_EIGEN_FETCH_FLAGS[@]}")

    append_litert_preferred_cmake_compiler_args _tca_args
    if command -v append_cmake_cross_args >/dev/null 2>&1; then
        append_cmake_cross_args _tca_args
    fi

    if cross_build_is_active; then
        local tflite_host_tools_dir
        tflite_host_tools_dir="$(resolve_litert_tflite_host_tools_dir || true)"
        if command -v append_cmake_cross_archiver_args >/dev/null 2>&1; then
            append_cmake_cross_archiver_args _tca_args resolve_cross_archive_tool
        fi
        if [ -z "${tflite_host_tools_dir}" ]; then
            err Could not resolve TFLite host tools directory containing flatc for cross build
        fi
        _tca_args+=("-DTFLITE_HOST_TOOLS_DIR=${tflite_host_tools_dir}")
        info Using TFLite host tools dir: ${tflite_host_tools_dir}
    fi

    append_litert_cache_linker_args _tca_args
}

# Install the C API (with a manual .so copy fallback — some LiteRT revisions omit
# the install rule) and verify libtensorflowlite_c.so exists. Runs in the build
# dir (cwd), passed as $1 for the diagnostic paths.
_tflite_c_install_and_verify() {
    local c_api_build="$1"
    info Installing TFLite C API...
    mkdir -p "${LITERT_PREFIX}/lib"
    if ! cmake --install .; then
        warn TFLite C API cmake install failed; falling back to manual library copy...
    fi
    find . -name "libtensorflowlite_c*.so*" -exec cp -av {} "${LITERT_PREFIX}/lib/" \; 2>/dev/null || true

    if [ -f "${LITERT_PREFIX}/lib/libtensorflowlite_c.so" ] || \
       ls "${c_api_build}"/libtensorflowlite_c*.so* 2>/dev/null; then
        info TFLite C API build complete - libtensorflowlite_c.so available
    else
        warn libtensorflowlite_c.so not found after build!
        info Checking build directory for any .so files:
        find "${c_api_build}" -name "*.so*" -ls 2>/dev/null || echo "No .so files found"
    fi
}

build_tflite_c_api() {
    info Building TensorFlow Lite C API library...

    local c_api_src="${LITERT_SRC}/tflite/c"
    if [ ! -d "${c_api_src}" ]; then
        warn TFLite C API source not found at ${c_api_src}; skipping C API build
        return 0
    fi

    _tflite_c_prepare_symlink

    local c_api_build="${LITERT_SRC}/tflite_c_build"
    mkdir -p "${c_api_build}"
    cd "${c_api_build}"

    local cmake_args=()
    _tflite_c_cmake_args cmake_args

    info Configuring TFLite C API...
    info C API source: ${c_api_src}
    info TF_SOURCE_DIR: ${LITERT_SRC}
    info Expected tensorflow/lite at: ${LITERT_SRC}/tensorflow/lite
    info TFLite C API CMake args: ${cmake_args[*]}
    ls -la "${LITERT_SRC}/tensorflow/lite" 2>/dev/null || warn tensorflow/lite symlink may not exist

    if ! cmake "${c_api_src}" "${cmake_args[@]}"; then
        err TFLite C API cmake configure failed!
        err This is required for GStreamer tflite plugin support.
        err Check the cmake output above for details.
    fi

    info Building TFLite C API...
    run_cmake_build_with_fallback . "${NPROC}" || err "TFLite C API build failed!"

    _tflite_c_install_and_verify "${c_api_build}"
}

install_litert() {
    info Installing LiteRT to ${LITERT_PREFIX}...

    local build_dir="${LITERT_SRC}/litert/$(litert_build_subdir)"

    cd "${LITERT_SRC}/litert"

    if ! cmake --build "${build_dir}" --target install; then
      warn "cmake --target install failed; using manual copy only"
    fi

    install_manual

    ldconfig || true

    mkdir -p "${LITERT_PREFIX}/wheels"

    _litert_build_wheel
}

_litert_wheel_prepare_env() {
    if cross_build_is_active; then
        cross_wheel_build=true
        if command -v cross_target_python_dev_ready >/dev/null 2>&1 && ! cross_target_python_dev_ready; then
            warn Target Python development files are unavailable; skipping LiteRT Python wheel build in cross mode
            return 1
        fi
        info Attempting LiteRT Python wheel build in cross mode for $(cross_target_arch)
    fi

    pip_pkg_dir="${LITERT_SRC}/tflite/tools/pip_package"
    if [ ! -d "${pip_pkg_dir}" ]; then
        info "No Python packaging detected for LiteRT at ${pip_pkg_dir}; skipping wheel build"
        return 1
    fi

    info Detected Python packaging in LiteRT source - attempting to build wheel
    pushd "${pip_pkg_dir}" > /dev/null

    export PYTHON="${HOST_PYTHON_BIN}"
    if [ -z "${PYTHON}" ]; then
        warn No python found in PATH to build LiteRT wheel
        popd > /dev/null
        return 1
    fi

    info Building wheel via build_pip_package_with_cmake.sh...
    export TENSORFLOW_DIR="${LITERT_SRC}"
    export TENSORFLOW_LITE_DIR="${LITERT_SRC}/tflite"
    export TENSORFLOW_TARGET="native"
    export TENSORFLOW_VERSION="${LITERT_VERSION#v}"

    mkdir -p "${LITERT_SRC}/tensorflow"
    ln -snf "${LITERT_SRC}/tflite" "${LITERT_SRC}/tensorflow/lite"

    # Build base cmake flags early so EXTRA_CMAKE_FLAGS can be exported
    # before the patch is applied (the patch script reads this env var).
    extra_cmake_flags="-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DRUY_PROFILER=0 -DRUY_ENABLE_INSTRUMENTATION=OFF -DRUY_PROFILER_INSTRUMENTATION=OFF -DRUY_BUILD_TOOLS=OFF -DRUY_BUILD_TESTING=OFF -DLITERT_AUTO_BUILD_TFLITE=ON -DLITERT_ENABLE_GPU=OFF -DLITERT_ENABLE_NPU=OFF -DTFLITE_ENABLE_RUY=ON -DPython3_EXECUTABLE=${PYTHON}"
    # EIGEN-NET: same mirrored eigen fetch as the configure paths above. The
    # patched upstream build_pip_package_with_cmake.sh word-splits this string
    # (`cmake ${EXTRA_CMAKE_FLAGS:-}`), so the flags must stay space-free.
    extra_cmake_flags+=" $(litert_eigen_fetch_flags_str)"
    export EXTRA_CMAKE_FLAGS="${extra_cmake_flags}"

    # Patch upstream build_pip_package_with_cmake.sh so it honours the env vars
    # we export (TENSORFLOW_DIR, TENSORFLOW_VERSION, EXTRA_CMAKE_FLAGS) and
    # replaces -march=native with a cross-safe include path. apply-patch.sh is
    # idempotent, so re-runs are safe.
    bash /opt/scripts/core/apply-patch.sh \
        /opt/scripts/patches/litert/001-env-var-overrides.patch \
        "${pip_pkg_dir}" \
        "LiteRT build_pip_package_with_cmake.sh env var overrides"
    _fixed="${pip_pkg_dir}/build_pip_package_with_cmake.sh"
}

_litert_wheel_native_args() {
    export WHEEL_PROJECT_NAME="ai_edge_litert"

    append_litert_preferred_cmake_compiler_args native_compiler_args
    if [ "${#native_compiler_args[@]}" -gt 0 ]; then
        extra_cmake_flags+=" ${native_compiler_args[*]}"
    fi
}

_litert_wheel_cross_args() {
    local wheel_cross_args=()

    python_major_minor="${python_major_minor:-$(host_python_major_minor 2>/dev/null || true)}"

    if command -v append_cmake_cross_args >/dev/null 2>&1; then
        append_cmake_cross_args wheel_cross_args
    fi
    if command -v append_cmake_cross_archiver_args >/dev/null 2>&1; then
        append_cmake_cross_archiver_args wheel_cross_args resolve_cross_archive_tool
    fi
    tflite_host_tools_dir="$(resolve_litert_tflite_host_tools_dir || true)"
    if [ -z "${tflite_host_tools_dir}" ]; then
        err Could not resolve TFLite host tools directory containing flatc for cross wheel build
    fi
    wheel_platform_name="$(litert_cross_wheel_platform_tag || true)"
    if [ -z "${wheel_platform_name}" ]; then
        err Could not resolve wheel platform tag for target architecture $(cross_target_arch)
    fi
    if [ -n "${python_major_minor}" ] && command -v cross_target_python_include_dir >/dev/null 2>&1; then
        target_python_include="$(cross_target_python_include_dir 2>/dev/null || true)"
        target_python_arch_include="$(cross_target_python_arch_include_dir 2>/dev/null || true)"
        if [ ! -d "${target_python_include}" ] || [ ! -d "${target_python_arch_include}" ]; then
            target_python_include=""
            target_python_arch_include=""
        fi
    fi

    extra_cmake_flags+=" ${wheel_cross_args[*]}"
    extra_cmake_flags+=" -DTFLITE_HOST_TOOLS_DIR=${tflite_host_tools_dir}"
    if [ -n "${target_python_include}" ]; then
        extra_cmake_flags+=" -DPYTHON_INCLUDE_DIR=${target_python_include}"
        extra_cmake_flags+=" -DPYTHON_INCLUDE_PATH=${target_python_include}"
        info Cross wheel target Python include dir: ${target_python_include}
        info Cross wheel target Python arch include dir: ${target_python_arch_include}
    fi

    export EXTRA_CMAKE_FLAGS="${extra_cmake_flags}"
    export TENSORFLOW_TARGET="native"
    export WHEEL_PLATFORM_NAME="${wheel_platform_name}"
    # Only emit -I flags for include dirs that actually resolved. The former
    # unconditional "-I${PYTHON_INCLUDE} -I${PYBIND11_INCLUDE} -I${NUMPY_INCLUDE}"
    # expanded to bare "-I -I -I" (those vars are never set in cross mode), which
    # corrupted the compiler command line and made Abseil's ABSL_INTERNAL_AT_LEAST_CXX17
    # probe fail -> "must use the same C++ standard" configure error. Feed the
    # resolved target Python include dirs (base + arch) so the pywrap extension
    # finds Python.h/pyconfig.h during cross compilation.
    local litert_build_flags="-idirafter /usr/include"
    [ -n "${TF_CXX_FLAGS:-}" ] && litert_build_flags+=" ${TF_CXX_FLAGS}"
    [ -n "${target_python_include:-}" ] && litert_build_flags+=" -I${target_python_include}"
    [ -n "${target_python_arch_include:-}" ] && litert_build_flags+=" -I${target_python_arch_include}"
    # The pywrap extension #includes "pybind11/functional.h" and
    # "numpy/arrayobject.h". Both ship arch-independent C-API headers in the build
    # venv (see install-deps.sh), so the host interpreter's include dirs are correct
    # even for a cross target (only the target Python.h above must be arch-specific).
    local _pybind11_inc="" _numpy_inc=""
    if [ -n "${PYTHON:-}" ]; then
        _pybind11_inc="$(python_module_include "${PYTHON}" pybind11)"
        _numpy_inc="$(python_module_include "${PYTHON}" numpy)"
    fi
    [ -n "${_pybind11_inc}" ] && litert_build_flags+=" -I${_pybind11_inc}"
    [ -n "${_numpy_inc}" ] && litert_build_flags+=" -I${_numpy_inc}"
    export BUILD_FLAGS="${litert_build_flags}"
    info Building LiteRT wheel in cross mode for $(cross_target_arch)
    info Cross wheel platform tag: ${WHEEL_PLATFORM_NAME}
    info Cross wheel host tools dir: ${tflite_host_tools_dir}
}

_litert_wheel_native_finalize() {
    export TENSORFLOW_TARGET="native"
    unset WHEEL_PLATFORM_NAME || true
    export EXTRA_CMAKE_FLAGS="${extra_cmake_flags}"
}

_litert_wheel_run() {
    export CMAKE_POLICY_VERSION_MINIMUM=3.5

    bash "${_fixed}" "${TENSORFLOW_TARGET}" > pip_build.log 2>&1 || {
        warn pip wheel failed for LiteRT source. Last 1000 lines of log:
        tail -n 1000 pip_build.log
        if [ "${cross_wheel_build}" = "true" ]; then
            warn Continuing without a local LiteRT wheel for the cross build
            popd > /dev/null
            return 0
        fi
        exit 1
    }

    info pip wheel success! Last 50 lines of log:
    tail -n 50 pip_build.log

    find "gen/tflite_pip" -name "*.whl" -type f -exec cp -v {} "${LITERT_PREFIX}/wheels/" \; 2>/dev/null || warn No wheels found after build script
    _litert_fix_pywrap_ext_name
    popd > /dev/null
}

# LiteRT v2.1.6's pip build ships the interpreter pybind extension FILE named
# `_pywrap_tensorflow_interpreter_wrapper*.so`, but its PyInit_ symbol — and every
# importer (tflite_runtime/interpreter.py imports `_pywrap_litert_interpreter_wrapper`)
# — uses the litert name. So `import _pywrap_litert_interpreter_wrapper` can't find
# the file and ai-edge-litert import dies with "cannot import name
# '_pywrap_litert_interpreter_wrapper' from 'tflite_runtime'". The binary is already
# the litert module (importing it under the tensorflow name fails with a missing
# PyInit_ symbol), so the fix is purely to rename the FILE to match its symbol.
# Post-process each staged wheel: unpack, rename the ext, repack (which recomputes
# RECORD). Best-effort — a repack failure leaves the original wheel untouched.
_litert_fix_pywrap_ext_name() {
    local py="${PYTHON:-python3}" wheel tmp unpacked tf_so _renamed
    command -v "${py}" >/dev/null 2>&1 || return 0
    for wheel in "${LITERT_PREFIX}/wheels/"ai_edge_litert-*.whl; do
        [ -f "${wheel}" ] || continue
        tmp="$(mktemp -d)"
        if ! "${py}" -m wheel unpack "${wheel}" -d "${tmp}" >/dev/null 2>&1; then
            rm -rf "${tmp}"; continue
        fi
        _renamed=""
        while IFS= read -r tf_so; do
            [ -n "${tf_so}" ] || continue
            mv "${tf_so}" "${tf_so/_pywrap_tensorflow_/_pywrap_litert_}" && _renamed=1
        done < <(find "${tmp}" -name '_pywrap_tensorflow_interpreter_wrapper*.so')
        if [ -n "${_renamed}" ]; then
            unpacked="$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -1)"
            if "${py}" -m wheel pack "${unpacked}" -d "${LITERT_PREFIX}/wheels/" >/dev/null 2>&1; then
                info "Renamed misnamed LiteRT pywrap ext to _pywrap_litert_interpreter_wrapper in $(basename "${wheel}")"
            else
                warn "Failed to repack LiteRT wheel after pywrap rename: $(basename "${wheel}")"
            fi
        fi
        rm -rf "${tmp}"
    done
}

_litert_build_wheel() {
    local cross_wheel_build=false
    local pip_pkg_dir=""
    local extra_cmake_flags=""
    local _fixed=""
    local native_compiler_args=()
    local wheel_platform_name=""
    local tflite_host_tools_dir=""
    local python_major_minor="${PYTHON_MAJOR_MINOR:-}"
    local target_python_include=""
    local target_python_arch_include=""

    _litert_wheel_prepare_env || return 0
    _litert_wheel_native_args
    if cross_build_is_active; then
        _litert_wheel_cross_args
    else
        _litert_wheel_native_finalize
    fi
    _litert_wheel_run
}

# Copy .so/.a libraries and create the libLiteRt -> libtensorflow-lite
# compatibility symlinks GStreamer expects.
_install_manual_libs_and_symlinks() {
    local build_dir="$1" lib_dir="$2"

    info Copying shared libraries...
    find "${build_dir}" -name "*.so*" -exec cp -v {} "${lib_dir}/" \; 2>/dev/null || true

    info Copying static libraries...
    find "${build_dir}" -name "*.a" -exec cp -v {} "${lib_dir}/" \; 2>/dev/null || true

    # Create symlinks for tensorflow-lite compatibility
    # LiteRT builds libLiteRt.so, but GStreamer expects libtensorflow-lite.so
    # Handle both versioned and unversioned libraries
    for lib in "${lib_dir}"/libLiteRt.so*; do
        [ -f "${lib}" ] || continue
        libname=$(basename "${lib}")
        tfname="${libname/libLiteRt/libtensorflow-lite}"
        ln -sf "${libname}" "${lib_dir}/${tfname}"
        info Created symlink: ${tfname} -> ${libname}
    done
}

# Copy C++ and C API headers: tensorflow/lite source layout OR litert layout,
# plus the tflite/ compatibility dir, the litert/c dir, and the
# tensorflow/lite -> tflite symlink libcamera and other consumers expect.
_install_manual_headers() {
    local src_dir="$1" include_dir="$2"

    info "Copying headers (C++ and C API)..."
    cd "${src_dir}"

    # 1. Copy ALL headers (C and C++) preserving the directory structure.
    # cpio needs --null to match find's -print0; without it cpio treats the whole
    # NUL-delimited stream as one bogus path and copies only the first header.
    if [ -d "tensorflow/lite" ]; then
        info Found tensorflow/lite source layout...
        find tensorflow/lite -type f \( -name "*.h" -o -name "*.hpp" \) -print0 | cpio -pdm --null "${include_dir}/"
    elif [ -d "litert" ]; then
        info Found litert source layout...
        find litert -type f \( -name "*.h" -o -name "*.hpp" \) -print0 | cpio -pdm --null "${include_dir}/"
    fi

    # 2. Copy tflite directory (contains TensorFlow Lite C++ compatibility headers)
    # This is CRITICAL for libcamera's awb_nn.cpp which needs tensorflow/lite/interpreter.h
    info Copying tflite C++ compatibility headers...
    if [ -d "tflite" ]; then
        cp -rv "tflite" "${include_dir}/" 2>/dev/null || true
        info tflite headers copied to ${include_dir}/tflite
    fi

    # 3. Copy litert/c headers for C API compatibility
    info Ensuring strict C API compatibility...
    if [ -d "litert/c" ]; then
        cp -rv "litert/c" "${include_dir}/"
    else
        warn "litert/c headers not found in source tree; C API consumers may miss headers"
    fi

    # 4. Create tensorflow/lite -> tflite symlink for compatibility
    # libcamera and other projects expect headers at <tensorflow/lite/interpreter.h>
    # but LiteRT provides them at <tflite/interpreter.h>
    # NOTE: Since this is a symlink, tensorflow/lite/c will automatically resolve
    # to tflite/c which should already have the C API headers from the tflite copy
    info Creating tensorflow/lite compat symlink...
    mkdir -p "${include_dir}/tensorflow"
    ln -sfn "../tflite" "${include_dir}/tensorflow/lite"
    info Created tensorflow/lite compatibility symlink

    # Verify the symlink works for the critical header
    if [ -f "${include_dir}/tensorflow/lite/interpreter.h" ]; then
        info Verified: tensorflow/lite/interpreter.h is accessible
    else
        warn tensorflow/lite/interpreter.h is NOT accessible via symlink!
        info Contents of ${include_dir}/tflite:
        ls -la "${include_dir}/tflite" 2>/dev/null || echo "  (directory not found)"
    fi
}

# Copy FlatBuffers headers. CMake builds may place them in different locations
# depending on the subproject naming; check common locations and fall back to
# a search for the flatbuffers.h file.
_install_manual_flatbuffers() {
    local build_dir="$1" include_dir="$2"

    # 5. Flatbuffers (Required by the C++ API)
    fb_found=0
    local _fbsrc
    for _fbsrc in "_deps/flatbuffers-src/include" "flatbuffers-flatc/include"; do
        if [ -d "${build_dir}/${_fbsrc}" ]; then
            info "Copying flatbuffers headers from ${_fbsrc}..."
            cp -rv "${build_dir}/${_fbsrc}"/* "${include_dir}/" 2>/dev/null || true
            fb_found=1
        fi
    done
    # Also check for an installed location within the build tree
    if [ -d "${build_dir}/flatbuffers-flatc/include/flatbuffers" ]; then
        info Copying flatbuffers headers from flatbuffers-flatc/include/flatbuffers...
        mkdir -p "${include_dir}/flatbuffers" || true
        cp -rv "${build_dir}/flatbuffers-flatc/include/flatbuffers"/* "${include_dir}/flatbuffers/" 2>/dev/null || true
        fb_found=1
    fi
    # Final fallback: search for the flatbuffers.h file and copy its directory
    if [ "$fb_found" -eq 0 ]; then
        local fbheader fbdir
        fbheader=$(find "${LITERT_SRC}/litert" -type f -path "*/flatbuffers/flatbuffers.h" -print -quit 2>/dev/null || true)
        if [ -n "$fbheader" ]; then
            fbdir=$(dirname "$fbheader")
            info "Found flatbuffers header at $fbheader; copying from $fbdir..."
            mkdir -p "${include_dir}/flatbuffers" || true
            cp -rv "$fbdir"/* "${include_dir}/flatbuffers/" 2>/dev/null || true
            fb_found=1
        fi
    fi
    if [ "$fb_found" -eq 0 ]; then
        warn "FlatBuffers headers not found in expected build locations; some targets may fail to compile"
    fi
}

# Install Abseil (absl) headers transitively required by the tflite C++ headers
# (tflite/util.h does `#include "absl/types/span.h"`). Canonical implementation
# lives in 01-core/abseil-headers.sh (Critical Fix #2). The helper is idempotent
# and skips if span.h is already present.
_install_manual_abseil() {
    local include_dir="$1"
    if ! install_abseil_headers "${include_dir}"; then
        warn "Abseil headers not found; tflite-consuming targets (e.g. libcamera awb_nn) may fail to compile"
        if [ -f "${include_dir}/absl/types/span.h" ]; then
            info "Verified: absl/types/span.h is accessible"
        fi
    else
        info "Verified: absl/types/span.h is accessible"
    fi
}

# Generate the litert.pc, tensorflow-lite.pc and tensorflowlite_c.pc files.
_install_manual_pkgconfig() {
    local lib_dir="$1"

    mkdir -p "${lib_dir}/pkgconfig"

    local static_libs=""
    for lib in "${lib_dir}"/*.a; do
        [ -f "${lib}" ] || continue
        libname=$(basename "${lib}" .a)
        static_libs="${static_libs} -l${libname}"
    done

    generate_pkgconfig_file "${lib_dir}/pkgconfig/litert.pc" \
      "LiteRT" "Google LiteRT Runtime Library" \
      "${LITERT_VERSION}" "${LITERT_PREFIX}" \
      "-L\${libdir} -lLiteRt -ltensorflow-lite" \
      "-I\${includedir}"

    # Libs.private passed as the 9th arg (requires left empty) so the helper
    # emits the `Libs.private:` line — no post-hoc `cat >>` append needed.
    generate_pkgconfig_file "${lib_dir}/pkgconfig/tensorflow-lite.pc" \
      "TensorFlow Lite" "TensorFlow Lite Library (via LiteRT)" \
      "${LITERT_VERSION}" "${LITERT_PREFIX}" \
      "-L\${libdir} -ltensorflow-lite" \
      "-I\${includedir}" \
      "" \
      "${static_libs} -lpthread -ldl"

    generate_pkgconfig_file "${lib_dir}/pkgconfig/tensorflowlite_c.pc" \
      "TensorFlow Lite C API" "TensorFlow Lite C API Library (via LiteRT)" \
      "${LITERT_VERSION}" "${LITERT_PREFIX}" \
      "-L\${libdir} -ltensorflowlite_c" \
      "-I\${includedir}" \
      "" \
      "-lpthread -ldl"
}

install_manual() {
    local build_dir="${LITERT_SRC}/litert/$(litert_build_subdir)"

    local lib_dir="${LITERT_PREFIX}/lib"
    local include_dir="${LITERT_PREFIX}/include"

    mkdir -p "${lib_dir}"
    mkdir -p "${include_dir}"

    _install_manual_libs_and_symlinks "${build_dir}" "${lib_dir}"
    _install_manual_headers "${LITERT_SRC}" "${include_dir}"
    _install_manual_flatbuffers "${build_dir}" "${include_dir}"
    _install_manual_abseil "${include_dir}"
    _install_manual_pkgconfig "${lib_dir}"
}

verify_installation() {
    info Verifying LiteRT installation...

    local found_libs=false
    if ls "${LITERT_PREFIX}/lib"/*[Ll]ite[Rr]t* 2>/dev/null; then
        found_libs=true
    fi
    if ls "${LITERT_PREFIX}/lib"/*tensorflow* 2>/dev/null; then
        found_libs=true
    fi

    if [ "${found_libs}" = "false" ]; then
        warn No LiteRT/TensorFlow Lite libraries found in ${LITERT_PREFIX}/lib
        ls -la "${LITERT_PREFIX}/lib" 2>/dev/null || true
        return 1
    fi

    if [ -f "${LITERT_PREFIX}/lib/pkgconfig/litert.pc" ]; then
        info LiteRT pkg-config:
        cat "${LITERT_PREFIX}/lib/pkgconfig/litert.pc"
    fi

    if [ -f "${LITERT_PREFIX}/lib/pkgconfig/tensorflow-lite.pc" ]; then
        info TensorFlow Lite pkg-config:
        cat "${LITERT_PREFIX}/lib/pkgconfig/tensorflow-lite.pc"
    fi

    info LiteRT ${LITERT_VERSION} installed successfully
}

cleanup() {
    if [ "${KEEP_SOURCES:-0}" = "1" ]; then
        info "KEEP_SOURCES=1, skipping cleanup of ${LITERT_SRC}"
        return 0
    fi
    info Cleaning up...
    rm -rf "${LITERT_SRC}" || true
}

main() {
    if [ -d "${LITERT_PREFIX}/lib" ] && [ -f "${LITERT_PREFIX}/include/tflite/interpreter.h" ]; then
        if [ "${FORCE_REBUILD:-0}" != "1" ]; then
            info "LiteRT already installed at ${LITERT_PREFIX} (set FORCE_REBUILD=1 to force)"
            return 0
        fi
    fi

    info LiteRT build started
    fetch_litert
    configure_litert
    build_litert
    build_tflite_c_api
    install_litert
    # AP4: strip ONLY litert's own libs (it installs into the shared
    # ${LITERT_PREFIX}/lib = /usr/local/lib, next to the base CPython libs, so a
    # whole-prefix strip would wrongly hit libpython etc.). strip_media_libs
    # self-derives the cross <triplet>-strip (this script does not export STRIP);
    # --strip-all keeps .dynsym. Best-effort, MEDIA_STRIP=0 disables. Runs BEFORE
    # verify_installation so the verify exercises the stripped libs.
    # DUPN1: MEDIA_STRIP gate lives inside the helper now.
    declare -F strip_media_libs >/dev/null 2>&1 \
        && strip_media_libs "${LITERT_PREFIX}/lib" \
            'libtensorflow-lite*.so*' 'libtensorflowlite_c*.so*' 'libtflite*.so*' || true
    verify_installation
    cleanup
    info LiteRT build complete
}

main "$@"
