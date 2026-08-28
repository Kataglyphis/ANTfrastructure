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
            # RV1 (2026-08-18): all three exceptions LIFTED — resolute ports now
            # carries libass/libsdl2/libgnutls28 dev for riscv64 (live-verified
            # 2026-08-17). Best-effort like arm64; FFmpeg's configure probes gate
            # each feature, so a ports regression degrades instead of failing.
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
    # The ffmpeg stage is isolated (Dockerfile.media: FROM base AS ffmpeg), so
    # the libwebp-dev opencv/gstreamer install never reached it — "Skipping
    # libwebp: pkg-config cannot resolve libwebp." on all three arches
    # (media-*.log 2026-08-27). No libvmaf counterpart on purpose: Ubuntu ships
    # NO vmaf package in any suite or arch (packages.ubuntu.com name+contents
    # search 2026-08-28), so that probe skip is expected, not a missing install.
    libwebp-dev              # WebP image codec (-dev also ships libwebpmux.pc)
)
for _ff_extra_pkg in "${ffmpeg_extra_feature_packages[@]}"; do
    install_optional_target_packages "${_ff_extra_pkg}"
done

# vid.stab needs BOTH halves, and the shipped 2026-08-27 build had neither on
# the cross arches -- amd64 linked libvidstab, arm64/riscv64 silently did not,
# and FFmpeg dropped --enable-libvidstab without failing anything.
#
#   1. libvidstab-dev for the TARGET. It is available for arm64 and riscv64
#      alike (Candidate 1.1.0-2.1 on both, checked against ubuntu-ports), so
#      the install below is a straightforward retry that also SAYS something
#      when it does not land.
#   2. a libgomp.so DEV SYMLINK for the target. vidstab.pc lists -lgomp, but
#      libgomp1:<arch> ships only libgomp.so.1, and the cross toolchain carries
#      a libgomp for the HOST (/opt/gcc-*/lib64) and none for the target --
#      `aarch64-linux-gnu-gcc -print-search-dirs` shows no target libgomp path
#      at all. Without the symlink the probe's link step dies on
#      "cannot find -lgomp" even once libvidstab-dev IS installed.
#
# Both verified in the real cross-media-arm64 image: installing the dev package
# alone still failed on -lgomp; adding the symlink turned the link green.
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
    # NET1 (2026-08-18): second-URL fallback — videolan canonical, github mirror.
    git clone --branch "${nv_codec_ref}" --depth 1 https://git.videolan.org/git/ffmpeg/nv-codec-headers.git /tmp/nv-codec-headers \
      || { rm -rf /tmp/nv-codec-headers
           git clone --branch "${nv_codec_ref}" --depth 1 https://github.com/FFmpeg/nv-codec-headers.git /tmp/nv-codec-headers; }
    cd /tmp/nv-codec-headers
    make install
    cd -
    rm -rf /tmp/nv-codec-headers
fi
