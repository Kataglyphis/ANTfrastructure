#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# build-opencv.sh - Build and install OpenCV from source
# ==============================================================================
# This script fetches a specific version of OpenCV and builds it with
# commonly used modules and features enabled.
#
# Usage:
#   ./build-opencv.sh [--opencv-version VERSION]
#
# Defaults can be overridden via environment variables or arguments.
# ==============================================================================

# Defaults (can be overridden via env vars or arguments)
: "${OPENCV_VERSION:=4.13.0}"
: "${OPENCV_SRC:=/tmp/opencv}"
: "${OPENCV_PREFIX:=/opt/opencv}"
: "${OPENCV_REPO:=https://github.com/opencv/opencv.git}"
: "${OPENCV_CONTRIB_REPO:=https://github.com/opencv/opencv_contrib.git}"
: "${BUILD_TYPE:=Release}"
: "${NPROC:=$(nproc)}"
: "${WITH_CONTRIB:=true}"
: "${WITH_PYTHON:=true}"
: "${OPENCV_PYTHON_VERSION:=3.14}"
: "${WITH_JAVA:=false}"
: "${SKIP_DEP_INSTALL:=false}"
: "${WITH_IPP:=ON}"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --opencv-version|-v)
            OPENCV_VERSION="$2"
            shift 2
            ;;
        --prefix|-p)
            OPENCV_PREFIX="$2"
            shift 2
            ;;
        --build-type|-b)
            BUILD_TYPE="$2"
            shift 2
            ;;
        --with-contrib)
            WITH_CONTRIB="$2"
            shift 2
            ;;
        --with-python)
            WITH_PYTHON="$2"
            shift 2
            ;;
        --with-java)
            WITH_JAVA="$2"
            shift 2
            ;;
        --skip-dep-install)
            SKIP_DEP_INSTALL="true"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --opencv-version VERSION  OpenCV version to build (default: 4.13.0)"
            echo "  --prefix PATH             Installation prefix (default: /opt/opencv)"
            echo "  --build-type TYPE         Build type: Release/Debug (default: Release)"
            echo "  --with-contrib BOOL       Build with contrib modules (default: true)"
            echo "  --with-python BOOL        Build with Python bindings (default: true)"
            echo "  --with-java BOOL          Build with Java bindings (default: false)"
            echo "  --skip-dep-install        Skip dependency installation (for Docker)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "build-opencv: version=${OPENCV_VERSION} prefix=${OPENCV_PREFIX} buildtype=${BUILD_TYPE}"

# ------------------------------------------------------------------------------
# Install build dependencies
# ------------------------------------------------------------------------------
install_dependencies() {
    if [ "${SKIP_DEP_INSTALL}" = "true" ]; then
        echo "Skipping OpenCV dependency installation (SKIP_DEP_INSTALL=true)"
        return 0
    fi
    
    echo "Installing OpenCV build dependencies..."
    
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y --no-install-recommends \
            build-essential \
            cmake \
            git \
            pkg-config \
            wget \
            unzip \
            libtbb-dev \
            libeigen3-dev \
            libgtk-3-dev \
            libavcodec-dev \
            libavformat-dev \
            libswscale-dev \
            libv4l-dev \
            libxvidcore-dev \
            libx264-dev \
            libjpeg-dev \
            libpng-dev \
            libtiff-dev \
            libopenexr-dev \
            libgstreamer1.0-dev \
            libgstreamer-plugins-base1.0-dev \
            libdc1394-dev || true
        
    if [ "${WITH_PYTHON}" = "true" ]; then
        # Allow building against a specific Python version, defaulting to
        # ${OPENCV_PYTHON_VERSION}. Users can override by setting
        # OPENCV_PYTHON_VERSION=3.14 in the environment.
        PYVER_MAJOR_MINOR="${OPENCV_PYTHON_VERSION%.*}"
        apt-get install -y --no-install-recommends \
                "python${OPENCV_PYTHON_VERSION}-dev" || true
        # Fallback to generic python3-dev and tools if explicit package name
        # isn't available in older distros.
        apt-get install -y --no-install-recommends python3-dev python3-numpy python3-pip || true
    fi
        
        if [ "${WITH_JAVA}" = "true" ]; then
            apt-get install -y --no-install-recommends \
                default-jdk \
                ant || true
        fi
    else
        echo "apt-get not found - ensure OpenCV build deps are installed manually."
    fi
}

# ------------------------------------------------------------------------------
# Fetch OpenCV source
# ------------------------------------------------------------------------------
fetch_opencv() {
    echo "Fetching OpenCV ${OPENCV_VERSION} source..."
    
    # Main repository
    if [ -d "${OPENCV_SRC}/.git" ]; then
        echo "Updating existing OpenCV checkout..."
        cd "${OPENCV_SRC}"
        git fetch --tags || true
    else
        rm -rf "${OPENCV_SRC}"
        git clone "${OPENCV_REPO}" "${OPENCV_SRC}" || { echo "Failed cloning OpenCV"; exit 1; }
        cd "${OPENCV_SRC}"
    fi
    
    git checkout "${OPENCV_VERSION}" || { echo "Failed to checkout version ${OPENCV_VERSION}"; exit 1; }
    echo "OpenCV version: $(git describe --tags 2>/dev/null || echo 'unknown')"
    
    # Contrib modules (optional)
    if [ "${WITH_CONTRIB}" = "true" ]; then
        echo "Fetching OpenCV contrib modules..."
        # Use the conventional opencv_contrib directory name so CMake's
        # OPENCV_EXTRA_MODULES_PATH is the expected path
        local contrib_dir="${OPENCV_SRC}/opencv_contrib"

        if [ -d "${contrib_dir}/.git" ]; then
            cd "${contrib_dir}"
            git fetch --tags || true
        else
            rm -rf "${contrib_dir}"
            git clone "${OPENCV_CONTRIB_REPO}" "${contrib_dir}" || { echo "Failed cloning OpenCV contrib"; exit 1; }
            cd "${contrib_dir}"
        fi

        git checkout "${OPENCV_VERSION}" || { echo "Failed to checkout contrib version ${OPENCV_VERSION}"; exit 1; }
        echo "OpenCV contrib version: $(git describe --tags 2>/dev/null || echo 'unknown')"
    fi
}

# ------------------------------------------------------------------------------
# Configure OpenCV build
# ------------------------------------------------------------------------------
configure_opencv() {
    echo "Configuring OpenCV build..."
    
    local build_dir="${OPENCV_SRC}/build"
    mkdir -p "${build_dir}"
    cd "${build_dir}"
    
    # Disable IPP automatically on non-x86 hosts because OpenCV bundles
    # prebuilt ippicv libraries for x86 which will fail when linking on
    # architectures like aarch64 or riscv. Allow explicit override via
    # the WITH_IPP env var (set to "ON" or "OFF").
    if [ "$(uname -m)" != "x86_64" ] && [ "${WITH_IPP}" = "ON" ]; then
        echo "Non-x86 host detected ($(uname -m)) - disabling Intel IPP to avoid x86 prebuilt libs"
        WITH_IPP="OFF"
    fi

    # Build cmake options array
    local cmake_opts=(
        "-DCMAKE_BUILD_TYPE=${BUILD_TYPE}"
        "-DCMAKE_INSTALL_PREFIX=${OPENCV_PREFIX}"
        "-DCMAKE_INSTALL_LIBDIR=lib"
        "-DBUILD_SHARED_LIBS=ON"
        "-DENABLE_BUILD_HARDENING=ON"
        "-DOPENCV_GENERATE_PKGCONFIG=ON"
        "-DBUILD_TESTS=OFF"
        "-DBUILD_PERF_TESTS=OFF"
        "-DBUILD_EXAMPLES=OFF"
        "-DBUILD_DOCS=OFF"
        "-DBUILD_JAVA_TESTS=OFF"
        "-DINSTALL_TESTS=OFF"
        "-DINSTALL_C_EXAMPLES=OFF"
        "-DINSTALL_PYTHON_EXAMPLES=OFF"
        "-DWITH_TBB=ON"
        "-DWITH_EIGEN=ON"
        "-DWITH_GTK=ON"
        "-DWITH_V4L=ON"
        "-DWITH_FFMPEG=ON"
        "-DWITH_GSTREAMER=ON"
        "-DWITH_OPENEXR=ON"
        "-DWITH_JPEG=ON"
        "-DWITH_PNG=ON"
        "-DWITH_TIFF=ON"
        "-DWITH_DC1394=ON"
        "-DWITH_1394=ON"
        "-DWITH_OPENCL=ON"
        "-DWITH_IPP=${WITH_IPP}"
    )

    # Ensure tracking contrib module is explicitly enabled (some builds/platforms
    # may not build it by default even when contrib modules are available).
    cmake_opts+=("-DBUILD_opencv_tracking=ON")
    
    # Contrib modules
    if [ "${WITH_CONTRIB}" = "true" ]; then
        cmake_opts+=("-DOPENCV_EXTRA_MODULES_PATH=${OPENCV_SRC}/opencv_contrib/modules")
        cmake_opts+=("-DBUILD_opencv_python3=${WITH_PYTHON}")
    fi
    
    # Python bindings
    if [ "${WITH_PYTHON}" = "true" ]; then
        # Use explicit python executable if available (eg. python3.14)
        PY_EXEC="$(command -v python${OPENCV_PYTHON_VERSION} 2>/dev/null || command -v python3 2>/dev/null || true)"
        if [ -n "${PY_EXEC}" ]; then
            cmake_opts+=("-DPYTHON3_EXECUTABLE=${PY_EXEC}")
        else
            cmake_opts+=("-DPYTHON3_EXECUTABLE=python3")
        fi
    fi
    
    # Java bindings
    if [ "${WITH_JAVA}" = "true" ]; then
        cmake_opts+=("-DBUILD_JAVA=ON")
        cmake_opts+=("-DBUILD_opencv_java=ON")
    else
        cmake_opts+=("-DBUILD_JAVA=OFF")
        cmake_opts+=("-DBUILD_opencv_java=OFF")
    fi
    
    echo "CMake options: ${cmake_opts[*]}"
    cmake "${OPENCV_SRC}" "${cmake_opts[@]}" || { echo "OpenCV configure failed"; exit 1; }
}

# ------------------------------------------------------------------------------
# Build OpenCV
# ------------------------------------------------------------------------------
build_opencv() {
    echo "Building OpenCV with ${NPROC} parallel jobs..."
    
    local build_dir="${OPENCV_SRC}/build"
    cd "${build_dir}"
    
    make -j"${NPROC}" || { echo "OpenCV build failed"; exit 1; }
}

# ------------------------------------------------------------------------------
# Install OpenCV
# ------------------------------------------------------------------------------
install_opencv() {
    echo "Installing OpenCV to ${OPENCV_PREFIX}..."
    
    local build_dir="${OPENCV_SRC}/build"
    cd "${build_dir}"
    
    if [ "$EUID" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo make install
        else
            echo "Not root and sudo missing - cannot install; exiting"
            exit 1
        fi
    else
        make install
    fi
    
    # Update ld cache
    if command -v sudo >/dev/null 2>&1; then
        sudo ldconfig || true
    else
        ldconfig || true
    fi

    # Some packaging environments install versioned .so files without the
    # unversioned symlink (libopencv_tracking.so). Create a symlink if the
    # versioned library exists but the unversioned name is missing so downstream
    # linkers can find the library via -lopencv_tracking.
    # Ensure unversioned symlinks exist for contrib libraries (search lib and lib64)
    # Use sudo when available so this works whether the script ran as root or
    # invoked via sudo during `make install`.
    SUDO=""
    if command -v sudo >/dev/null 2>&1; then
        SUDO=sudo
    fi

    for libdir in "${OPENCV_PREFIX}/lib" "${OPENCV_PREFIX}/lib64"; do
        if [ -d "${libdir}" ]; then
            pushd "${libdir}" >/dev/null 2>&1 || true
            # Find any libopencv_tracking shared object (versioned or unversioned).
            candidate="$(ls -1 libopencv_tracking.so* 2>/dev/null | head -n1 || true)"
            if [ -n "${candidate}" ]; then
                if [ ! -e libopencv_tracking.so ]; then
                    echo "Creating symlink ${libdir}/libopencv_tracking.so -> ${candidate}"
                    ${SUDO} ln -sf "${candidate}" libopencv_tracking.so || true
                fi
            fi
            popd >/dev/null 2>&1 || true
        fi
    done

    # Sanity-check: fail early if tracking library is still missing
    if ! (ls "${OPENCV_PREFIX}/lib/libopencv_tracking.so" >/dev/null 2>&1 || ls "${OPENCV_PREFIX}/lib64/libopencv_tracking.so" >/dev/null 2>&1); then
        echo "ERROR: libopencv_tracking was not found after install. Listing installed libs for debugging:"
        ${SUDO} ls -la "${OPENCV_PREFIX}/lib" 2>/dev/null || true
        ${SUDO} ls -la "${OPENCV_PREFIX}/lib64" 2>/dev/null || true
        echo "Failing build so the image build doesn't continue with a broken OpenCV install."
        exit 1
    fi

    # Attempt to build/capture Python wheel for OpenCV
    mkdir -p "${OPENCV_PREFIX}/wheels"
    if [ "${WITH_PYTHON}" = "true" ]; then
        echo "Attempting to create OpenCV wheel using the selected Python"
        # Try using the python executable chosen during configure; fall back to python3
        PYEXEC="$(command -v python${OPENCV_PYTHON_VERSION} 2>/dev/null || command -v python3 2>/dev/null || true)"
        if [ -n "${PYEXEC}" ]; then
            # Many OpenCV builds place the Python wheel under build/lib/python*/site-packages
            # Try to use pip wheel against the source tree (if opportunity exists)
            ${PYEXEC} -m pip wheel -w "${OPENCV_PREFIX}/wheels" "${OPENCV_SRC}" || echo "Could not wheel OpenCV via pip; wheel may not be available"
        else
            echo "No suitable python executable found to build OpenCV wheel"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
cleanup() {
    echo "Cleaning up build directory..."
    rm -rf "${OPENCV_SRC}" || true
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    install_dependencies
    fetch_opencv
    configure_opencv
    build_opencv
    install_opencv
    cleanup
    
    echo "OpenCV ${OPENCV_VERSION} installed successfully to ${OPENCV_PREFIX}"
    echo "Libraries:"
    ls -la "${OPENCV_PREFIX}/lib" 2>/dev/null | head -20 || echo "Could not list libraries"
    
    if [ "${WITH_PYTHON}" = "true" ]; then
        echo ""
        echo "Python bindings:"
        python3 -c "import cv2; print('OpenCV version:', cv2.__version__)" 2>/dev/null || echo "Could not import cv2"
    fi
}

main "$@"
