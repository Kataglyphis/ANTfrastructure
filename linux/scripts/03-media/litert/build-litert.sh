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

# Source shared modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for helper in \
    "/opt/scripts/core/modules.sh" \
    "${SCRIPT_DIR}/../../01-core/modules.sh"; do
    if [ -f "${helper}" ]; then
        # shellcheck disable=SC1090
        source "${helper}"
        source_modules_framework "${SCRIPT_DIR}"
        break
    fi
done

source_module cross-env.sh || true
source_module logging.sh || true
source_module parallelism.sh || true
source_module compiler-cache.sh && { setup_ccache; setup_lld_linker; } || true
source_module compiler-resolution.sh || true

LITERT_VERSION="${LITERT_VERSION:-${1:-v2.1.5}}"
: "${LITERT_SRC:=${TMPDIR:-/tmp}/litert-$$}"
: "${LITERT_PREFIX:=/usr/local}"
: "${BUILD_TYPE:=Release}"
: "${NPROC:=$(compute_jobs_with_mem_cap "" 2000)}"
: "${SKIP_DEP_INSTALL:=false}"

HOST_PYTHON="$(host_python_bin)"
HOST_PYTHON_MM="$(host_python_major_minor 2>/dev/null || true)"
if [ -n "${HOST_PYTHON_MM}" ] && [ -z "${PYTHON_MAJOR_MINOR:-}" ]; then
    export PYTHON_MAJOR_MINOR="${HOST_PYTHON_MM}"
fi
export PYTHON_EXECUTABLE="${HOST_PYTHON}" \
       Python_EXECUTABLE="${HOST_PYTHON}" \
       Python3_EXECUTABLE="${HOST_PYTHON}"

info Building LiteRT ${LITERT_VERSION}
info Using JOBS=${NPROC}
info Install prefix: ${LITERT_PREFIX}

fetch_litert() {
    info Fetching LiteRT ${LITERT_VERSION} source...
    clone_or_update_repo "https://github.com/google-ai-edge/LiteRT.git" "${LITERT_SRC}" "${LITERT_VERSION}"
    cd "${LITERT_SRC}"
    info LiteRT version: $(git describe --tags 2>/dev/null || echo 'unknown')
}

resolve_host_compiler() {
    local lang="$1"
    if command -v resolve_host_compiler_for_lang >/dev/null 2>&1; then
        resolve_host_compiler_for_lang "${lang}"
        return $?
    fi

    local triplet=""
    local resolved=""

    if command -v resolve_build_gcc_tool >/dev/null 2>&1; then
        case "${lang}" in
            c)
                resolved="$(resolve_build_gcc_tool gcc 2>/dev/null || true)"
                [ -n "${resolved}" ] || resolved="$(resolve_build_gcc_tool cc 2>/dev/null || true)"
                ;;
            cxx)
                resolved="$(resolve_build_gcc_tool g++ 2>/dev/null || true)"
                [ -n "${resolved}" ] || resolved="$(resolve_build_gcc_tool c++ 2>/dev/null || true)"
                ;;
        esac
        [ -n "${resolved}" ] && { printf '%s' "${resolved}"; return 0; }
    fi

    if command -v build_deb_multiarch_triplet >/dev/null 2>&1; then
        triplet="$(build_deb_multiarch_triplet)"
    fi

    case "${lang}" in
        c)
            for candidate in \
                "/usr/bin/${triplet}-gcc" \
                /usr/bin/clang \
                /usr/bin/gcc \
                /usr/bin/cc; do
                [ -x "${candidate}" ] && { printf '%s' "${candidate}"; return 0; }
            done
            command -v gcc 2>/dev/null || command -v cc 2>/dev/null || true
            ;;
        cxx)
            for candidate in \
                "/usr/bin/${triplet}-g++" \
                /usr/bin/clang++ \
                /usr/bin/g++ \
                /usr/bin/c++; do
                [ -x "${candidate}" ] && { printf '%s' "${candidate}"; return 0; }
            done
            command -v g++ 2>/dev/null || command -v c++ 2>/dev/null || true
            ;;
        *)
            return 1
            ;;
    esac
}

prepare_host_compiler_wrapper() {
    local compiler="$1"
    local wrapper_name="${2:-host-gcc}"
    local wrapper_dir; wrapper_dir="$(mktemp -d "${TMPDIR:-/tmp}/litert-host-toolchain.XXXXXX")"
    make_named_host_compiler_wrapper "${wrapper_dir}" "${wrapper_name}" "${compiler}"
}

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
  local -n _alcla_args=$1

  if command -v ld.lld >/dev/null 2>&1 && [ "${USE_LLD:-true}" != "false" ]; then
    _alcla_args+=("-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld")
    _alcla_args+=("-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld")
    _alcla_args+=("-DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld")
    info Using lld linker for faster linking
  fi

  if command -v ccache >/dev/null 2>&1 && [ "${USE_CCACHE:-true}" != "false" ]; then
    if [ -z "${CMAKE_C_COMPILER_LAUNCHER:-}" ]; then
      _alcla_args+=("-DCMAKE_C_COMPILER_LAUNCHER=ccache")
      _alcla_args+=("-DCMAKE_CXX_COMPILER_LAUNCHER=ccache")
      _alcla_args+=("-DCMAKE_ASM_COMPILER_LAUNCHER=")
      info "Using ccache for faster compilation (C/C++ only, not ASM)"
    else
      info ccache already configured via environment
      _alcla_args+=("-DCMAKE_ASM_COMPILER_LAUNCHER=")
    fi
  fi
}

litert_cross_wheel_platform_tag() {
    if command -v cross_wheel_platform_tag >/dev/null 2>&1; then
        cross_wheel_platform_tag
        return $?
    fi
    if ! command -v cross_target_arch >/dev/null 2>&1; then
        return 1
    fi

    case "$(cross_target_arch)" in
        amd64) printf '%s' "linux_x86_64" ;;
        arm64) printf '%s' "linux_aarch64" ;;
        armhf) printf '%s' "linux_armv7l" ;;
        riscv64) printf '%s' "linux_riscv64" ;;
        *) return 1 ;;
    esac
}

configure_litert() {
    info Configuring LiteRT build...

    cd "${LITERT_SRC}/litert"

    local host_cc=""
    local host_cxx=""

    host_cc="$(resolve_host_compiler c)"
    host_cxx="$(resolve_host_compiler cxx)"

    local preset="default"
    if [ "${BUILD_TYPE}" = "Debug" ]; then
        preset="default-debug"
    fi

    info Using preset: ${preset}

    # Build CMake arguments array
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
        "-DPython3_EXECUTABLE=${HOST_PYTHON}"
    )

    append_litert_preferred_cmake_compiler_args cmake_args

    if command -v append_cmake_cross_args >/dev/null 2>&1; then
        append_cmake_cross_args cmake_args
    fi

    if cross_build_is_active && \
       command -v cross_target_arch >/dev/null 2>&1; then
        local cross_arch=""
        cross_arch="$(cross_target_arch)"
        if [ "${cross_arch}" = "arm64" ] || [ "${cross_arch}" = "riscv64" ]; then
            info Removing Samsung vendor sources to avoid GCC 16.1.0 ICE on ${cross_arch} cross
            rm -rf "${LITERT_SRC}/litert/vendors/samsung" 2>/dev/null || true
            mkdir -p "${LITERT_SRC}/litert/vendors/samsung"
            cat > "${LITERT_SRC}/litert/vendors/samsung/CMakeLists.txt" <<CMAKE_EOF
message(STATUS "Samsung vendor disabled for ${cross_arch} cross build")
CMAKE_EOF
        fi
    fi

    if cross_build_is_active; then
        if command -v append_cmake_cross_archiver_args >/dev/null 2>&1; then
            append_cmake_cross_archiver_args cmake_args resolve_cross_archive_tool
        fi

        # LiteRT configures a nested host-only FlatBuffers build for flatc.
        # Do not let the target-side toolchain/cache/linker environment leak into
        # that host probe, or CMake's simple compiler checks can fail.
        unset CC CXX AR AS LD NM RANLIB STRIP OBJCOPY
        unset CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER CMAKE_ASM_COMPILER_LAUNCHER
        unset CMAKE_EXE_LINKER_FLAGS CMAKE_SHARED_LINKER_FLAGS CMAKE_MODULE_LINKER_FLAGS
        unset LDFLAGS
        if [ -n "${host_cc}" ]; then
            host_cc="$(prepare_host_compiler_wrapper "${host_cc}" host-gcc)"
        fi
        if [ -n "${host_cxx}" ]; then
            host_cxx="$(prepare_host_compiler_wrapper "${host_cxx}" host-g++)"
        fi
        info Using host C compiler for flatbuffers: ${host_cc:-unresolved}
        info Using host C++ compiler for flatbuffers: ${host_cxx:-unresolved}
        if [ -n "${host_cc}" ]; then
            cmake_args+=("-DLITERT_HOST_C_COMPILER=${host_cc}")
        fi
        if [ -n "${host_cxx}" ]; then
            cmake_args+=("-DLITERT_HOST_CXX_COMPILER=${host_cxx}")
        fi
        info Using cross archive tool: ${cross_ar:-unresolved}
        info Using cross ranlib tool: ${cross_ranlib:-unresolved}
    fi

    append_litert_cache_linker_args cmake_args

    # Enable ruy but keep its profiler/instrumentation disabled to avoid
    # linking against ruy_profiler_instrumentation (not present in some
    # build environments / submodule combinations). Explicitly set
    # RUY_PROFILER=0 so the profiler is disabled while ruy remains enabled.
    info LiteRT CMake args: ${cmake_args[*]}
    cmake --preset "${preset}" "${cmake_args[@]}"
}

build_litert() {
    info Building LiteRT with ${NPROC} parallel jobs...

    local build_dir="cmake_build"
    if [ "${BUILD_TYPE}" = "Debug" ]; then
        build_dir="cmake_build_debug"
    fi

    cd "${LITERT_SRC}/litert"
    cmake --build "${build_dir}" -j"${NPROC}" || {
        warn Parallel build failed, trying single-threaded...
        cmake --build "${build_dir}" -j1 --verbose
    }
}

build_tflite_c_api() {
    info Building TensorFlow Lite C API library...

    local c_api_src="${LITERT_SRC}/tflite/c"
    if [ ! -d "${c_api_src}" ]; then
        warn TFLite C API source not found at ${c_api_src}; skipping C API build
        return 0
    fi

    # The C API CMakeLists.txt expects TF_SOURCE_DIR to contain tensorflow/lite
    # but LiteRT uses tflite/ instead. Create the compatibility symlink.
    info Creating tensorflow/lite symlink for C API build compatibility...
    mkdir -p "${LITERT_SRC}/tensorflow"
    ln -snf "${LITERT_SRC}/tflite" "${LITERT_SRC}/tensorflow/lite"

    local c_api_build="${LITERT_SRC}/tflite_c_build"
    local tflite_host_tools_dir=""
    mkdir -p "${c_api_build}"
    cd "${c_api_build}"

    local cmake_args=(
        "-DCMAKE_BUILD_TYPE=${BUILD_TYPE}"
        "-DCMAKE_INSTALL_PREFIX=${LITERT_PREFIX}"
        "-DCMAKE_INSTALL_LIBDIR=lib"
        "-DTFLITE_C_BUILD_SHARED_LIBS=ON"
        "-DTF_SOURCE_DIR=${LITERT_SRC}"
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
        "-DOVERRIDABLE_FETCH_CONTENT_GIT_REPOSITORY_AND_TAG_TO_URL_eigen=ON"
    )

    append_litert_preferred_cmake_compiler_args cmake_args

    if command -v append_cmake_cross_args >/dev/null 2>&1; then
        append_cmake_cross_args cmake_args
    fi

    if cross_build_is_active; then
        tflite_host_tools_dir="$(resolve_litert_tflite_host_tools_dir || true)"
        if command -v append_cmake_cross_archiver_args >/dev/null 2>&1; then
            append_cmake_cross_archiver_args cmake_args resolve_cross_archive_tool
        fi
        if [ -z "${tflite_host_tools_dir}" ]; then
            err Could not resolve TFLite host tools directory containing flatc for cross build
        fi
        cmake_args+=("-DTFLITE_HOST_TOOLS_DIR=${tflite_host_tools_dir}")
        info Using TFLite host tools dir: ${tflite_host_tools_dir}
    fi

    append_litert_cache_linker_args cmake_args

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
    if ! cmake --build . -j"${NPROC}"; then
        warn TFLite C API parallel build failed, trying single-threaded...
        if ! cmake --build . -j1 --verbose; then
            err TFLite C API build failed!
        fi
    fi

    info Installing TFLite C API...
    mkdir -p "${LITERT_PREFIX}/lib"
    if ! cmake --install .; then
        warn TFLite C API cmake install failed; falling back to manual library copy...
    fi
    # Some LiteRT revisions build libtensorflowlite_c.so without an install
    # rule. Copy it explicitly so downstream cross stages can link against it.
    find . -name "libtensorflowlite_c*.so*" -exec cp -av {} "${LITERT_PREFIX}/lib/" \; 2>/dev/null || true

    # Verify the library was built
    if [ -f "${LITERT_PREFIX}/lib/libtensorflowlite_c.so" ] || \
       ls "${c_api_build}"/libtensorflowlite_c*.so* 2>/dev/null; then
        info TFLite C API build complete - libtensorflowlite_c.so available
    else
        warn libtensorflowlite_c.so not found after build!
        info Checking build directory for any .so files:
        find "${c_api_build}" -name "*.so*" -ls 2>/dev/null || echo "No .so files found"
    fi
}

install_litert() {
    info Installing LiteRT to ${LITERT_PREFIX}...

    local build_dir="${LITERT_SRC}/litert/cmake_build"
    if [ "${BUILD_TYPE}" = "Debug" ]; then
        build_dir="${LITERT_SRC}/litert/cmake_build_debug"
    fi

    cd "${LITERT_SRC}/litert"

    cmake --build "${build_dir}" --target install || true

    install_manual

    ldconfig || true

    # Keep the output layout stable across native and cross builds so later
    # Docker stages can copy the wheels directory even when no wheel is built.
    mkdir -p "${LITERT_PREFIX}/wheels"

    local cross_wheel_build=false
    if cross_build_is_active; then
        cross_wheel_build=true
        if command -v cross_target_python_dev_ready >/dev/null 2>&1 && ! cross_target_python_dev_ready; then
            warn Target Python development files are unavailable; skipping LiteRT Python wheel build in cross mode
            return 0
        fi
        info Attempting LiteRT Python wheel build in cross mode for $(cross_target_arch)
    fi

    # Try to build a Python wheel if the project exposes a Python package
    local pip_pkg_dir="${LITERT_SRC}/tflite/tools/pip_package"
    if [ -d "${pip_pkg_dir}" ]; then
        info Detected Python packaging in LiteRT source - attempting to build wheel
        
        # We need to make sure the environment is set up for the pip package builder
        pushd "${pip_pkg_dir}" > /dev/null
        
        # The Litert script build_pip_package_with_cmake.sh builds the wheel.
        # It requires PYTHON environment variable
        export PYTHON="${HOST_PYTHON}"
        if [ -n "${PYTHON}" ]; then
            info Building wheel via build_pip_package_with_cmake.sh...
            # build_pip_package_with_cmake.sh uses these env vars to locate tensorflow/lite
            export TENSORFLOW_DIR="${LITERT_SRC}"
            export TENSORFLOW_LITE_DIR="${LITERT_SRC}/tflite"
            export TENSORFLOW_TARGET="native"
            
            # create missing directories and symlinks to satisfy hardcoded paths in pip script
            mkdir -p "${LITERT_SRC}/tensorflow"
            ln -snf "${LITERT_SRC}/tflite" "${LITERT_SRC}/tensorflow/lite"
            
            # fix build_pip_package_with_cmake.sh path resolution and version
            # shellcheck disable=SC2016
            sed -i 's|export TENSORFLOW_DIR=.*|export TENSORFLOW_DIR="${SCRIPT_DIR}/../../.."|g' build_pip_package_with_cmake.sh
            sed -i 's|TENSORFLOW_VERSION=.*|TENSORFLOW_VERSION="'"${LITERT_VERSION#v}"'"|g' build_pip_package_with_cmake.sh
            
            # Export the new official LiteRT name so the wheel matches PyPI
            export WHEEL_PROJECT_NAME="ai_edge_litert"
            
            # fix cmake policy error and inject required flags to match main build
            local extra_cmake_flags="-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DRUY_PROFILER=0 -DRUY_ENABLE_INSTRUMENTATION=OFF -DRUY_PROFILER_INSTRUMENTATION=OFF -DRUY_BUILD_TOOLS=OFF -DRUY_BUILD_TESTING=OFF -DLITERT_AUTO_BUILD_TFLITE=ON -DLITERT_ENABLE_GPU=OFF -DLITERT_ENABLE_NPU=OFF -DTFLITE_ENABLE_RUY=ON -DPython3_EXECUTABLE=${PYTHON} -DOVERRIDABLE_FETCH_CONTENT_GIT_REPOSITORY_AND_TAG_TO_URL_eigen=ON"
            local native_compiler_args=()
            local wheel_platform_name=""
            local tflite_host_tools_dir=""
            local python_major_minor="${PYTHON_MAJOR_MINOR:-}"
            local target_python_include=""
            local target_python_arch_include=""

            append_litert_preferred_cmake_compiler_args native_compiler_args
            if [ "${#native_compiler_args[@]}" -gt 0 ]; then
                extra_cmake_flags+=" ${native_compiler_args[*]}"
            fi

            if cross_build_is_active; then
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

                # Keep the pip helper on its generic/native code path so it does
                # not try to bootstrap a second host-flatc build with its own
                # limited cross-target switch logic. The injected CMake args
                # below still make the actual extension build target the cross
                # architecture and tag the produced wheel accordingly.
                export TENSORFLOW_TARGET="native"
                export WHEEL_PLATFORM_NAME="${wheel_platform_name}"
                info Building LiteRT wheel in cross mode for $(cross_target_arch)
                info Cross wheel platform tag: ${WHEEL_PLATFORM_NAME}
                info Cross wheel host tools dir: ${tflite_host_tools_dir}
            else
                export TENSORFLOW_TARGET="native"
                unset WHEEL_PLATFORM_NAME || true
            fi
            
            sed -i "s|cmake \"\${TENSORFLOW_LITE_DIR}\"|cmake ${extra_cmake_flags} \"\${TENSORFLOW_LITE_DIR}\"|g" build_pip_package_with_cmake.sh 2>/dev/null || true
            sed -i "s|cmake \\\\|cmake ${extra_cmake_flags} \\\\|g" build_pip_package_with_cmake.sh 2>/dev/null || true

            if cross_build_is_active; then
                # Debian/Ubuntu's Python.h in /usr/include/pythonX.Y includes
                # <triplet/pythonX.Y/pyconfig.h> (or the equivalent
                # target triplet). The cross compiler does not reliably search
                # /usr/include by default with the current sysroot/toolchain
                # setup, so make that root visible to the wheel helper's
                # BUILD_FLAGS path.
                # shellcheck disable=SC2016
                sed -i 's|BUILD_FLAGS=${BUILD_FLAGS:-"-march=native ${TF_CXX_FLAGS} -I${PYTHON_INCLUDE} -I${PYBIND11_INCLUDE} -I${NUMPY_INCLUDE}"}|BUILD_FLAGS=${BUILD_FLAGS:-"-idirafter /usr/include ${TF_CXX_FLAGS} -I${PYTHON_INCLUDE} -I${PYBIND11_INCLUDE} -I${NUMPY_INCLUDE}"}|' build_pip_package_with_cmake.sh 2>/dev/null || true
                # shellcheck disable=SC2016
                sed -i 's|BUILD_FLAGS=${BUILD_FLAGS:-"${TF_CXX_FLAGS} -I${PYTHON_INCLUDE} -I${PYBIND11_INCLUDE} -I${NUMPY_INCLUDE}"}|BUILD_FLAGS=${BUILD_FLAGS:-"-idirafter /usr/include ${TF_CXX_FLAGS} -I${PYTHON_INCLUDE} -I${PYBIND11_INCLUDE} -I${NUMPY_INCLUDE}"}|' build_pip_package_with_cmake.sh 2>/dev/null || true
            fi
            
            # remove -march=native from build flags to avoid multi-arch issues
            sed -i 's|-march=native ||g' build_pip_package_with_cmake.sh 2>/dev/null || true
            
            # Vendored neon2sse requires CMake >= 3.5; export so cmake picks it up
            export CMAKE_POLICY_VERSION_MINIMUM=3.5
            
            # run the script
            bash build_pip_package_with_cmake.sh "${TENSORFLOW_TARGET}" > pip_build.log 2>&1 || {
                warn pip wheel failed for LiteRT source. Last 1000 lines of log:
                tail -n 1000 pip_build.log
                if [ "${cross_wheel_build}" = "true" ]; then
                    warn Continuing without a local LiteRT wheel for the cross build
                    popd > /dev/null
                    return 0
                fi
                exit 1
            }
            
            # Print the log if it succeeds so we can debug anyway!
            info pip wheel success! Last 50 lines of log:
            tail -n 50 pip_build.log
            
            # The wheels are created in tflite/tools/pip_package/gen/tflite_pip/python3/dist/
            find "gen/tflite_pip" -name "*.whl" -type f -exec cp -v {} "${LITERT_PREFIX}/wheels/" \; 2>/dev/null || warn No wheels found after build script
        else
            warn No python found in PATH to build LiteRT wheel
        fi
        popd > /dev/null
    else
        info "No Python packaging detected for LiteRT at ${pip_pkg_dir}; skipping wheel build"
    fi
}

install_manual() {
    local build_dir="${LITERT_SRC}/litert/cmake_build"
    if [ "${BUILD_TYPE}" = "Debug" ]; then
        build_dir="${LITERT_SRC}/litert/cmake_build_debug"
    fi

    local lib_dir="${LITERT_PREFIX}/lib"
    local include_dir="${LITERT_PREFIX}/include"

    mkdir -p "${lib_dir}"
    mkdir -p "${include_dir}"

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

    info "Copying headers (C++ and C API)..."
    cd "${LITERT_SRC}"
    
    # 1. Copy ALL headers (C and C++) preserving the directory structure
    if [ -d "tensorflow/lite" ]; then
        info Found tensorflow/lite source layout...
        find tensorflow/lite -type f \( -name "*.h" -o -name "*.hpp" \) -print0 | cpio -pdm "${include_dir}/"
    elif [ -d "litert" ]; then
        info Found litert source layout...
        find litert -type f \( -name "*.h" -o -name "*.hpp" \) -print0 | cpio -pdm "${include_dir}/"
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
    cp -rv "litert/c" "${include_dir}/" 2>/dev/null || true
    
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
    
    # 5. Flatbuffers (Required by the C++ API)
    # CMake builds may place FlatBuffers headers in different locations
    # depending on the subproject naming. Check common locations and
    # fall back to searching for the header if needed.
    fb_found=0
    if [ -d "${LITERT_SRC}/litert/cmake_build/_deps/flatbuffers-src/include" ]; then
        info Copying flatbuffers headers from _deps/flatbuffers-src/include...
        cp -rv "${LITERT_SRC}/litert/cmake_build/_deps/flatbuffers-src/include"/* "${include_dir}/" 2>/dev/null || true
        fb_found=1
    fi
    if [ -d "${LITERT_SRC}/litert/cmake_build/flatbuffers-flatc/include" ]; then
        info Copying flatbuffers headers from flatbuffers-flatc/include...
        cp -rv "${LITERT_SRC}/litert/cmake_build/flatbuffers-flatc/include"/* "${include_dir}/" 2>/dev/null || true
        fb_found=1
    fi
    # Also check for an installed location within the build tree
    if [ -d "${LITERT_SRC}/litert/cmake_build/flatbuffers-flatc/include/flatbuffers" ]; then
        info Copying flatbuffers headers from flatbuffers-flatc/include/flatbuffers...
        mkdir -p "${include_dir}/flatbuffers" || true
        cp -rv "${LITERT_SRC}/litert/cmake_build/flatbuffers-flatc/include/flatbuffers"/* "${include_dir}/flatbuffers/" 2>/dev/null || true
        fb_found=1
    fi
    # Final fallback: search for the flatbuffers.h file and copy its directory
    if [ "$fb_found" -eq 0 ]; then
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

    # 6. Abseil (absl) headers (Required transitively by the tflite C++ headers)
    # tflite/util.h does `#include "absl/types/span.h"`, which is pulled in via
    # <tflite/interpreter.h>. Downstream consumers such as libcamera's
    # rpi/awb_nn.cpp include tflite/interpreter.h and therefore need the absl
    # headers on the include path. Copy them next to the tflite headers.
    info "Copying Abseil (absl) headers..."
    absl_found=0
    for absl_root in \
        "${LITERT_SRC}/litert/cmake_build/_deps/abseil-cpp-src" \
        "${LITERT_SRC}/litert/cmake_build/_deps/abseil_cpp-src" \
        "${LITERT_SRC}/litert/cmake_build/_deps/abseil-src"; do
        if [ -d "${absl_root}/absl" ]; then
            info Copying absl headers from ${absl_root}/absl...
            ( cd "${absl_root}" && find absl -type f \( -name "*.h" -o -name "*.inc" \) \
                -print0 | cpio -pdm "${include_dir}/" ) 2>/dev/null || true
            absl_found=1
            break
        fi
    done
    # Fallback: locate absl/types/span.h anywhere under the LiteRT tree and copy
    # the absl tree rooted at its grandparent directory.
    if [ "$absl_found" -eq 0 ]; then
        spanhdr=$(find "${LITERT_SRC}/litert" -type f -path "*/absl/types/span.h" -print -quit 2>/dev/null || true)
        if [ -n "$spanhdr" ]; then
            absl_root=$(dirname "$(dirname "$(dirname "$spanhdr")")")
            info "Found absl headers under ${absl_root}; copying..."
            ( cd "${absl_root}" && find absl -type f \( -name "*.h" -o -name "*.inc" \) \
                -print0 | cpio -pdm "${include_dir}/" ) 2>/dev/null || true
            absl_found=1
        fi
    fi
    if [ "$absl_found" -eq 1 ] && [ -f "${include_dir}/absl/types/span.h" ]; then
        info Verified: absl/types/span.h is accessible
    else
        warn "Abseil headers not found; tflite-consuming targets (e.g. libcamera awb_nn) may fail to compile"
    fi

    local static_libs=""
    for lib in "${lib_dir}"/*.a; do
        [ -f "${lib}" ] || continue
        libname=$(basename "${lib}" .a)
        static_libs="${static_libs} -l${libname}"
    done

    mkdir -p "${lib_dir}/pkgconfig"

    cat > "${lib_dir}/pkgconfig/litert.pc" <<EOF
prefix=${LITERT_PREFIX}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: LiteRT
Description: Google LiteRT Runtime Library
Version: ${LITERT_VERSION}
Libs: -L\${libdir} -lLiteRt -ltensorflow-lite
Libs.private: ${static_libs}
Cflags: -I\${includedir}
EOF

    cat > "${lib_dir}/pkgconfig/tensorflow-lite.pc" <<EOF
prefix=${LITERT_PREFIX}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: TensorFlow Lite
Description: TensorFlow Lite Library (via LiteRT)
Version: ${LITERT_VERSION}
Libs: -L\${libdir} -ltensorflow-lite
Libs.private: ${static_libs} -lpthread -ldl
Cflags: -I\${includedir}
EOF

    # Create pkg-config file for the C API (tensorflowlite_c)
    # GStreamer's tflite plugin prefers this library
    cat > "${lib_dir}/pkgconfig/tensorflowlite_c.pc" <<EOF
prefix=${LITERT_PREFIX}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: TensorFlow Lite C API
Description: TensorFlow Lite C API Library (via LiteRT)
Version: ${LITERT_VERSION}
Libs: -L\${libdir} -ltensorflowlite_c
Libs.private: -lpthread -ldl
Cflags: -I\${includedir}
EOF
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
    verify_installation
    cleanup
    info LiteRT build complete
}

main "$@"
