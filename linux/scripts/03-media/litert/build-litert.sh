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
    if [ "${SKIP_DEP_INSTALL}" = "true" ]; then
        echo "[INFO] Skipping dependency installation (SKIP_DEP_INSTALL=true)"
        return 0
    fi

    echo "[INFO] Installing build dependencies..."
    apt-get update
    apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        git \
        pkg-config \
        curl \
        unzip \
        python3-dev \
        gfortran \
        libopenblas-dev \
        liblapack-dev \
        libatlas-base-dev \
        ninja-build
    rm -rf /var/lib/apt/lists/*

    echo "[INFO] Setting up Python via uv venv..."
    export PATH="${HOME}/.local/bin:${PATH}"
    uv venv /opt/venv-litert --python 3.12
    source /opt/venv-litert/bin/activate

    # Ensure pip/build tooling is up-to-date so numpy can build wheels when
    # prebuilt wheels are not available for the target architecture (eg.
    # riscv64). Installing cython/pybind11 helps avoid build failures when
    # numpy needs to compile C extensions from source.
    uv pip install --upgrade pip setuptools wheel
    uv pip install cython pybind11
    uv pip install numpy
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

    if [ -f /opt/venv-litert/bin/activate ]; then
        source /opt/venv-litert/bin/activate
    fi

    cd "${LITERT_SRC}/litert"

    local preset="default"
    if [ "${BUILD_TYPE}" = "Debug" ]; then
        preset="default-debug"
    fi

    echo "[INFO] Using preset: ${preset}"

    # Disable ruy profiler/instrumentation and related tooling to avoid
    # linking against ruy_profiler_instrumentation (not present in some
    # build environments / submodule combinations). Keep RUY_PROFILER=OFF
    # for compatibility but also set several explicit ruy-related flags so
    # CMake won't accidentally pull in the instrumentation library.
    cmake --preset "${preset}" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DRUY_PROFILER=OFF \
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
        -DTFLITE_ENABLE_RUY=OFF
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

    echo "[INFO] Copying headers..."
    cp -rv "${LITERT_SRC}/litert/c" "${include_dir}/" 2>/dev/null || true
    cp -rv "${LITERT_SRC}/tflite" "${include_dir}/" 2>/dev/null || true
    mkdir -p "${include_dir}/tensorflow/lite/c"
    ln -sf "${include_dir}/tflite/c/c_api.h" "${include_dir}/tensorflow/lite/c/c_api.h" 2>/dev/null || true
    ln -sf "${include_dir}/tflite/c/c_api_experimental.h" "${include_dir}/tensorflow/lite/c/c_api_experimental.h" 2>/dev/null || true
    ln -sf "${include_dir}/tflite/c/c_api_opaque.h" "${include_dir}/tensorflow/lite/c/c_api_opaque.h" 2>/dev/null || true
    ln -sf "${include_dir}/tflite/c/common.h" "${include_dir}/tensorflow/lite/c/common.h" 2>/dev/null || true
    ln -sf "${include_dir}/tflite/c/builtin_op_kernels.h" "${include_dir}/tensorflow/lite/c/builtin_op_kernels.h" 2>/dev/null || true

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
