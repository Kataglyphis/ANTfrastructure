#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# build-litert.sh - Build and install LiteRT from source
# ==============================================================================
#
# Build Acceleration:
#   USE_CCACHE=true     Enable ccache for faster rebuilds (default: true)
#   USE_LLD=true        Use lld linker for faster linking (default: true)
# ==============================================================================

# Source build acceleration helpers if available
SCRIPT_DIR_LITERT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for helper in \
    "/opt/scripts/core/cross-env.sh" \
    "${SCRIPT_DIR_LITERT}/../../01-core/cross-env.sh"; do
    if [ -f "${helper}" ]; then
        # shellcheck disable=SC1090
        source "${helper}"
        break
    fi
done

for helper in \
    "/opt/scripts/core/compiler-cache.sh" \
    "${SCRIPT_DIR_LITERT}/../../01-core/compiler-cache.sh"; do
    if [ -f "${helper}" ]; then
        # shellcheck disable=SC1090
        source "${helper}"
        setup_ccache
        setup_lld_linker
        break
    fi
done

LITERT_VERSION="${1:-v2.1.4}"
: "${LITERT_SRC:=/tmp/litert}"
: "${LITERT_PREFIX:=/usr/local}"
: "${BUILD_TYPE:=Release}"
: "${NPROC:=$(nproc)}"
: "${SKIP_DEP_INSTALL:=false}"

HOST_PYTHON="$(host_python_bin)"
HOST_PYTHON_MM="$(host_python_major_minor 2>/dev/null || true)"
if [ -n "${HOST_PYTHON_MM}" ] && [ -z "${PYTHON_MAJOR_MINOR:-}" ]; then
    export PYTHON_MAJOR_MINOR="${HOST_PYTHON_MM}"
fi
export PYTHON_EXECUTABLE="${HOST_PYTHON}" \
       Python_EXECUTABLE="${HOST_PYTHON}" \
       Python3_EXECUTABLE="${HOST_PYTHON}"

echo "[INFO] Building LiteRT ${LITERT_VERSION}"
echo "[INFO] Using JOBS=${NPROC}"
echo "[INFO] Install prefix: ${LITERT_PREFIX}"

fetch_litert() {
    echo "[INFO] Fetching LiteRT ${LITERT_VERSION} source..."

    rm -rf "${LITERT_SRC}"
    git clone --depth=1 --branch "${LITERT_VERSION}" \
        https://github.com/google-ai-edge/LiteRT.git "${LITERT_SRC}"
    cd "${LITERT_SRC}"

    echo "[INFO] LiteRT version: $(git describe --tags 2>/dev/null || echo 'unknown')"
}

resolve_host_compiler() {
    local lang="$1"
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
    local lang="$1"
    local compiler="$2"
    local wrapper_dir="${LITERT_HOST_TOOLCHAIN_DIR:-/tmp/litert-host-toolchain}"
    local wrapper=""

    case "${lang}" in
        c) wrapper="${wrapper_dir}/host-gcc" ;;
        cxx) wrapper="${wrapper_dir}/host-g++" ;;
        *) return 1 ;;
    esac

    if command -v make_host_compiler_wrapper >/dev/null 2>&1; then
        make_host_compiler_wrapper "${wrapper}" "${compiler}"
        return 0
    fi

    mkdir -p "${wrapper_dir}"
    cat > "${wrapper}" <<EOF
#!/usr/bin/env bash
exec env PATH="/usr/bin:/bin" "${compiler}" -B/usr/bin/ "\$@"
EOF
    chmod +x "${wrapper}"
    printf '%s' "${wrapper}"
}

resolve_litert_cross_archive_tool() {
    local tool="$1"
    local triplet="${CROSS_TARGET_TRIPLET:-}"
    local preferred=""
    local fallback=""
    local resolved=""

    if [ -z "${triplet}" ] && command -v cross_target_triplet >/dev/null 2>&1; then
        triplet="$(cross_target_triplet)"
    fi

    preferred="${triplet}-gcc-${tool}"
    fallback="${triplet}-${tool}"

    resolved="$(command -v "${preferred}" 2>/dev/null || true)"
    if [ -n "${resolved}" ]; then
        printf '%s' "${resolved}"
        return 0
    fi

    resolved="$(command -v "${fallback}" 2>/dev/null || true)"
    if [ -n "${resolved}" ]; then
        printf '%s' "${resolved}"
        return 0
    fi

    printf '%s' "${fallback}"
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

litert_cross_wheel_platform_tag() {
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
    echo "[INFO] Configuring LiteRT build..."

    cd "${LITERT_SRC}/litert"

    local host_cc=""
    local host_cxx=""
    local cross_ar=""
    local cross_ranlib=""

    host_cc="$(resolve_host_compiler c)"
    host_cxx="$(resolve_host_compiler cxx)"

    local preset="default"
    if [ "${BUILD_TYPE}" = "Debug" ]; then
        preset="default-debug"
    fi

    echo "[INFO] Using preset: ${preset}"

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

    if command -v append_cmake_cross_args >/dev/null 2>&1; then
        append_cmake_cross_args cmake_args
    fi

    if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
        cross_ar="$(resolve_litert_cross_archive_tool ar)"
        cross_ranlib="$(resolve_litert_cross_archive_tool ranlib)"

        cmake_args+=("-DCMAKE_AR=${cross_ar}")
        cmake_args+=("-DCMAKE_RANLIB=${cross_ranlib}")
        cmake_args+=("-DCMAKE_C_COMPILER_AR=${cross_ar}")
        cmake_args+=("-DCMAKE_CXX_COMPILER_AR=${cross_ar}")
        cmake_args+=("-DCMAKE_C_COMPILER_RANLIB=${cross_ranlib}")
        cmake_args+=("-DCMAKE_CXX_COMPILER_RANLIB=${cross_ranlib}")

        # LiteRT configures a nested host-only FlatBuffers build for flatc.
        # Do not let the target-side toolchain/cache/linker environment leak into
        # that host probe, or CMake's simple compiler checks can fail.
        unset CC CXX AR AS LD NM RANLIB STRIP OBJCOPY
        unset CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER CMAKE_ASM_COMPILER_LAUNCHER
        unset CMAKE_EXE_LINKER_FLAGS CMAKE_SHARED_LINKER_FLAGS CMAKE_MODULE_LINKER_FLAGS
        unset LDFLAGS
        if [ -n "${host_cc}" ]; then
            host_cc="$(prepare_host_compiler_wrapper c "${host_cc}")"
        fi
        if [ -n "${host_cxx}" ]; then
            host_cxx="$(prepare_host_compiler_wrapper cxx "${host_cxx}")"
        fi
        echo "[INFO] Using host C compiler for flatbuffers: ${host_cc:-unresolved}"
        echo "[INFO] Using host C++ compiler for flatbuffers: ${host_cxx:-unresolved}"
        if [ -n "${host_cc}" ]; then
            cmake_args+=("-DLITERT_HOST_C_COMPILER=${host_cc}")
        fi
        if [ -n "${host_cxx}" ]; then
            cmake_args+=("-DLITERT_HOST_CXX_COMPILER=${host_cxx}")
        fi
        echo "[INFO] Using cross archive tool: ${cross_ar}"
        echo "[INFO] Using cross ranlib tool: ${cross_ranlib}"
    fi

    # Add lld linker flags if available
    if command -v ld.lld >/dev/null 2>&1 && [ "${USE_LLD:-true}" != "false" ]; then
        cmake_args+=("-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld")
        cmake_args+=("-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld")
        cmake_args+=("-DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld")
        echo "[INFO] Using lld linker for faster linking"
    fi

    # Add ccache if available
    # Only add if CMAKE_C_COMPILER_LAUNCHER is not already set by compiler-cache.sh
    if command -v ccache >/dev/null 2>&1 && [ "${USE_CCACHE:-true}" != "false" ]; then
        if [ -z "${CMAKE_C_COMPILER_LAUNCHER:-}" ]; then
            cmake_args+=("-DCMAKE_C_COMPILER_LAUNCHER=ccache")
            cmake_args+=("-DCMAKE_CXX_COMPILER_LAUNCHER=ccache")
            # Explicitly disable ccache for ASM files - ccache cannot handle assembly
            # and will fail with "invalid option -- 'D'" when processing .S files
            cmake_args+=("-DCMAKE_ASM_COMPILER_LAUNCHER=")
            echo "[INFO] Using ccache for faster compilation (C/C++ only, not ASM)"
        else
            echo "[INFO] ccache already configured via environment"
            # Still need to disable ASM launcher to prevent ccache from being used for .S files
            cmake_args+=("-DCMAKE_ASM_COMPILER_LAUNCHER=")
        fi
    fi

    # Enable ruy but keep its profiler/instrumentation disabled to avoid
    # linking against ruy_profiler_instrumentation (not present in some
    # build environments / submodule combinations). Explicitly set
    # RUY_PROFILER=0 so the profiler is disabled while ruy remains enabled.
    echo "[INFO] LiteRT CMake args: ${cmake_args[*]}"
    cmake --preset "${preset}" "${cmake_args[@]}"
}

build_litert() {
    echo "[INFO] Building LiteRT with ${NPROC} parallel jobs..."

    local build_dir="cmake_build"
    if [ "${BUILD_TYPE}" = "Debug" ]; then
        build_dir="cmake_build_debug"
    fi

    cd "${LITERT_SRC}/litert"
    cmake --build "${build_dir}" -j"${NPROC}" || {
        echo "[WARN] Parallel build failed, trying single-threaded..."
        cmake --build "${build_dir}" -j1 --verbose
    }
}

build_tflite_c_api() {
    echo "[INFO] Building TensorFlow Lite C API library..."

    local c_api_src="${LITERT_SRC}/tflite/c"
    if [ ! -d "${c_api_src}" ]; then
        echo "[WARN] TFLite C API source not found at ${c_api_src}; skipping C API build"
        return 0
    fi

    # The C API CMakeLists.txt expects TF_SOURCE_DIR to contain tensorflow/lite
    # but LiteRT uses tflite/ instead. Create the compatibility symlink.
    echo "[INFO] Creating tensorflow/lite symlink for C API build compatibility..."
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

    if command -v append_cmake_cross_args >/dev/null 2>&1; then
        append_cmake_cross_args cmake_args
    fi

    if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
        local cross_ar
        local cross_ranlib

        cross_ar="$(resolve_litert_cross_archive_tool ar)"
        cross_ranlib="$(resolve_litert_cross_archive_tool ranlib)"
        tflite_host_tools_dir="$(resolve_litert_tflite_host_tools_dir || true)"
        cmake_args+=("-DCMAKE_AR=${cross_ar}")
        cmake_args+=("-DCMAKE_RANLIB=${cross_ranlib}")
        cmake_args+=("-DCMAKE_C_COMPILER_AR=${cross_ar}")
        cmake_args+=("-DCMAKE_CXX_COMPILER_AR=${cross_ar}")
        cmake_args+=("-DCMAKE_C_COMPILER_RANLIB=${cross_ranlib}")
        cmake_args+=("-DCMAKE_CXX_COMPILER_RANLIB=${cross_ranlib}")
        if [ -z "${tflite_host_tools_dir}" ]; then
            echo "[ERROR] Could not resolve TFLite host tools directory containing flatc for cross build"
            return 1
        fi
        cmake_args+=("-DTFLITE_HOST_TOOLS_DIR=${tflite_host_tools_dir}")
        echo "[INFO] Using TFLite host tools dir: ${tflite_host_tools_dir}"
    fi

    # Add lld linker flags if available
    if command -v ld.lld >/dev/null 2>&1 && [ "${USE_LLD:-true}" != "false" ]; then
        cmake_args+=("-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld")
        cmake_args+=("-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld")
        cmake_args+=("-DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld")
    fi

    # Add ccache if available
    if command -v ccache >/dev/null 2>&1 && [ "${USE_CCACHE:-true}" != "false" ]; then
        if [ -z "${CMAKE_C_COMPILER_LAUNCHER:-}" ]; then
            cmake_args+=("-DCMAKE_C_COMPILER_LAUNCHER=ccache")
            cmake_args+=("-DCMAKE_CXX_COMPILER_LAUNCHER=ccache")
            cmake_args+=("-DCMAKE_ASM_COMPILER_LAUNCHER=")
        fi
    fi

    echo "[INFO] Configuring TFLite C API..."
    echo "[INFO] C API source: ${c_api_src}"
    echo "[INFO] TF_SOURCE_DIR: ${LITERT_SRC}"
    echo "[INFO] Expected tensorflow/lite at: ${LITERT_SRC}/tensorflow/lite"
    echo "[INFO] TFLite C API CMake args: ${cmake_args[*]}"
    ls -la "${LITERT_SRC}/tensorflow/lite" 2>/dev/null || echo "[WARN] tensorflow/lite symlink may not exist"
    
    if ! cmake "${c_api_src}" "${cmake_args[@]}"; then
        echo "[ERROR] TFLite C API cmake configure failed!"
        echo "[ERROR] This is required for GStreamer tflite plugin support."
        echo "[ERROR] Check the cmake output above for details."
        return 1
    fi

    echo "[INFO] Building TFLite C API..."
    if ! cmake --build . -j"${NPROC}"; then
        echo "[WARN] TFLite C API parallel build failed, trying single-threaded..."
        if ! cmake --build . -j1 --verbose; then
            echo "[ERROR] TFLite C API build failed!"
            return 1
        fi
    fi

    echo "[INFO] Installing TFLite C API..."
    mkdir -p "${LITERT_PREFIX}/lib"
    if ! cmake --install .; then
        echo "[WARN] TFLite C API cmake install failed; falling back to manual library copy..."
    fi
    # Some LiteRT revisions build libtensorflowlite_c.so without an install
    # rule. Copy it explicitly so downstream cross stages can link against it.
    find . -name "libtensorflowlite_c*.so*" -exec cp -av {} "${LITERT_PREFIX}/lib/" \; 2>/dev/null || true

    # Verify the library was built
    if [ -f "${LITERT_PREFIX}/lib/libtensorflowlite_c.so" ] || \
       ls "${c_api_build}"/libtensorflowlite_c*.so* 2>/dev/null; then
        echo "[INFO] TFLite C API build complete - libtensorflowlite_c.so available"
    else
        echo "[WARN] libtensorflowlite_c.so not found after build!"
        echo "[INFO] Checking build directory for any .so files:"
        find "${c_api_build}" -name "*.so*" -ls 2>/dev/null || echo "No .so files found"
    fi
}

install_litert() {
    echo "[INFO] Installing LiteRT to ${LITERT_PREFIX}..."

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

    if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
        echo "[INFO] Skipping LiteRT Python wheel build in cross mode; target wheel build and validation are not supported in the amd64 host container"
        return 0
    fi

    # Try to build a Python wheel if the project exposes a Python package
    local pip_pkg_dir="${LITERT_SRC}/tflite/tools/pip_package"
    if [ -d "${pip_pkg_dir}" ]; then
        echo "[INFO] Detected Python packaging in LiteRT source - attempting to build wheel"
        
        # We need to make sure the environment is set up for the pip package builder
        pushd "${pip_pkg_dir}" > /dev/null
        
        # The Litert script build_pip_package_with_cmake.sh builds the wheel.
        # It requires PYTHON environment variable
        export PYTHON="${HOST_PYTHON}"
        if [ -n "${PYTHON}" ]; then
            echo "[INFO] Building wheel via build_pip_package_with_cmake.sh..."
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
            local wheel_platform_name=""
            local tflite_host_tools_dir=""
            local python_major_minor="${PYTHON_MAJOR_MINOR:-}"
            local target_python_include=""
            local target_python_arch_include=""

            if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
                local wheel_cross_args=()
                local cross_ar
                local cross_ranlib

                python_major_minor="${python_major_minor:-$(host_python_major_minor 2>/dev/null || true)}"

                if command -v append_cmake_cross_args >/dev/null 2>&1; then
                    append_cmake_cross_args wheel_cross_args
                fi
                cross_ar="$(resolve_litert_cross_archive_tool ar)"
                cross_ranlib="$(resolve_litert_cross_archive_tool ranlib)"
                tflite_host_tools_dir="$(resolve_litert_tflite_host_tools_dir || true)"
                if [ -z "${tflite_host_tools_dir}" ]; then
                    echo "[ERROR] Could not resolve TFLite host tools directory containing flatc for cross wheel build"
                    exit 1
                fi
                wheel_platform_name="$(litert_cross_wheel_platform_tag || true)"
                if [ -z "${wheel_platform_name}" ]; then
                    echo "[ERROR] Could not resolve wheel platform tag for target architecture $(cross_target_arch)"
                    exit 1
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
                extra_cmake_flags+=" -DCMAKE_AR=${cross_ar} -DCMAKE_RANLIB=${cross_ranlib} -DCMAKE_C_COMPILER_AR=${cross_ar} -DCMAKE_CXX_COMPILER_AR=${cross_ar} -DCMAKE_C_COMPILER_RANLIB=${cross_ranlib} -DCMAKE_CXX_COMPILER_RANLIB=${cross_ranlib}"
                extra_cmake_flags+=" -DTFLITE_HOST_TOOLS_DIR=${tflite_host_tools_dir}"
                if [ -n "${target_python_include}" ]; then
                    extra_cmake_flags+=" -DPYTHON_INCLUDE_DIR=${target_python_include}"
                    extra_cmake_flags+=" -DPYTHON_INCLUDE_PATH=${target_python_include}"
                    echo "[INFO] Cross wheel target Python include dir: ${target_python_include}"
                    echo "[INFO] Cross wheel target Python arch include dir: ${target_python_arch_include}"
                fi

                # Keep the pip helper on its generic/native code path so it does
                # not try to bootstrap a second host-flatc build with its own
                # limited cross-target switch logic. The injected CMake args
                # below still make the actual extension build target the cross
                # architecture and tag the produced wheel accordingly.
                export TENSORFLOW_TARGET="native"
                export WHEEL_PLATFORM_NAME="${wheel_platform_name}"
                echo "[INFO] Building LiteRT wheel in cross mode for $(cross_target_arch)"
                echo "[INFO] Cross wheel platform tag: ${WHEEL_PLATFORM_NAME}"
                echo "[INFO] Cross wheel host tools dir: ${tflite_host_tools_dir}"
            else
                export TENSORFLOW_TARGET="native"
                unset WHEEL_PLATFORM_NAME || true
            fi
            
            sed -i "s|cmake \"\${TENSORFLOW_LITE_DIR}\"|cmake ${extra_cmake_flags} \"\${TENSORFLOW_LITE_DIR}\"|g" build_pip_package_with_cmake.sh
            sed -i "s|cmake \\\\|cmake ${extra_cmake_flags} \\\\|g" build_pip_package_with_cmake.sh

            if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
                # Debian/Ubuntu's Python.h in /usr/include/pythonX.Y includes
                # <triplet/pythonX.Y/pyconfig.h> (or the equivalent
                # target triplet). The cross compiler does not reliably search
                # /usr/include by default with the current sysroot/toolchain
                # setup, so make that root visible to the wheel helper's
                # BUILD_FLAGS path.
                # shellcheck disable=SC2016
                sed -i 's|BUILD_FLAGS=${BUILD_FLAGS:-"-march=native ${TF_CXX_FLAGS} -I${PYTHON_INCLUDE} -I${PYBIND11_INCLUDE} -I${NUMPY_INCLUDE}"}|BUILD_FLAGS=${BUILD_FLAGS:-"-idirafter /usr/include ${TF_CXX_FLAGS} -I${PYTHON_INCLUDE} -I${PYBIND11_INCLUDE} -I${NUMPY_INCLUDE}"}|' build_pip_package_with_cmake.sh
                # shellcheck disable=SC2016
                sed -i 's|BUILD_FLAGS=${BUILD_FLAGS:-"${TF_CXX_FLAGS} -I${PYTHON_INCLUDE} -I${PYBIND11_INCLUDE} -I${NUMPY_INCLUDE}"}|BUILD_FLAGS=${BUILD_FLAGS:-"-idirafter /usr/include ${TF_CXX_FLAGS} -I${PYTHON_INCLUDE} -I${PYBIND11_INCLUDE} -I${NUMPY_INCLUDE}"}|' build_pip_package_with_cmake.sh
            fi
            
            # remove -march=native from build flags to avoid multi-arch issues
            sed -i 's|-march=native ||g' build_pip_package_with_cmake.sh
            
            # run the script
            bash build_pip_package_with_cmake.sh "${TENSORFLOW_TARGET}" > pip_build.log 2>&1 || {
                echo "[WARN] pip wheel failed for LiteRT source. Last 1000 lines of log:"
                tail -n 1000 pip_build.log
                exit 1
            }
            
            # Print the log if it succeeds so we can debug anyway!
            echo "[INFO] pip wheel success! Last 50 lines of log:"
            tail -n 50 pip_build.log
            
            # The wheels are created in tflite/tools/pip_package/gen/tflite_pip/python3/dist/
            find "gen/tflite_pip" -name "*.whl" -type f -exec cp -v {} "${LITERT_PREFIX}/wheels/" \; 2>/dev/null || echo "[WARN] No wheels found after build script"
        else
            echo "[WARN] No python found in PATH to build LiteRT wheel"
        fi
        popd > /dev/null
    else
        echo "[INFO] No Python packaging detected for LiteRT at ${pip_pkg_dir}; skipping wheel build"
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

    echo "[INFO] Copying shared libraries..."
    find "${build_dir}" -name "*.so*" -exec cp -v {} "${lib_dir}/" \; 2>/dev/null || true

    echo "[INFO] Copying static libraries..."
    find "${build_dir}" -name "*.a" -exec cp -v {} "${lib_dir}/" \; 2>/dev/null || true

    # Create symlinks for tensorflow-lite compatibility
    # LiteRT builds libLiteRt.so, but GStreamer expects libtensorflow-lite.so
    # Handle both versioned and unversioned libraries
    for lib in "${lib_dir}"/libLiteRt.so*; do
        [ -f "${lib}" ] || continue
        libname=$(basename "${lib}")
        tfname="${libname/libLiteRt/libtensorflow-lite}"
        ln -sf "${libname}" "${lib_dir}/${tfname}"
        echo "[INFO] Created symlink: ${tfname} -> ${libname}"
    done

    echo "[INFO] Copying headers (C++ and C API)..."
    cd "${LITERT_SRC}"
    
    # 1. Copy ALL headers (C and C++) preserving the directory structure
    if [ -d "tensorflow/lite" ]; then
        echo "[INFO] Found tensorflow/lite source layout..."
        find tensorflow/lite -type f \( -name "*.h" -o -name "*.hpp" \) -exec cp --parents {} "${include_dir}/" \;
    elif [ -d "litert" ]; then
        echo "[INFO] Found litert source layout..."
        find litert -type f \( -name "*.h" -o -name "*.hpp" \) -exec cp --parents {} "${include_dir}/" \;
    fi
    
    # 2. Copy tflite directory (contains TensorFlow Lite C++ compatibility headers)
    # This is CRITICAL for libcamera's awb_nn.cpp which needs tensorflow/lite/interpreter.h
    echo "[INFO] Copying tflite C++ compatibility headers..."
    if [ -d "tflite" ]; then
        cp -rv "tflite" "${include_dir}/" 2>/dev/null || true
        echo "[INFO] tflite headers copied to ${include_dir}/tflite"
    fi
    
    # 3. Copy litert/c headers for C API compatibility
    echo "[INFO] Ensuring strict C API compatibility..."
    cp -rv "litert/c" "${include_dir}/" 2>/dev/null || true
    
    # 4. Create tensorflow/lite -> tflite symlink for compatibility
    # libcamera and other projects expect headers at <tensorflow/lite/interpreter.h>
    # but LiteRT provides them at <tflite/interpreter.h>
    # NOTE: Since this is a symlink, tensorflow/lite/c will automatically resolve
    # to tflite/c which should already have the C API headers from the tflite copy
    echo "[INFO] Creating tensorflow/lite compatibility symlink..."
    mkdir -p "${include_dir}/tensorflow"
    rm -rf "${include_dir}/tensorflow/lite"  # Remove any existing symlink or directory
    ln -snf "${include_dir}/tflite" "${include_dir}/tensorflow/lite"
    echo "[INFO] Created symlink: ${include_dir}/tensorflow/lite -> ${include_dir}/tflite"
    
    # Verify the symlink works for the critical header
    if [ -f "${include_dir}/tensorflow/lite/interpreter.h" ]; then
        echo "[INFO] Verified: tensorflow/lite/interpreter.h is accessible"
    else
        echo "[WARN] tensorflow/lite/interpreter.h is NOT accessible via symlink!"
        echo "[INFO] Contents of ${include_dir}/tflite:"
        ls -la "${include_dir}/tflite" 2>/dev/null || echo "  (directory not found)"
    fi
    
    # 5. Flatbuffers (Required by the C++ API)
    # CMake builds may place FlatBuffers headers in different locations
    # depending on the subproject naming. Check common locations and
    # fall back to searching for the header if needed.
    fb_found=0
    if [ -d "${LITERT_SRC}/litert/cmake_build/_deps/flatbuffers-src/include" ]; then
        echo "[INFO] Copying flatbuffers headers from _deps/flatbuffers-src/include..."
        cp -rv "${LITERT_SRC}/litert/cmake_build/_deps/flatbuffers-src/include"/* "${include_dir}/" 2>/dev/null || true
        fb_found=1
    fi
    if [ -d "${LITERT_SRC}/litert/cmake_build/flatbuffers-flatc/include" ]; then
        echo "[INFO] Copying flatbuffers headers from flatbuffers-flatc/include..."
        cp -rv "${LITERT_SRC}/litert/cmake_build/flatbuffers-flatc/include"/* "${include_dir}/" 2>/dev/null || true
        fb_found=1
    fi
    # Also check for an installed location within the build tree
    if [ -d "${LITERT_SRC}/litert/cmake_build/flatbuffers-flatc/include/flatbuffers" ]; then
        echo "[INFO] Copying flatbuffers headers from flatbuffers-flatc/include/flatbuffers..."
        mkdir -p "${include_dir}/flatbuffers" || true
        cp -rv "${LITERT_SRC}/litert/cmake_build/flatbuffers-flatc/include/flatbuffers"/* "${include_dir}/flatbuffers/" 2>/dev/null || true
        fb_found=1
    fi
    # Final fallback: search for the flatbuffers.h file and copy its directory
    if [ "$fb_found" -eq 0 ]; then
        fbheader=$(find "${LITERT_SRC}/litert" -type f -path "*/flatbuffers/flatbuffers.h" -print -quit 2>/dev/null || true)
        if [ -n "$fbheader" ]; then
            fbdir=$(dirname "$fbheader")
            echo "[INFO] Found flatbuffers header at $fbheader; copying from $fbdir..."
            mkdir -p "${include_dir}/flatbuffers" || true
            cp -rv "$fbdir"/* "${include_dir}/flatbuffers/" 2>/dev/null || true
            fb_found=1
        fi
    fi
    if [ "$fb_found" -eq 0 ]; then
        echo "[WARN] FlatBuffers headers not found in expected build locations; some targets may fail to compile" || true
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
    echo "[INFO] Verifying LiteRT installation..."

    local found_libs=false
    if ls "${LITERT_PREFIX}/lib"/*[Ll]ite[Rr]t* 2>/dev/null; then
        found_libs=true
    fi
    if ls "${LITERT_PREFIX}/lib"/*tensorflow* 2>/dev/null; then
        found_libs=true
    fi

    if [ "${found_libs}" = "false" ]; then
        echo "[WARN] No LiteRT/TensorFlow Lite libraries found in ${LITERT_PREFIX}/lib"
        ls -la "${LITERT_PREFIX}/lib" 2>/dev/null || true
        return 1
    fi

    if [ -f "${LITERT_PREFIX}/lib/pkgconfig/litert.pc" ]; then
        echo "[INFO] LiteRT pkg-config:"
        cat "${LITERT_PREFIX}/lib/pkgconfig/litert.pc"
    fi

    if [ -f "${LITERT_PREFIX}/lib/pkgconfig/tensorflow-lite.pc" ]; then
        echo "[INFO] TensorFlow Lite pkg-config:"
        cat "${LITERT_PREFIX}/lib/pkgconfig/tensorflow-lite.pc"
    fi

    echo "[INFO] LiteRT ${LITERT_VERSION} installed successfully"
}

cleanup() {
    echo "[INFO] Cleaning up..."
    rm -rf "${LITERT_SRC}" || true
}

main() {
    echo "[INFO] LiteRT build started"
    fetch_litert
    configure_litert
    build_litert
    build_tflite_c_api
    install_litert
    verify_installation
    cleanup
    echo "[INFO] LiteRT build complete"
}

main "$@"

# Validation step
if [ -f "${LITERT_OUTPUT_DIR}/lib/pkgconfig/litert.pc" ]; then
    echo "LiteRT pkg-config found:"
    cat "${LITERT_OUTPUT_DIR}/lib/pkgconfig/litert.pc"
fi
if [ -f "${LITERT_OUTPUT_DIR}/lib/pkgconfig/tensorflow-lite.pc" ]; then
    echo "TensorFlow Lite (via LiteRT) pkg-config found:"
    cat "${LITERT_OUTPUT_DIR}/lib/pkgconfig/tensorflow-lite.pc"
fi
ls -la "${LITERT_OUTPUT_DIR}/lib"/*lite* 2>/dev/null || echo "Warning: LiteRT libraries may not be in expected location"
ldconfig
