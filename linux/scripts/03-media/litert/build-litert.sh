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
    "/opt/scripts/core/compiler-cache.sh" \
    "${SCRIPT_DIR_LITERT}/../../../01-core/compiler-cache.sh"; do
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

echo "[INFO] Building LiteRT ${LITERT_VERSION}"
echo "[INFO] Using JOBS=${NPROC}"
echo "[INFO] Install prefix: ${LITERT_PREFIX}"

install_dependencies() {
    echo "[INFO] Dependencies should be installed prior to running this script."
}

fetch_litert() {
    echo "[INFO] Fetching LiteRT ${LITERT_VERSION} source..."

    rm -rf "${LITERT_SRC}"
    git clone --depth=1 --branch "${LITERT_VERSION}" \
        https://github.com/google-ai-edge/LiteRT.git "${LITERT_SRC}"
    cd "${LITERT_SRC}"

    echo "[INFO] LiteRT version: $(git describe --tags 2>/dev/null || echo 'unknown')"
}

configure_litert() {
    echo "[INFO] Configuring LiteRT build..."

    cd "${LITERT_SRC}/litert"

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
        "-DPython3_EXECUTABLE=$(which python3)"
    )

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
        cmake --build "${build_dir}" -j1
    }
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

    # Try to build a Python wheel if the project exposes a Python package
    mkdir -p "${LITERT_PREFIX}/wheels"
    
    local pip_pkg_dir="${LITERT_SRC}/tflite/tools/pip_package"
    if [ -d "${pip_pkg_dir}" ]; then
        echo "[INFO] Detected Python packaging in LiteRT source - attempting to build wheel"
        
        # We need to make sure the environment is set up for the pip package builder
        pushd "${pip_pkg_dir}" > /dev/null
        
        # The Litert script build_pip_package_with_cmake.sh builds the wheel.
        # It requires PYTHON environment variable
        export PYTHON="$(which python3)"
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
            sed -i 's|export TENSORFLOW_DIR=.*|export TENSORFLOW_DIR="${SCRIPT_DIR}/../../.."|g' build_pip_package_with_cmake.sh
            sed -i 's|TENSORFLOW_VERSION=.*|TENSORFLOW_VERSION="'"${LITERT_VERSION#v}"'"|g' build_pip_package_with_cmake.sh
            
            # Export the new official LiteRT name so the wheel matches PyPI
            export WHEEL_PROJECT_NAME="ai_edge_litert"
            
            # fix cmake policy error and inject required flags to match main build
            local extra_cmake_flags="-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DRUY_PROFILER=0 -DRUY_ENABLE_INSTRUMENTATION=OFF -DRUY_PROFILER_INSTRUMENTATION=OFF -DRUY_BUILD_TOOLS=OFF -DRUY_BUILD_TESTING=OFF -DLITERT_AUTO_BUILD_TFLITE=ON -DLITERT_ENABLE_GPU=OFF -DLITERT_ENABLE_NPU=OFF -DTFLITE_ENABLE_RUY=ON -DPython3_EXECUTABLE=${PYTHON}"
            
            sed -i "s|cmake \"\${TENSORFLOW_LITE_DIR}\"|cmake ${extra_cmake_flags} \"\${TENSORFLOW_LITE_DIR}\"|g" build_pip_package_with_cmake.sh
            sed -i "s|cmake \\\\|cmake ${extra_cmake_flags} \\\\|g" build_pip_package_with_cmake.sh
            
            # remove -march=native from build flags to avoid multi-arch issues
            sed -i 's|-march=native ||g' build_pip_package_with_cmake.sh
            
            # run the script
            bash build_pip_package_with_cmake.sh native > pip_build.log 2>&1 || {
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
        tfname=$(echo "${libname}" | sed 's/libLiteRt/libtensorflow-lite/')
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
        
        # General compatibility symlink
        mkdir -p "${include_dir}/tensorflow"
        ln -snf "${include_dir}/litert" "${include_dir}/tensorflow/lite"
    fi
    
    # 2. Restore explicit C API copies and symlinks for strict compatibility
    echo "[INFO] Ensuring strict C API compatibility..."
    cp -rv "litert/c" "${include_dir}/" 2>/dev/null || true
    cp -rv "tflite" "${include_dir}/" 2>/dev/null || true
    
    mkdir -p "${include_dir}/tensorflow/lite/c"
    
    # Safely link specific C API headers depending on where they were found
    for header in c_api.h c_api_experimental.h c_api_opaque.h common.h builtin_op_kernels.h; do
        if [ -f "${include_dir}/litert/c/${header}" ]; then
            ln -sf "${include_dir}/litert/c/${header}" "${include_dir}/tensorflow/lite/c/${header}"
        elif [ -f "${include_dir}/tflite/c/${header}" ]; then
            ln -sf "${include_dir}/tflite/c/${header}" "${include_dir}/tensorflow/lite/c/${header}"
        fi
    done
    
    # 3. Flatbuffers (Required by the C++ API)
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
    install_dependencies
    fetch_litert
    configure_litert
    build_litert
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
