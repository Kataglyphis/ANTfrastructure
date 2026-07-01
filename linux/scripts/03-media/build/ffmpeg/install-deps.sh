#!/usr/bin/env bash
set -euo pipefail

# Load the shared apt/cross helpers, trying the in-container path first and
# falling back to the repo layout for local dev. Fail loudly if none load.
for _dep_env in \
    "/opt/scripts/core/install-deps-preamble.sh" \
    "/opt/scripts/core/cross-env.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../01-core/cross-env.sh"; do
    if [ -f "${_dep_env}" ]; then
        # shellcheck disable=SC1090
        source "${_dep_env}" || { echo "FATAL: cannot load ${_dep_env}" >&2; exit 1; }
        break
    fi
done

echo "Installing FFmpeg build dependencies..."

install_deps_preamble autoconf automake build-essential cmake git libtool pkg-config texinfo wget yasm nasm


target_packages=(
    libfreetype6-dev
    libmp3lame-dev
    libva-dev
    libvdpau-dev
    libvorbis-dev
    libxcb1-dev
    libxcb-shm0-dev
    libxcb-xfixes0-dev
    zlib1g-dev
    libx264-dev
    libx265-dev
    libnuma-dev
    libvpx-dev
    libfdk-aac-dev
    libopus-dev
    libaom-dev
    libdav1d-dev
)

optional_cross_target_packages=()

if is_cross && \
   command -v cross_target_arch >/dev/null 2>&1; then
    case "$(cross_target_arch)" in
        riscv64)
            echo "Skipping libass-dev for riscv64 because Ubuntu Ports cannot satisfy its HarfBuzz/GLib helper dependency chain."
            echo "Skipping libgnutls28-dev for riscv64 because FFmpeg's cross probe does not currently pass in this environment."
            echo "Skipping libsdl2-dev for riscv64 because Ubuntu Ports cannot satisfy its GLib helper dependency chain."
            ;;
        arm64)
            target_packages+=(libgnutls28-dev)
            optional_cross_target_packages+=(libass-dev)
            optional_cross_target_packages+=(libsdl2-dev)
            echo "Installing libass-dev and libsdl2-dev on a best-effort basis for arm64 cross builds because the foreign-arch GLib helper dependency chain is currently inconsistent."
            ;;
        *)
            target_packages+=(libgnutls28-dev)
            target_packages+=(libass-dev)
            target_packages+=(libsdl2-dev)
            ;;
    esac
else
    target_packages+=(libgnutls28-dev)
    target_packages+=(libass-dev)
    target_packages+=(libsdl2-dev)
fi

if is_cross && [ "$(cross_target_arch)" = "riscv64" ]; then
    echo "Installing riscv64 target FFmpeg feature deps on a best-effort basis because Ubuntu Ports currently has partial/broken dependency coverage for several optional codec packages."
    install_optional_target_packages "${target_packages[@]}"
    install_optional_target_packages libsvtav1enc-dev libsvtav1-dev
else
    install_target_packages "${target_packages[@]}"
    install_target_packages libsvtav1enc-dev || install_target_packages libsvtav1-dev || true
fi

if [ "${#optional_cross_target_packages[@]}" -gt 0 ]; then
    install_optional_target_packages "${optional_cross_target_packages[@]}"
fi

if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
    echo "Installing nv-codec-headers for FFmpeg NVIDIA acceleration..."
    local nv_codec_ref="${NV_CODEC_HEADERS_REF:-n12.2.1}"
    git clone --branch "${nv_codec_ref}" --depth 1 https://git.videolan.org/git/ffmpeg/nv-codec-headers.git /tmp/nv-codec-headers
    cd /tmp/nv-codec-headers
    make install
    cd -
    rm -rf /tmp/nv-codec-headers
fi
