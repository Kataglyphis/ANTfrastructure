#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# build-ffmpeg.sh - Build and install latest FFmpeg from source
# ==============================================================================
# This script fetches the latest stable FFmpeg release and builds it with
# commonly used codecs and features enabled.
#
# Defaults can be overridden via environment variables.
# ==============================================================================

# Defaults (can be overridden via env vars)
: "${FFMPEG_SRC:=/tmp/ffmpeg}"
: "${FFMPEG_PREFIX:=/opt/ffmpeg}"
: "${FFMPEG_GIT:=https://git.ffmpeg.org/ffmpeg.git}"
: "${BUILD_TYPE:=release}"
: "${NPROC:=$(nproc)}"

echo "build-ffmpeg: src=${FFMPEG_SRC} prefix=${FFMPEG_PREFIX} buildtype=${BUILD_TYPE}"

# ------------------------------------------------------------------------------
# Install build dependencies
# ------------------------------------------------------------------------------
install_dependencies() {
    echo "Dependencies should be installed prior to running this script."
}

# ------------------------------------------------------------------------------
# Fetch latest FFmpeg source
# ------------------------------------------------------------------------------
fetch_ffmpeg() {
    echo "Fetching latest FFmpeg source..."
    
    if [ -d "${FFMPEG_SRC}/.git" ]; then
        echo "Updating existing FFmpeg checkout..."
        cd "${FFMPEG_SRC}"
        git fetch --tags || true
    else
        rm -rf "${FFMPEG_SRC}"
        git clone "${FFMPEG_GIT}" "${FFMPEG_SRC}" || { echo "Failed cloning FFmpeg"; exit 1; }
        cd "${FFMPEG_SRC}"
    fi
    
    # Get the latest release tag (stable version)
    LATEST_TAG=$(git tag -l 'n*' | grep -E '^n[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V | tail -n1)
    
    if [ -z "${LATEST_TAG}" ]; then
        echo "Warning: Could not find latest release tag, using master branch"
        git checkout master
    else
        echo "Checking out latest stable release: ${LATEST_TAG}"
        git checkout "${LATEST_TAG}"
    fi
    
    echo "FFmpeg version: $(git describe --tags 2>/dev/null || echo 'unknown')"
}

# ------------------------------------------------------------------------------
# Configure FFmpeg build
# ------------------------------------------------------------------------------
configure_ffmpeg() {
    echo "Configuring FFmpeg build..."
    cd "${FFMPEG_SRC}"
    
    # Build configure options array
    local configure_opts=(
        "--prefix=${FFMPEG_PREFIX}"
        "--enable-gpl"
        "--enable-nonfree"
        "--enable-version3"
        "--enable-shared"
        "--enable-pic"
        "--disable-static"
        "--disable-debug"
        "--disable-doc"
        "--enable-libass"
        "--enable-libfreetype"
        "--enable-libmp3lame"
        "--enable-libopus"
        "--enable-libvorbis"
        "--enable-libvpx"
        "--enable-libx264"
        "--enable-libx265"
        "--enable-gnutls"
    )
    
    # Optional codecs - add if libraries are available
    if pkg-config --exists fdk-aac 2>/dev/null; then
        configure_opts+=("--enable-libfdk-aac")
    fi
    
    if pkg-config --exists aom 2>/dev/null; then
        configure_opts+=("--enable-libaom")
    fi
    
    if pkg-config --exists dav1d 2>/dev/null; then
        configure_opts+=("--enable-libdav1d")
    fi
    
    if pkg-config --exists SvtAv1Enc 2>/dev/null; then
        configure_opts+=("--enable-libsvtav1")
    fi
    
    # Hardware acceleration (if available)
    if pkg-config --exists libva 2>/dev/null; then
        configure_opts+=("--enable-vaapi")
    fi
    
    if pkg-config --exists vdpau 2>/dev/null; then
        configure_opts+=("--enable-vdpau")
    fi
    
    # NVIDIA Hardware acceleration
    if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
        echo "Enabling NVIDIA CUDA and NVENC/NVDEC support in FFmpeg..."
        configure_opts+=("--enable-nvenc")
        configure_opts+=("--enable-nvdec")
        configure_opts+=("--enable-cuvid")
        configure_opts+=("--enable-ffnvcodec")
        configure_opts+=("--enable-cuda-nvcc")
        
        # Explicitly pass CUDA include and lib directories so FFmpeg can find CUDA headers
        CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
        configure_opts+=("--extra-cflags=-I${CUDA_HOME}/include")
        configure_opts+=("--extra-ldflags=-L${CUDA_HOME}/lib64")
    fi
    
    ./configure "${configure_opts[@]}" || { echo "FFmpeg configure failed"; exit 1; }
}

# ------------------------------------------------------------------------------
# Build and install FFmpeg
# ------------------------------------------------------------------------------
build_ffmpeg() {
    echo "Building FFmpeg with ${NPROC} parallel jobs..."
    cd "${FFMPEG_SRC}"
    
    make -j"${NPROC}" || { echo "FFmpeg build failed"; exit 1; }
}

install_ffmpeg() {
    echo "Installing FFmpeg to ${FFMPEG_PREFIX}..."
    cd "${FFMPEG_SRC}"
    
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
        ldconfig || true 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
cleanup() {
    echo "Cleaning up build directory..."
    rm -rf "${FFMPEG_SRC}" || true
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    # Check if FFmpeg is already available at desired version
    if command -v ffmpeg >/dev/null 2>&1; then
        INSTALLED_VERSION=$(ffmpeg -version 2>/dev/null | head -n1 | awk '{print $3}')
        echo "FFmpeg ${INSTALLED_VERSION} already installed"
        
        # Continue with build to ensure we have latest
    fi
    
    install_dependencies
    fetch_ffmpeg
    configure_ffmpeg
    build_ffmpeg
    install_ffmpeg
    cleanup
    
    echo "FFmpeg installed successfully to ${FFMPEG_PREFIX}"
    echo "Version: $(${FFMPEG_PREFIX}/bin/ffmpeg -version 2>/dev/null | head -n1 || echo 'unknown')"
}

main "$@"
