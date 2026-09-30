#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# FFMPEG_PROBE_DEBUG=1 makes a skipped codec probe print the compiler error behind it.
: "${FFMPEG_PROBE_DEBUG:=0}"
export FFMPEG_PROBE_DEBUG

# Builds FFmpeg from source with every codec this target's probes can link.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../core/common.sh"
media_common_init "${SCRIPT_DIR}"

# The Dockerfile bind-mounts the whole ffmpeg dir, so these siblings are always present.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/ffmpeg-probe-framework.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/ffmpeg-probes-codecs.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/ffmpeg-dnn-backends.sh"
# G2 lives beside 03-media/, mounted per file (never inside the ffmpeg dir mount).
# shellcheck source=../../ort-provenance.sh
source "${SCRIPT_DIR}/../../ort-provenance.sh"

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

: "${FFMPEG_SRC:=${TMPDIR:-/tmp}/ffmpeg-$$}"
: "${FFMPEG_PREFIX:=/opt/ffmpeg}"
: "${FFMPEG_GIT:=https://git.ffmpeg.org/ffmpeg.git}"
: "${FFMPEG_GIT_MIRROR:=https://github.com/FFmpeg/FFmpeg.git}"
: "${BUILD_TYPE:=release}"

echo "build-ffmpeg: src=${FFMPEG_SRC} prefix=${FFMPEG_PREFIX} buildtype=${BUILD_TYPE}"

# Fetch (a tarball, which is reliable in BuildKit)
fetch_ffmpeg() {
    echo "Fetching FFmpeg source from GitHub releases..."
    rm -rf "${FFMPEG_SRC}"
    mkdir -p "${FFMPEG_SRC}"

    # FFMPEG_COMMIT (40-hex SHA) wins over FFMPEG_VERSION (a tag); unset, this tracks master.
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
    # The tarball alone is a single point of failure, so fall back to both git remotes.
    download_and_extract "${tarball_url}" "${FFMPEG_SRC}" 1 || {
        echo "Tarball download failed; falling back to git clone (${FFMPEG_GIT})..." >&2
        rm -rf "${FFMPEG_SRC}"; mkdir -p "${FFMPEG_SRC}"
        git clone --depth 1 --branch "${release_ref}" "${FFMPEG_GIT}" "${FFMPEG_SRC}" \
          || { echo "Canonical clone failed; trying mirror (${FFMPEG_GIT_MIRROR})..." >&2
               rm -rf "${FFMPEG_SRC}"; mkdir -p "${FFMPEG_SRC}"
               git clone --depth 1 --branch "${release_ref}" "${FFMPEG_GIT_MIRROR}" "${FFMPEG_SRC}"; } \
          || die "All FFmpeg sources failed: tarball, ${FFMPEG_GIT}, ${FFMPEG_GIT_MIRROR}"
    }
    cd "${FFMPEG_SRC}"
    echo "FFmpeg version: ${release_ref} (from tarball)"
}

# Configure

# Appends the cross-compilation configure options to the named array.
_ffmpeg_cross_args() {
    local -n _ffca_out="$1"
    if cross_build_is_active; then
        local host_cc

        setup_linux_cross_env
        # The multiarch -L below exposes apt's libstdc++, often the wrong arch or too old for C++ probes, so pin GCC's first.
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
        # The cross GCC ignores the multiarch dirs and LIBRARY_PATH/CPATH, and pkg-config omits that -L, so apt's target codecs need explicit -L/-I.
        local _ma_triplet="${CROSS_TARGET_TRIPLET:-}"
        if [ -z "${_ma_triplet}" ] && command -v cross_target_triplet >/dev/null 2>&1; then
            _ma_triplet="$(cross_target_triplet 2>/dev/null || true)"
        fi
        if [ -n "${_ma_triplet}" ] && [ -d "/usr/lib/${_ma_triplet}" ]; then
            _ffca_out+=("--extra-ldflags=-L/usr/lib/${_ma_triplet} -L/lib/${_ma_triplet}")
            # The cross GCC does not search /usr/include either, where headers like x264.h live.
            _ffca_out+=("--extra-cflags=-I/usr/include -I/usr/include/${_ma_triplet}")
            echo "Cross: added multiarch lib/include dirs for ${_ma_triplet} (-L/-I incl /usr/include) so apt-installed target codecs link"
        fi
        if [ "$(cross_target_arch)" = "riscv64" ]; then
            # RVV assembly uses absolute relocations, so shared libs need text relocations.
            _ffca_out+=("--extra-ldflags=-Wl,-z,notext")
        fi
    fi
}

# Probe-gated core codecs; libx265 is gated separately behind FFMPEG_ENABLE_X265.
_ffmpeg_probe_core_codecs() {
    local -n _ffpcc_out="$1"

    if ffmpeg_probe_pkg_config_feature "libfreetype" "freetype2" "ft2build.h FT_FREETYPE_H" "FT_Init_FreeType"; then
        _ffpcc_out+=("--enable-libfreetype")
    fi

    # drawtext needs harfbuzz for text shaping and fontconfig for font discovery.
    if ffmpeg_probe_pkg_config_feature "libharfbuzz" "harfbuzz" "hb.h" "hb_buffer_create"; then
        _ffpcc_out+=("--enable-libharfbuzz")
    fi
    if ffmpeg_probe_pkg_config_feature "libfontconfig" "fontconfig" "fontconfig/fontconfig.h" "FcInit"; then
        _ffpcc_out+=("--enable-libfontconfig")
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

    if ffmpeg_probe_pkg_config_feature "gnutls" "gnutls" "gnutls/gnutls.h" "gnutls_global_init"; then
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

# DNN backends; each probe exports the _FFMPEG_*_EXTRA_* flags its configure line needs.
_ffmpeg_probe_dnn_backends() {
    local -n _ffpdb_out="$1"

    if ffmpeg_probe_libonnxruntime; then
        _ffpdb_out+=("--enable-libonnxruntime")
        # FFmpeg's onnxruntime check is a bare check_lib, so the paths go through the global extra flags.
        [ -n "${_FFMPEG_ONNX_EXTRA_CFLAGS:-}" ] && _ffpdb_out+=("--extra-cflags=${_FFMPEG_ONNX_EXTRA_CFLAGS}")
        ffmpeg_ort_ldflags_first _ffpdb_out || die "chain ORT -L missing (ffmpeg_probe_libonnxruntime set none)"
        [ -n "${_FFMPEG_ONNX_EXTRA_LIBS:-}" ] && _ffpdb_out+=("--extra-libs=${_FFMPEG_ONNX_EXTRA_LIBS}")
    fi

    # Off by default because the TF C SDK is a large download for one optional backend; ONNX Runtime stays always-on.
    if is_truthy "${FFMPEG_ENABLE_TF:-0}" && ffmpeg_probe_libtensorflow; then
        _ffpdb_out+=("--enable-libtensorflow")
        # FFmpeg's libtensorflow check ignores pkg-config too, so the same global extra flags carry the paths.
        [ -n "${_FFMPEG_TF_EXTRA_CFLAGS:-}" ] && _ffpdb_out+=("--extra-cflags=${_FFMPEG_TF_EXTRA_CFLAGS}")
        [ -n "${_FFMPEG_TF_EXTRA_LDFLAGS:-}" ] && _ffpdb_out+=("--extra-ldflags=${_FFMPEG_TF_EXTRA_LDFLAGS}")
        [ -n "${_FFMPEG_TF_EXTRA_LIBS:-}" ] && _ffpdb_out+=("--extra-libs=${_FFMPEG_TF_EXTRA_LIBS}")
    fi

    if ffmpeg_probe_libopenvino; then
        _ffpdb_out+=("--enable-libopenvino")
    fi
}

# Probe-gated extra codecs and protocols found through pkg-config.
_ffmpeg_probe_extra_pkgconfig_loop() {
    local -n _ffepdl_out="$1"
    # flag|pkg-config spec|headers|symbols; headers and symbols mirror FFmpeg's own configure checks.
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

# These libraries ship no pkg-config file, so they get a direct link probe.
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

    # FFmpeg auto-detects Vulkan, but only an explicit probe is reliable when cross-building.
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
        # No --enable-cuda-nvcc: it needs --enable-nonfree, which with --enable-gpl makes the binary non-redistributable.
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

    local _ff_cc_launcher
    media_compiler_launcher _ff_cc_launcher
    if [ -n "${_ff_cc_launcher}" ]; then
        if cross_build_is_active; then
            _fflc_out+=("--cc=${_ff_cc_launcher} ${CC}")
            _fflc_out+=("--cxx=${_ff_cc_launcher} ${CXX}")
        else
            _fflc_out+=("--cc=${_ff_cc_launcher} gcc")
            _fflc_out+=("--cxx=${_ff_cc_launcher} g++")
        fi
        echo "Using ${_ff_cc_launcher##*/} for faster compilation"
    elif cross_build_is_active; then
        _fflc_out+=("--cc=${CC}")
        _fflc_out+=("--cxx=${CXX}")
    fi
}

configure_ffmpeg() {
    echo "Configuring FFmpeg build..."
    cd "${FFMPEG_SRC}"

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

    # Opt-in because FFmpeg master can fail to compile against x265; when on, the probe still falls back to disabled.
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
    # Resolve -lonnxruntime from config.mak the way ld does, so only the chain ORT can pass.
    local ort_findings
    ort_findings="$(ffmpeg_ort_link_findings ffbuild/config.mak "${_FFMPEG_ONNX_ROOT:-}")"
    [ -z "${ort_findings}" ] || die "FFmpeg links an ONNX Runtime other than the chain: ${ort_findings}"
}

# Build and install
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

    ${SUDO_WRAP} ldconfig || true
}

bundle_sdk_runtime_libs() {
    # The SDK cache mount is gone at runtime and no apt package owns its libs, so every NEEDED only it resolves (and that lib's closure) ships in the prefix.
    local sdk_cache="${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}"

    if [ -d "${sdk_cache}" ]; then
        echo "Scanning ffmpeg NEEDED entries for SDK-cache-only libraries to bundle into ${FFMPEG_PREFIX}/lib ..."
        ensure_sudo_or_die
        ${SUDO_WRAP} mkdir -p "${FFMPEG_PREFIX}/lib"

        local -a queue=()
        local -A seen=()
        local _f _so _src _dep
        while IFS= read -r _f; do
            while IFS= read -r _so; do
                { [ -n "${_so}" ] && [ -z "${seen[${_so}]:-}" ]; } || continue
                seen["${_so}"]=1
                queue+=("${_so}")
            done < <(elf_unresolved_needed "${_f}" "${FFMPEG_PREFIX}/lib" "${FFMPEG_PREFIX}/lib64")
        done < <(
            find "${FFMPEG_PREFIX}/bin" -maxdepth 1 -type f 2>/dev/null
            find "${FFMPEG_PREFIX}/lib" -maxdepth 2 -name '*.so*' -type f 2>/dev/null
        )

        local bundled=0 i=0
        while [ "${i}" -lt "${#queue[@]}" ]; do
            _so="${queue[${i}]}"
            i=$((i + 1))
            # `|| true`: find | head -1 dies of SIGPIPE on several matches; -type l because SDK sonames are usually symlinks.
            _src="$(find "${sdk_cache}" -maxdepth 6 \( -type f -o -type l \) -name "${_so}" 2>/dev/null | head -1 || true)"
            if [ -z "${_src}" ]; then
                echo "  NOTE: ${_so} unresolved and not in the SDK cache; leaving it to the runtime apt manifest / validator" >&2
                continue
            fi
            # -L: a bare symlink would dangle once the cache mount is gone.
            ${SUDO_WRAP} cp -aL "${_src}" "${FFMPEG_PREFIX}/lib/${_so}"
            echo "  BUNDLED: ${_so} (from ${_src%/*})"
            bundled=$((bundled + 1))
            # Walk the bundled lib's own NEEDED so SDK-internal deps ship too.
            while IFS= read -r _dep; do
                { [ -n "${_dep}" ] && [ -z "${seen[${_dep}]:-}" ]; } || continue
                seen["${_dep}"]=1
                queue+=("${_dep}")
            done < <(elf_unresolved_needed "${_src}" "${FFMPEG_PREFIX}/lib" "${FFMPEG_PREFIX}/lib64")
        done

        echo "Bundled ${bundled} SDK runtime .so file(s) into ${FFMPEG_PREFIX}/lib"
        [ "${bundled}" -eq 0 ] || ${SUDO_WRAP} ldconfig || true
    fi

    # With TF on, the bundled libtensorflow.so.2 alone keeps ffmpeg loadable, and no later smoke catches a missing copy.
    if [ -n "${_FFMPEG_TF_EXTRA_LDFLAGS:-}" ]; then
        [ -f "${FFMPEG_PREFIX}/lib/libtensorflow.so.2" ] \
            || die "TensorFlow backend enabled but libtensorflow.so.2 was not bundled into ${FFMPEG_PREFIX}/lib"
    fi
}

emit_runtime_apt_manifest() {
    # Records the apt package behind each linked codec .so, since versioned names (libx264-NNN) cannot be hardcoded; best-effort by design.
    command -v objdump >/dev/null 2>&1 || { echo "objdump unavailable; skip ffmpeg runtime-apt manifest"; return 0; }
    command -v dpkg    >/dev/null 2>&1 || { echo "dpkg unavailable; skip ffmpeg runtime-apt manifest"; return 0; }

    local manifest="${FFMPEG_PREFIX}/runtime-apt-packages.txt" tmp
    tmp="$(mktemp)"
    {
        find "${FFMPEG_PREFIX}/bin" -maxdepth 1 -type f 2>/dev/null
        find "${FFMPEG_PREFIX}/lib" -maxdepth 2 -name '*.so*' -type f 2>/dev/null
    } | while IFS= read -r _f; do
        elf_needed_sonames "${_f}"   # canonical NEEDED walk (01-core/platform.sh, backlog D4)
    done | sort -u | while IFS= read -r _soname; do
        local _path _pkg
        # `|| true` on both: find | head -1 dies of SIGPIPE on several matches and dpkg -S exits 1 for unowned files.
        _path="$(find /usr/lib /lib -maxdepth 3 -name "${_soname}" 2>/dev/null | head -1 || true)"
        [ -n "${_path}" ] || continue
        case "${_path}" in /opt/*) continue ;; esac   # our own payload, not apt
        _pkg="$(dpkg -S "${_path}" 2>/dev/null | head -1 | cut -d: -f1 || true)"
        # `|| :` so an empty _pkg on the last soname does not end the loop with status 1.
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

# Smoke test
smoke_test_ffmpeg() {
    echo ""
    echo "=== FFmpeg smoke test ==="
    local ffmpeg_bin="${FFMPEG_PREFIX}/bin/ffmpeg"
    if [ ! -x "${ffmpeg_bin}" ]; then
        echo "FAIL: ffmpeg binary not found at ${ffmpeg_bin}"
        return 1
    fi

    # The build sandbox's loader path lacks libav*.so and GCC's libstdc++; if ffmpeg still cannot run, smoke-media.sh at the package stage decides.
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

    # One check per feature so a miss shows in the log; only "none linked" fails, as these are best-effort per-arch packages.
    echo "  Enabled backends:"
    local buildconf feat linked=0
    buildconf="$("${ffmpeg_bin}" -hide_banner -buildconf 2>/dev/null || true)"
    for feat in libonnxruntime libtensorflow libopenvino libwebp libvmaf nvenc nvdec cuda cuvid; do
        if printf '%s\n' "${buildconf}" | grep -q -- "--enable-${feat}"; then
            echo "    ${feat}: YES"
            linked=$((linked + 1))
        else
            echo "    ${feat}: no"
        fi
    done
    if [ "${linked}" -eq 0 ]; then
        echo "    FAIL: none of the DNN/CUDA/media backends were linked"
        failures=$((failures + 1))
    fi

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

# Main
main() {
    local _ff_stamp="${FFMPEG_PREFIX}/.ffmpeg_version_stamp"
    local _arch

    _arch="${TARGET_ARCH:-${TARGETARCH:-$(uname -m)}}"

    # Compare normalized names: _arch is Debian-style (amd64) while uname -m says x86_64.
    local _is_native=0
    [ "$(arch_normalize "${_arch}")" = "$(arch_normalize "$(uname -m)")" ] && _is_native=1

    # Cross-compiled binaries cannot run on the build host.
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
    # G2: the tree, config.mak and config.log hold the chain ORT only; a pass stamps the prefix for G1.
    ort_assert_chain_only ffmpeg --stamp "${FFMPEG_PREFIX}/ort-provenance/ffmpeg.json" --chain "${_FFMPEG_ONNX_ROOT:-}" \
        --tree "${FFMPEG_SRC}" --record "${FFMPEG_SRC}/ffbuild/config.mak" --log "${FFMPEG_SRC}/ffbuild/config.log" \
        || die "FFmpeg's build inputs reach an ONNX Runtime other than the chain's"
    # `|| true` keeps the scan best-effort; its TF assert still exits hard.
    bundle_sdk_runtime_libs || true
    # A manifest problem must never fail a build that already succeeded.
    emit_runtime_apt_manifest || true

    # Strip after bundling so the SDK libs are stripped too; best-effort, MEDIA_STRIP=0 disables it.
    declare -F strip_media_prefixes >/dev/null 2>&1 && strip_media_prefixes "${FFMPEG_PREFIX}" || true

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
