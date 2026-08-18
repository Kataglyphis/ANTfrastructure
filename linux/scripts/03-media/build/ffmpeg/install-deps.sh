#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../core/common.sh"
media_install_deps_init "${SCRIPT_DIR}"

echo "Installing FFmpeg build dependencies..."

install_deps_preamble autoconf automake build-essential cmake git libtool pkg-config texinfo wget yasm nasm


target_packages=(
    libfreetype6-dev
    libmp3lame-dev
    # LOG3 (2026-08-17): headers-only, arch-independent — without it ffmpeg's
    # configure printed "spirv-headers not found, swscale SPIR-V backend
    # unavailable" and silently dropped the backend.
    spirv-headers
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

# ---------------------------------------------------------------------------
# Extra optional codec / protocol libraries — maximize FFmpeg feature coverage.
# Installed one-at-a-time and best-effort: any package unavailable for the
# target arch (e.g. riscv64/arm64 Ubuntu Ports gaps) is skipped without failing
# the build, and build-ffmpeg.sh probe-gates the matching --enable-* flag, so a
# missing library just means that feature is left out for that arch.
# ---------------------------------------------------------------------------
ffmpeg_extra_feature_packages=(
    libtheora-dev            # Theora video
    libopenjp2-7-dev         # JPEG 2000
    libspeex-dev             # Speex speech
    libsoxr-dev              # high-quality audio resampling
    libzimg-dev              # high-quality scaling (zscale)
    libtwolame-dev           # MP2 audio encoder
    libopencore-amrnb-dev    # AMR-NB speech
    libopencore-amrwb-dev    # AMR-WB speech
    libsrt-gnutls-dev        # SRT transport (gnutls flavor to match FFmpeg TLS)
    libssh-dev               # SFTP/SSH protocol
    librav1e-dev             # rav1e AV1 encoder
    libvidstab-dev           # vid.stab stabilization filter
    libopenmpt-dev           # tracker/module audio (MOD/XM/IT/S3M)
    libgme-dev               # game-music-emu (chiptunes)
    libmysofa-dev            # SOFA HRTF (spatial audio)
    libbluray-dev            # Blu-ray navigation
    librsvg2-dev             # SVG rasterization
    libgsm1-dev              # GSM 06.10 speech
    libxvidcore-dev          # Xvid MPEG-4 ASP encoder
)
for _ff_extra_pkg in "${ffmpeg_extra_feature_packages[@]}"; do
    install_optional_target_packages "${_ff_extra_pkg}"
done

if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
    echo "Installing nv-codec-headers for FFmpeg NVIDIA acceleration..."
    nv_codec_ref="${NV_CODEC_HEADERS_REF:-n13.1.15.0}"
    git clone --branch "${nv_codec_ref}" --depth 1 https://git.videolan.org/git/ffmpeg/nv-codec-headers.git /tmp/nv-codec-headers
    cd /tmp/nv-codec-headers
    make install
    cd -
    rm -rf /tmp/nv-codec-headers
fi
