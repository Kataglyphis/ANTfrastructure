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
        python3 \
        python3-pip \
        python3-numpy \
        curl \
        unzip
    rm -rf /var/lib/apt/lists/*
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

    cmake --preset "${preset}" \
        -DCMAKE_INSTALL_PREFIX="${LITERT_PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DLITERT_AUTO_BUILD_TFLITE=ON \
        -DLITERT_ENABLE_GPU=OFF \
        -DLITERT_ENABLE_NPU=OFF \
        -DBUILD_SHARED_LIBS=ON
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

    cmake --build "${build_dir}" --target install || {
        echo "[INFO] Install target not available, installing manually..."
        install_manual
    }

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

    find "${build_dir}" -name "*.so*" -exec cp -v {} "${lib_dir}/" \; 2>/dev/null || true
    find "${build_dir}" -name "*.a" -exec cp -v {} "${lib_dir}/" \; 2>/dev/null || true

    cp -rv "${LITERT_SRC}/litert/c" "${include_dir}/" 2>/dev/null || true
    cp -rv "${LITERT_SRC}/tflite/c" "${include_dir}/tensorflow/lite/" 2>/dev/null || true

    mkdir -p "${lib_dir}/pkgconfig"

    cat > "${lib_dir}/pkgconfig/litert.pc" <<EOF
prefix=${LITERT_PREFIX}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: LiteRT
Description: Google LiteRT Runtime Library
Version: ${LITERT_VERSION}
Libs: -L\${libdir} -lLiteRt -ltensorflowlite
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
Libs: -L\${libdir} -ltensorflowlite
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