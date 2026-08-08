#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Optional diagnostic: capture the compiler stderr of failed codec probes so
# skips print WHY (header not found, etc.). Off by default; set
# FFMPEG_PROBE_DEBUG=1 in the environment to re-enable when investigating a skip.
: "${FFMPEG_PROBE_DEBUG:=0}"
export FFMPEG_PROBE_DEBUG

# ==============================================================================
# build-ffmpeg.sh - Build and install latest FFmpeg from source
# ==============================================================================
# This script fetches the latest stable FFmpeg release and builds it with
# commonly used codecs and features enabled.
#
# Defaults can be overridden via environment variables.
#
# Build Acceleration:
#   USE_CCACHE=true     Enable ccache for faster rebuilds (default: true)
#   USE_LLD=true        Use lld linker for faster linking (default: true)
# ==============================================================================

# Source shared modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../core/common.sh"
media_common_init "${SCRIPT_DIR}"

# Sourced sibling modules (same directory; the Dockerfile bind-mounts the whole
# ffmpeg dir, so these files are always present next to this script).
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/ffmpeg-probe-framework.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/ffmpeg-probes-codecs.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/ffmpeg-dnn-backends.sh"

case "${1:-}" in
  -h|--help)
    echo "Usage: $0"
    echo ""
    echo "Build and install FFmpeg from source with common codecs enabled."
    echo ""
    echo "Environment:"
    echo "  FFMPEG_PREFIX  Install prefix (default: /opt/ffmpeg)"
    echo "  FFMPEG_SRC     Source checkout dir (default: /tmp/ffmpeg-\$\$)"
    echo "  NPROC          Parallel jobs (default: auto with memory cap)"
    echo "  USE_CCACHE     Enable ccache (default: true)"
    echo "  USE_LLD        Use lld linker (default: true)"
    exit 0
    ;;
esac

NPROC="$(media_jobs)"

# Defaults (can be overridden via env vars)
: "${FFMPEG_SRC:=${TMPDIR:-/tmp}/ffmpeg-$$}"
: "${FFMPEG_PREFIX:=/opt/ffmpeg}"
: "${FFMPEG_GIT:=https://git.ffmpeg.org/ffmpeg.git}"
: "${FFMPEG_GIT_MIRROR:=https://github.com/FFmpeg/FFmpeg.git}"
: "${BUILD_TYPE:=release}"

echo "build-ffmpeg: src=${FFMPEG_SRC} prefix=${FFMPEG_PREFIX} buildtype=${BUILD_TYPE}"

# ------------------------------------------------------------------------------
# Fetch FFmpeg source — download latest release tarball (reliable in BuildKit)
# ------------------------------------------------------------------------------
fetch_ffmpeg() {
    echo "Fetching FFmpeg source from GitHub releases..."
    rm -rf "${FFMPEG_SRC}"
    mkdir -p "${FFMPEG_SRC}"

    # Track a branch ("master", default = bleeding edge) or pin reproducibly:
    # set FFMPEG_COMMIT to a 40-hex SHA (immutable GitHub archive) or
    # FFMPEG_VERSION to a release tag. FFMPEG_COMMIT wins when set.
    local release_ref="${FFMPEG_COMMIT:-${FFMPEG_VERSION:-master}}"

    local tarball_url
    case "${release_ref}" in
      main|master|develop) tarball_url="https://github.com/FFmpeg/FFmpeg/archive/refs/heads/${release_ref}.tar.gz" ;;
      *)
        if [[ "${release_ref}" =~ ^[0-9a-f]{40}$ ]]; then
          # Immutable commit archive (codeload) -> reproducible.
          tarball_url="https://github.com/FFmpeg/FFmpeg/archive/${release_ref}.tar.gz"
        else
          tarball_url="https://github.com/FFmpeg/FFmpeg/archive/refs/tags/${release_ref}.tar.gz"
        fi
        ;;
    esac
    echo "Downloading FFmpeg ${release_ref} from ${tarball_url}..."
    download_and_extract "${tarball_url}" "${FFMPEG_SRC}" 1 || {
        die "Tarball download failed for ${tarball_url}"
    }
    cd "${FFMPEG_SRC}"
    echo "FFmpeg version: ${release_ref} (from tarball)"
}

# ------------------------------------------------------------------------------
# Configure FFmpeg build
# ------------------------------------------------------------------------------

# Append cross-compilation configure opts (arch, cross-prefix, sysroot,
# multiarch lib/include dirs, riscv64 SDL/text-rels workarounds).
_ffmpeg_cross_args() {
    local -n _ffca_out="$1"
    if cross_build_is_active; then
        local host_cc

        setup_linux_cross_env
        # The -L/usr/lib/<triplet> flags below (and the probes' own -L) expose the
        # apt/Ports libstdc++ there, which is often the wrong arch or missing newer
        # GLIBCXX symbols — any C++ probe/link (libopenmpt, onnx, …) then fails and,
        # for an explicitly-enabled feature, hard-aborts configure. Pin it to GCC's
        # target-arch superset first. Best-effort; no-op on native.
        if command -v pin_target_libstdcxx >/dev/null 2>&1; then
            pin_target_libstdcxx "$(cross_target_arch)" || true
        fi
        host_cc="$(resolve_ffmpeg_host_compiler)"
        if [ -n "${host_cc}" ]; then
            host_cc="$(prepare_ffmpeg_host_compiler_wrapper "${host_cc}")"
        fi
        _ffca_out+=(
            "--arch=$(cross_target_arch)"
            "--target-os=linux"
            "--enable-cross-compile"
            "--cross-prefix=${CROSS_TARGET_TRIPLET}-"
            "--pkg-config=pkg-config"
        )
        if [ -n "${host_cc}" ]; then
            _ffca_out+=("--host-cc=${host_cc}")
            echo "Using native host C compiler for FFmpeg build tools: ${host_cc}"
        fi
        _ffca_out+=("--extra-cflags=--sysroot=/")
        _ffca_out+=("--extra-ldflags=--sysroot=/")
        # The custom cross-GCC with --sysroot=/ does NOT search the Debian
        # multiarch dirs (/usr/lib/<triplet>, /usr/include/<triplet>) where apt
        # installs the :<arch> target dev packages, and it does NOT honor
        # LIBRARY_PATH/CPATH (verified empirically — only explicit -L/-I work).
        # pkg-config also omits -L for that libdir (treats it as a system path).
        # Without this, every apt-installed target codec (openjpeg, x264, opus,
        # …) fails to link and gets dropped. Pass the multiarch dirs explicitly
        # to FFmpeg's own configure/link (the probe adds the same -L/-I itself)
        # so we build with the MAXIMUM set of target libraries.
        local _ma_triplet="${CROSS_TARGET_TRIPLET:-}"
        if [ -z "${_ma_triplet}" ] && command -v cross_target_triplet >/dev/null 2>&1; then
            _ma_triplet="$(cross_target_triplet 2>/dev/null || true)"
        fi
        if [ -n "${_ma_triplet}" ] && [ -d "/usr/lib/${_ma_triplet}" ]; then
            _ffca_out+=("--extra-ldflags=-L/usr/lib/${_ma_triplet} -L/lib/${_ma_triplet}")
            # -I/usr/include is required too: the custom cross-GCC does not search
            # it by default, so headers like x264.h (in /usr/include, not the
            # triplet dir) are otherwise invisible to FFmpeg's own compiles.
            _ffca_out+=("--extra-cflags=-I/usr/include -I/usr/include/${_ma_triplet}")
            echo "Cross: added multiarch lib/include dirs for ${_ma_triplet} (-L/-I incl /usr/include) so apt-installed target codecs link"
        fi
        if [ "$(cross_target_arch)" = "riscv64" ]; then
            # Avoid cross-detecting host SDL when the target SDL dev package is unavailable.
            _ffca_out+=("--disable-sdl2" "--disable-ffplay")
            # RVV assembly uses absolute relocations; allow text rels in shared libs
            _ffca_out+=("--extra-ldflags=-Wl,-z,notext")
        fi
    fi
}

# Append probe-gated core codec/feature flags (freetype, mp3lame, opus, vorbis,
# vpx, x264, gnutls, libass, aom, dav1d, svtav1, webp, vmaf). Each is enabled
# only when its probe (declared in ffmpeg-probes-codecs.sh / -framework.sh) finds
# the matching pkg-config/lib/header/symbol.
#
# NOTE: libx265 (HEVC encode) is handled separately below, gated behind
# FFMPEG_ENABLE_X265 (default off), not in this always-on core-codec probe list.
_ffmpeg_probe_core_codecs() {
    local -n _ffpcc_out="$1"

    if ffmpeg_probe_pkg_config_feature "libfreetype" "freetype2" "ft2build.h FT_FREETYPE_H" "FT_Init_FreeType"; then
        _ffpcc_out+=("--enable-libfreetype")
    fi

    if ffmpeg_probe_libmp3lame; then
        _ffpcc_out+=("--enable-libmp3lame")
    fi

    if ffmpeg_probe_libopus; then
        _ffpcc_out+=("--enable-libopus")
    fi

    if ffmpeg_probe_libvorbis; then
        _ffpcc_out+=("--enable-libvorbis")
    fi

    if ffmpeg_probe_libvpx; then
        _ffpcc_out+=("--enable-libvpx")
    fi

    if ffmpeg_probe_libx264; then
        _ffpcc_out+=("--enable-libx264")
    fi

    # Optional codecs - add if libraries are available
    if cross_build_is_active && [ "$(cross_target_arch)" = "riscv64" ]; then
        echo "Skipping gnutls for riscv64 cross builds because FFmpeg's configure probe does not currently pass in this environment."
    elif ffmpeg_probe_pkg_config_feature "gnutls" "gnutls" "gnutls/gnutls.h" "gnutls_global_init"; then
        _ffpcc_out+=("--enable-gnutls")
    fi

    if ffmpeg_probe_pkg_config_feature "libass" "libass >= 0.11.0" "ass/ass.h" "ass_library_init"; then
        _ffpcc_out+=("--enable-libass")
    fi

    if ffmpeg_probe_pkg_config_feature "libaom" "aom >= 2.0.0" "aom/aom_codec.h" "aom_codec_version"; then
        _ffpcc_out+=("--enable-libaom")
    fi

    if ffmpeg_probe_pkg_config_feature "libdav1d" "dav1d >= 1.0.0" "dav1d/dav1d.h" "dav1d_version"; then
        _ffpcc_out+=("--enable-libdav1d")
    fi

    if ffmpeg_probe_pkg_config_feature "libsvtav1" "SvtAv1Enc >= 0.9.0" "EbSvtAv1Enc.h" "svt_av1_enc_init_handle"; then
        _ffpcc_out+=("--enable-libsvtav1")
    fi

    # Image codecs
    if ffmpeg_probe_pkg_config_feature "libwebp" "libwebp" "webp/decode.h" "WebPGetDecoderVersion"; then
        _ffpcc_out+=("--enable-libwebp")
    fi

    # Video quality metrics (if installed)
    if ffmpeg_probe_pkg_config_feature "libvmaf" "libvmaf" "libvmaf/libvmaf.h" "vmaf_version"; then
        _ffpcc_out+=("--enable-libvmaf")
    fi
}

# Append DNN backend flags (onnxruntime, tensorflow, openvino). Each probe
# also exports _FFMPEG_ONNX_EXTRA_* env used by the onnxruntime configure line.
_ffmpeg_probe_dnn_backends() {
    local -n _ffpdb_out="$1"

    if ffmpeg_probe_libonnxruntime; then
        _ffpdb_out+=("--enable-libonnxruntime")
        # FFmpeg's onnxruntime check is a bare check_lib, so feed the header/lib
        # paths through the global extra flags (see ffmpeg_probe_libonnxruntime).
        [ -n "${_FFMPEG_ONNX_EXTRA_CFLAGS:-}" ] && _ffpdb_out+=("--extra-cflags=${_FFMPEG_ONNX_EXTRA_CFLAGS}")
        [ -n "${_FFMPEG_ONNX_EXTRA_LDFLAGS:-}" ] && _ffpdb_out+=("--extra-ldflags=${_FFMPEG_ONNX_EXTRA_LDFLAGS}")
        [ -n "${_FFMPEG_ONNX_EXTRA_LIBS:-}" ] && _ffpdb_out+=("--extra-libs=${_FFMPEG_ONNX_EXTRA_LIBS}")
    fi

    # Deep Neural Network backends (always try; skip if SDK not available)
    if ffmpeg_probe_libtensorflow; then
        _ffpdb_out+=("--enable-libtensorflow")
    fi

    if ffmpeg_probe_libopenvino; then
        _ffpdb_out+=("--enable-libopenvino")
    fi
}

# Run the table-driven extra-pkgconfig probe loop (theora/openjpeg/speex/soxr/
# zimg/opencore-amr/srt/ssh/rav1e/vidstab/openmpt/gme/mysofa/bluray/rsvg).
_ffmpeg_probe_extra_pkgconfig_loop() {
    local -n _ffepdl_out="$1"
    # ------------------------------------------------------------------
    # Extra optional codecs / protocols (max-feature expansion).
    # Each entry is probe-gated: "flag|pkg-config spec|headers|symbols".
    # If the library isn't present/linkable for this arch, the feature is
    # simply not enabled and the build still succeeds. Symbols/headers mirror
    # FFmpeg's own configure checks to minimise false positives.
    # ------------------------------------------------------------------
    local _ff_extra_pkgconfig=(
        "--enable-libtheora|theoraenc theoradec|theora/theoraenc.h|th_encode_alloc"
        "--enable-libopenjpeg|libopenjp2 >= 2.1.0|openjpeg.h|opj_version"
        "--enable-libspeex|speex|speex/speex_header.h|speex_lib_get_mode"
        "--enable-libsoxr|soxr|soxr.h|soxr_create"
        "--enable-libzimg|zimg >= 2.7.0|zimg.h|zimg_get_api_version"
        "--enable-libopencore-amrnb|opencore-amrnb|opencore-amrnb/interf_dec.h|Decoder_Interface_init"
        "--enable-libopencore-amrwb|opencore-amrwb|opencore-amrwb/dec_if.h|D_IF_init"
        "--enable-libsrt|srt >= 1.3.0|srt/srt.h|srt_socket"
        "--enable-libssh|libssh >= 0.6.0|libssh/sftp.h|sftp_init"
        "--enable-librav1e|rav1e >= 0.4.0|rav1e.h|rav1e_context_new"
        "--enable-libvidstab|vidstab >= 0.98|vid.stab/libvidstab.h|vsMotionDetectInit"
        "--enable-libopenmpt|libopenmpt >= 0.2.6557|libopenmpt/libopenmpt.h|openmpt_module_create"
        "--enable-libgme|libgme|gme/gme.h|gme_new_emu"
        "--enable-libmysofa|libmysofa|mysofa.h|mysofa_load"
        "--enable-libbluray|libbluray >= 0.6.0|libbluray/bluray.h|bd_open"
        "--enable-librsvg|librsvg-2.0 >= 2.36.1|librsvg-2.0/librsvg/rsvg.h|rsvg_handle_new"
    )
    local _ff_feat _ff_flag _ff_pkg _ff_hdrs _ff_syms
    for _ff_feat in "${_ff_extra_pkgconfig[@]}"; do
        IFS='|' read -r _ff_flag _ff_pkg _ff_hdrs _ff_syms <<<"${_ff_feat}"
        if ffmpeg_probe_pkg_config_feature "${_ff_flag}" "${_ff_pkg}" "${_ff_hdrs}" "${_ff_syms}"; then
            _ffepdl_out+=("${_ff_flag}")
        fi
    done
}

# Run the table-driven extra-link probe loop (twolame/gsm/xvid — libraries that
# ship no pkg-config file, so we use a direct link probe instead).
_ffmpeg_probe_extra_link_loop() {
    local -n _ffpell_out="$1"
    local _ff_extra_link=(
        "--enable-libtwolame|twolame.h|twolame_init|-ltwolame"
        "--enable-libgsm|gsm/gsm.h|gsm_create|-lgsm"
        "--enable-libxvid|xvid.h|xvid_global|-lxvidcore"
    )
    local _ff_feat _ff_flag _ff_hdrs _ff_syms _ff_libs
    for _ff_feat in "${_ff_extra_link[@]}"; do
        IFS='|' read -r _ff_flag _ff_hdrs _ff_syms _ff_libs <<<"${_ff_feat}"
        if ffmpeg_probe_library_feature "${_ff_flag}" "${_ff_hdrs}" "${_ff_syms}" "${_ff_libs}"; then
            _ffpell_out+=("${_ff_flag}")
        fi
    done
}

# Append hardware-acceleration opts (vaapi, vdpau, vulkan, NVIDIA CUDA SDK).
_ffmpeg_hwaccel_args() {
    local -n _ffha_out="$1"

    if ffmpeg_probe_pkg_config_feature "vaapi" "libva >= 0.35.0" "va/va.h" "vaInitialize"; then
        _ffha_out+=("--enable-vaapi")
    fi

    if ffmpeg_probe_vdpau; then
        _ffha_out+=("--enable-vdpau")
    fi

    # Vulkan HW acceleration — auto-detected by FFmpeg's configure but also
    # explicitly enabled via pkg-config probe for cross-build reliability.
    if ffmpeg_probe_pkg_config_feature "vulkan" "vulkan" "vulkan/vulkan.h" "vkCreateInstance"; then
        _ffha_out+=("--enable-vulkan")
    fi

    # NVIDIA Hardware acceleration — auto-probe for CUDA SDK
    CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
    if [ -f "${CUDA_HOME}/include/cuda.h" ] && [ -d "${CUDA_HOME}/lib64" ]; then
        echo "NVIDIA CUDA SDK detected at ${CUDA_HOME}. Enabling NVENC/NVDEC/CUDA..."
        _ffha_out+=("--enable-nvenc")
        _ffha_out+=("--enable-nvdec")
        _ffha_out+=("--enable-cuvid")
        _ffha_out+=("--enable-ffnvcodec")
        _ffha_out+=("--enable-cuda-nvcc")
        _ffha_out+=("--extra-cflags=-I${CUDA_HOME}/include")
        _ffha_out+=("--extra-ldflags=-L${CUDA_HOME}/lib64")
    elif [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
        echo "ENABLE_NVIDIA=true but CUDA SDK not found at ${CUDA_HOME}. Skipping NVIDIA acceleration."
    fi
}

# Append lld linker + ccache/cc configuration.
_ffmpeg_linker_ccache_args() {
    local -n _fflc_out="$1"

    # Use lld linker for faster linking if available
    if command -v ld.lld >/dev/null 2>&1 && [ "${USE_LLD:-true}" != "false" ]; then
        _fflc_out+=("--extra-ldflags=-fuse-ld=lld")
        echo "Using lld linker for faster linking"
    fi

    # Use ccache if available
    if command -v ccache >/dev/null 2>&1 && { case "${USE_CCACHE:-true}" in 0|false|FALSE|no|NO|off|OFF) false ;; *) true ;; esac; }; then
        if cross_build_is_active; then
            _fflc_out+=("--cc=ccache ${CC}")
            _fflc_out+=("--cxx=ccache ${CXX}")
        else
            _fflc_out+=("--cc=ccache gcc")
            _fflc_out+=("--cxx=ccache g++")
        fi
        echo "Using ccache for faster compilation"
    elif cross_build_is_active; then
        _fflc_out+=("--cc=${CC}")
        _fflc_out+=("--cxx=${CXX}")
    fi
}

configure_ffmpeg() {
    echo "Configuring FFmpeg build..."
    cd "${FFMPEG_SRC}"

    # Build configure options array
    local configure_opts=(
        "--prefix=${FFMPEG_PREFIX}"
        "--enable-gpl"
        "--enable-version3"
        "--enable-shared"
        "--enable-pic"
        "--disable-static"
        "--disable-debug"
        "--disable-doc"
    )

    _ffmpeg_cross_args configure_opts

    # Workaround for glibc 2.43+ __pthread_cond_timedwait64 symbol (Clang sets __USE_TIME_BITS64)
    configure_opts+=("--extra-cflags=-U__USE_TIME_BITS64")

    _ffmpeg_probe_core_codecs configure_opts
    _ffmpeg_probe_dnn_backends configure_opts
    _ffmpeg_probe_extra_pkgconfig_loop configure_opts
    _ffmpeg_probe_extra_link_loop configure_opts
    _ffmpeg_hwaccel_args configure_opts
    _ffmpeg_linker_ccache_args configure_opts

    # libx265 (HEVC encoding). Historically force-disabled because FFmpeg master
    # could fail to COMPILE against a bleeding-edge source-built x265. libx265-dev
    # (a stable distro release) is installed on all arches, so it's now gated
    # behind FFMPEG_ENABLE_X265: default off keeps the exact prior behavior
    # (--disable-libx265); when set it's probe-gated like every other codec, so a
    # genuinely-absent/unusable x265 still falls back to disabled rather than
    # hard-failing configure.
    if is_truthy "${FFMPEG_ENABLE_X265:-0}" && ffmpeg_probe_libx265; then
        configure_opts+=("--enable-libx265")
    else
        configure_opts+=("--disable-libx265")
    fi

    if ! ./configure "${configure_opts[@]}"; then
        echo "FFmpeg configure failed"
        if [ -f "ffbuild/config.log" ]; then
            echo "Last 200 lines of ffbuild/config.log:"
            tail -n 200 "ffbuild/config.log" || true
        fi
        exit 1
    fi
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

    ensure_sudo_or_die
    ${SUDO_WRAP} make install

    # Update ld cache
    ${SUDO_WRAP} ldconfig || true
}

emit_runtime_apt_manifest() {
    # Record the EXACT apt packages that provide the external codec .so libraries
    # this FFmpeg build actually links, so the runtime image can install exactly
    # them -- no soname guessing (the base is Ubuntu ${UBUNTU_VERSION:-26.04}, whose
    # versioned package names, e.g. libx264-NNN, we cannot hardcode reliably).
    #
    # Why this exists: /opt/ffmpeg is source-built against a broad, PROBE-GATED set
    # of apt -dev codec libs (see ffmpeg/install-deps.sh). Every enabled codec
    # becomes a NEEDED .so on libavcodec/ffmpeg; if its runtime package is absent
    # from the final image, `ffmpeg` dies at load (observed 2026-07-11:
    # `libopencore-amrwb.so.0: cannot open shared object file`). Prior to this the
    # runtime lib list was hand-maintained and silently drifted.
    #
    # Build and runtime share the same base, so names resolved here are valid there.
    # objdump reads NEEDED from foreign-arch ELF too, and cross builds keep target
    # libs under /usr/lib/<triplet>/ where `find` locates them; `dpkg -S` maps the
    # file to its package and we strip any :arch qualifier. Entirely best-effort --
    # never fail the ffmpeg build over manifest generation.
    command -v objdump >/dev/null 2>&1 || { echo "objdump unavailable; skip ffmpeg runtime-apt manifest"; return 0; }
    command -v dpkg    >/dev/null 2>&1 || { echo "dpkg unavailable; skip ffmpeg runtime-apt manifest"; return 0; }

    local manifest="${FFMPEG_PREFIX}/runtime-apt-packages.txt" tmp
    tmp="$(mktemp)"
    {
        find "${FFMPEG_PREFIX}/bin" -maxdepth 1 -type f 2>/dev/null
        find "${FFMPEG_PREFIX}/lib" -maxdepth 2 -name '*.so*' -type f 2>/dev/null
    } | while IFS= read -r _f; do
        objdump -p "${_f}" 2>/dev/null | awk '/NEEDED/{print $2}'
    done | sort -u | while IFS= read -r _soname; do
        local _path _pkg
        # `|| true` on both: `find | head -1` dies with SIGPIPE (rc 141) when
        # more than one match exists, and `dpkg -S` exits 1 for any file no
        # package owns. Under set -e either kills this while-subshell, pipefail
        # fails the whole pipeline, and the "best-effort" promise above breaks
        # AFTER a successful ffmpeg build.
        _path="$(find /usr/lib /lib -maxdepth 3 -name "${_soname}" 2>/dev/null | head -1 || true)"
        [ -n "${_path}" ] || continue
        case "${_path}" in /opt/*) continue ;; esac   # our own payload, not apt
        _pkg="$(dpkg -S "${_path}" 2>/dev/null | head -1 | cut -d: -f1 || true)"
        # `; :` tail: if _pkg is empty on the LAST soname, a bare AND-list here
        # would make the while exit 1 and abort the pipeline the same way.
        { [ -n "${_pkg}" ] && printf '%s\n' "${_pkg}"; } || :
    done | sort -u > "${tmp}"

    if [ -s "${tmp}" ]; then
        ${SUDO_WRAP} mkdir -p "${FFMPEG_PREFIX}"
        ${SUDO_WRAP} cp "${tmp}" "${manifest}"
        echo "FFmpeg runtime-apt manifest: $(wc -l < "${tmp}") package(s) -> ${manifest}"
        sed 's/^/  /' "${tmp}"
    else
        echo "WARNING: FFmpeg runtime-apt manifest came out EMPTY (objdump/dpkg/find resolution failed?);"
        echo "         the runtime image will fall back to its hardcoded codec-lib list."
    fi
    rm -f "${tmp}"
}

# ------------------------------------------------------------------------------
# Smoke test — verify DNN module and linked backends
# ------------------------------------------------------------------------------
smoke_test_ffmpeg() {
    echo ""
    echo "=== FFmpeg smoke test ==="
    local ffmpeg_bin="${FFMPEG_PREFIX}/bin/ffmpeg"
    if [ ! -x "${ffmpeg_bin}" ]; then
        echo "FAIL: ffmpeg binary not found at ${ffmpeg_bin}"
        return 1
    fi

    # The freshly-built ffmpeg links against its own libav*.so and the source-built
    # GCC's libstdc++ (via the C++ DNN backends), neither of which is on the loader
    # path in the media BUILD sandbox -- ldconfig/ENV are only wired at the package
    # stage. Point LD_LIBRARY_PATH at them so ffmpeg can execute here; if it STILL
    # can't, DEFER (return 0) rather than fail the build -- the authoritative
    # functional test is smoke-media.sh at the package stage (loader-configured
    # runtime env). Before the native-arch fix this smoke was wrongly skipped on
    # amd64, which hid that it was never sandbox-safe (ffmpeg failing to load libs
    # returns 127, and `version=$(... )` propagated that under set -e/pipefail).
    local gcc_libdir
    gcc_libdir="$(dirname "$("${CC:-gcc}" -print-file-name=libstdc++.so.6 2>/dev/null || true)" 2>/dev/null || true)"
    case "${gcc_libdir}" in /*) : ;; *) gcc_libdir="" ;; esac
    export LD_LIBRARY_PATH="${FFMPEG_PREFIX}/lib:${FFMPEG_PREFIX}/lib64${gcc_libdir:+:${gcc_libdir}}${GCC_VERSION:+:/opt/gcc-${GCC_VERSION}/lib64:/opt/gcc-${GCC_VERSION}/lib}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

    if ! "${ffmpeg_bin}" -version >/dev/null 2>&1; then
        echo "  NOTE: ffmpeg present but cannot execute in the build sandbox"
        echo "        (loader/GLIBCXX only wired at the package stage); deferring"
        echo "        functional checks to smoke-media.sh at runtime."
        echo "=== FFmpeg smoke test deferred to package stage (binary installed OK) ==="
        echo ""
        return 0
    fi

    local failures=0

    # Basic version check
    local version
    version="$("${ffmpeg_bin}" -version 2>&1 | head -1 || true)"
    echo "  Version: ${version}"

    # Check DNN module is compiled in
    echo -n "  DNN filter: "
    if "${ffmpeg_bin}" -filters 2>/dev/null | grep -q "dnn"; then
        echo "FOUND"
    else
        echo "FAIL: DNN filter NOT FOUND (check --enable-dnn or native DNN backend)"
        failures=$((failures + 1))
    fi

    # Check enabled backends from configure
    echo "  Enabled backends:"
    local backends
    backends="$("${ffmpeg_bin}" -hide_banner -buildconf 2>/dev/null | grep -E "libonnx|libtensorflow|libopenvino|libwebp|libvmaf|nvenc|nvdec|cuda|cuvid" || true)"
    if [ -n "${backends}" ]; then
        echo "${backends}" | while IFS= read -r line; do echo "    ${line}"; done
    else
        echo "    (none of the DNN/CUDA/media backends were linked)"
        failures=$((failures + 1))
    fi

    # Verify DNN inference filter can accept input
    echo -n "  dnn_processing filter available: "
    if "${ffmpeg_bin}" -hide_banner -filters 2>/dev/null | grep -q "dnn_processing"; then
        echo "YES"
    else
        echo "FAIL: dnn_processing filter NOT available"
        failures=$((failures + 1))
    fi

    echo "=== FFmpeg smoke test complete (${failures} failure(s)) ==="
    echo ""
    [ "${failures}" -eq 0 ]
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
    local _ff_stamp="${FFMPEG_PREFIX}/.ffmpeg_version_stamp"
    local _arch

    _arch="${TARGET_ARCH:-${TARGETARCH:-$(uname -m)}}"

    # "native" = target arch equals the build host. Compare NORMALIZED names:
    # _arch is Debian-named (amd64) while `uname -m` returns x86_64, so a raw
    # string compare wrongly treats a native amd64 build as cross — skipping its
    # smoke test and the already-installed fast-path. arch_normalize() (loaded via
    # media_common_init) maps both sides to a common token (amd64/arm64/riscv64).
    local _is_native=0
    [ "$(arch_normalize "${_arch}")" = "$(arch_normalize "$(uname -m)")" ] && _is_native=1

    # Only run version check / stamp read when the binary is native — cross-compiled
    # binaries cannot execute on the build host.
    if [ "${_is_native}" = "1" ]; then
        if [ -x "${FFMPEG_PREFIX}/bin/ffmpeg" ]; then
            INSTALLED_VERSION=$("${FFMPEG_PREFIX}/bin/ffmpeg" -version 2>/dev/null | head -n1 | awk '{print $3}')
            echo "FFmpeg ${INSTALLED_VERSION} already installed at ${FFMPEG_PREFIX}"
            if [ "${FORCE_REBUILD:-0}" != "1" ]; then
                if [ -f "$_ff_stamp" ] && [ "$(cat "$_ff_stamp")" = "${INSTALLED_VERSION}" ]; then
                    echo "Skipping rebuild (set FORCE_REBUILD=1 to force)"
                    emit_runtime_apt_manifest   # regenerate even on the cache-skip fast-path
                    return 0
                fi
            fi
        fi
    fi

    fetch_ffmpeg
    configure_ffmpeg
    build_ffmpeg
    install_ffmpeg
    # Best-effort by declaration (see its header comment): a manifest problem
    # must never fail an ffmpeg build that already succeeded.
    emit_runtime_apt_manifest || true

    # Only write stamp and run smoke test for native builds
    if [ "${_is_native}" = "1" ]; then
        echo "$(${FFMPEG_PREFIX}/bin/ffmpeg -version 2>/dev/null | head -n1 | awk '{print $3}')" > "$_ff_stamp"
        smoke_test_ffmpeg
        echo "FFmpeg installed successfully to ${FFMPEG_PREFIX}"
        echo "Version: $(${FFMPEG_PREFIX}/bin/ffmpeg -version 2>/dev/null | head -n1 || echo 'unknown')"
    else
        echo "FFmpeg cross-built for ${_arch} (host=$(uname -m)); skipping native smoke test"
        echo "FFmpeg installed successfully to ${FFMPEG_PREFIX}"
    fi
}

main "$@"
