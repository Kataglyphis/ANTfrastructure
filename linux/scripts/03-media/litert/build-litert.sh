#!/usr/bin/env bash
set -euo pipefail

LITERT_VERSION="${1:-v2.1.3}"
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

    # Enable ruy but keep its profiler/instrumentation disabled to avoid
    # linking against ruy_profiler_instrumentation (not present in some
    # build environments / submodule combinations). Explicitly set
    # RUY_PROFILER=0 so the profiler is disabled while ruy remains enabled.
    cmake --preset "${preset}" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DRUY_PROFILER=0 \
        -DRUY_ENABLE_INSTRUMENTATION=OFF \
        -DRUY_PROFILER_INSTRUMENTATION=OFF \
        -DRUY_BUILD_TOOLS=OFF \
        -DRUY_BUILD_TESTING=OFF \
        -DCMAKE_INSTALL_PREFIX="${LITERT_PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DLITERT_AUTO_BUILD_TFLITE=ON \
        -DLITERT_ENABLE_GPU=OFF \
        -DLITERT_ENABLE_NPU=OFF \
        -DTFLITE_ENABLE_RUY=ON
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
            # build_pip_package_with_cmake.sh copies setup_with_binary.py and 
            # actually runs cmake natively to produce _pywrap_tensorflow_interpreter_wrapper.so
            # Since we already built some things, this script might rebuild or we just let it.
            # We must set TENSORFLOW_TARGET=native
            export TENSORFLOW_TARGET="native"
            # It expects to write to out directory or gen directory. Let's just run it:
            bash build_pip_package_with_cmake.sh native || echo "[WARN] pip wheel failed for LiteRT source"
            
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
