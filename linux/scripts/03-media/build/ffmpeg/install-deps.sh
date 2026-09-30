#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../core/common.sh"
media_install_deps_init "${SCRIPT_DIR}"

echo "Installing FFmpeg build dependencies..."

install_deps_preamble autoconf automake build-essential cmake git libtool pkg-config texinfo wget yasm nasm glslang-tools


target_packages=(
    libfreetype-dev
    libmp3lame-dev
    # Without it configure silently drops swscale's SPIR-V backend.
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
    # PulseAudio input/output devices.
    libpulse-dev
)

optional_cross_target_packages=()

if is_cross && \
   command -v cross_target_arch >/dev/null 2>&1; then
    case "$(cross_target_arch)" in
        riscv64)
            # Best-effort: FFmpeg's probes gate each feature, so a ports regression degrades instead of failing.
            optional_cross_target_packages+=(libgnutls28-dev libass-dev libsdl2-dev)
            echo "Installing gnutls/ass/sdl2 dev on a best-effort basis for riscv64 (ports caught up, RV1); FFmpeg probes decide."
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

# One at a time and best-effort: a package missing for this arch only drops its probe-gated feature.
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
    # The ffmpeg stage is isolated, so it needs its own libwebp-dev; Ubuntu ships no vmaf package, so that probe skip is expected.
    libwebp-dev              # WebP image codec (-dev also ships libwebpmux.pc)
    libharfbuzz-dev          # HarfBuzz text shaping (drawtext filter)
    libfontconfig1-dev       # font discovery for drawtext
)
for _ff_extra_pkg in "${ffmpeg_extra_feature_packages[@]}"; do
    install_optional_target_packages "${_ff_extra_pkg}"
done

# vidstab.pc lists -lgomp, but libgomp1:<arch> ships only libgomp.so.1 and the cross toolchain has no target libgomp.
_ffmpeg_ensure_vidstab_linkable() {
    is_cross || return 0
    local _tri _libdir
    _tri="$(cross_target_triplet 2>/dev/null || true)"
    [ -n "${_tri}" ] || return 0
    _libdir="/usr/lib/${_tri}"
    [ -d "${_libdir}" ] || return 0
    if [ ! -e "${_libdir}/libgomp.so" ] && [ -e "${_libdir}/libgomp.so.1" ]; then
        echo "Creating ${_libdir}/libgomp.so -> libgomp.so.1 (libgomp1 ships no dev symlink; the cross toolchain has no target libgomp)"
        ln -sf libgomp.so.1 "${_libdir}/libgomp.so"
    fi
    if [ ! -e "${_libdir}/libvidstab.so" ]; then
        echo "NOTE: ${_libdir}/libvidstab.so still absent after the optional install; --enable-libvidstab will be probe-skipped for this arch"
    fi
}
_ffmpeg_ensure_vidstab_linkable

if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
    echo "Installing nv-codec-headers for FFmpeg NVIDIA acceleration..."
    nv_codec_ref="${NV_CODEC_HEADERS_REF:-n13.1.15.0}"
    # Fall back to the GitHub mirror when videolan is unreachable.
    git clone --branch "${nv_codec_ref}" --depth 1 https://git.videolan.org/git/ffmpeg/nv-codec-headers.git /tmp/nv-codec-headers \
      || { rm -rf /tmp/nv-codec-headers
           git clone --branch "${nv_codec_ref}" --depth 1 https://github.com/FFmpeg/nv-codec-headers.git /tmp/nv-codec-headers; }
    cd /tmp/nv-codec-headers
    make install
    cd -
    rm -rf /tmp/nv-codec-headers
fi
