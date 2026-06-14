#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

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
if [ -f /opt/scripts/media/media-build-preamble.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/media/media-build-preamble.sh
  media_build_preamble_init "${SCRIPT_DIR}"
else
  for helper in \
    "/opt/scripts/core/modules.sh" \
    "${SCRIPT_DIR}/../../01-core/modules.sh"; do
    if [ -f "${helper}" ]; then
      # shellcheck disable=SC1090
      source "${helper}"
      source_modules_framework "${SCRIPT_DIR}"
      break
    fi
  done
  source_module cross-env.sh || true
  source_module compiler-cache.sh && { setup_ccache; setup_lld_linker; } || true
  source_module compiler-resolution.sh || true
fi

if declare -F compute_jobs_with_mem_cap >/dev/null 2>&1; then
  NPROC="$(compute_jobs_with_mem_cap "" 2000)"
else
  NPROC="$(nproc)"
fi

# Defaults (can be overridden via env vars)
: "${FFMPEG_SRC:=${TMPDIR:-/tmp}/ffmpeg-$$}"
: "${FFMPEG_PREFIX:=/opt/ffmpeg}"
: "${FFMPEG_GIT:=https://git.ffmpeg.org/ffmpeg.git}"
: "${FFMPEG_GIT_MIRROR:=https://github.com/FFmpeg/FFmpeg.git}"
: "${BUILD_TYPE:=release}"
: "${NPROC:=${NPROC}}"

echo "build-ffmpeg: src=${FFMPEG_SRC} prefix=${FFMPEG_PREFIX} buildtype=${BUILD_TYPE}"

# ------------------------------------------------------------------------------
# Fetch FFmpeg source — download latest release tarball (reliable in BuildKit)
# ------------------------------------------------------------------------------
fetch_ffmpeg() {
    echo "Fetching FFmpeg source from GitHub releases..."
    rm -rf "${FFMPEG_SRC}"
    mkdir -p "${FFMPEG_SRC}"

    # Use latest stable release tag
    local release_tag="n7.1"

    local tarball_url="https://github.com/FFmpeg/FFmpeg/archive/refs/tags/${release_tag}.tar.gz"
    echo "Downloading FFmpeg ${release_tag} from ${tarball_url}..."
    curl -sL "${tarball_url}" | tar -xzf - -C "${FFMPEG_SRC}" --strip-components=1 || {
        echo "Tarball download failed for ${tarball_url}" >&2
        exit 1
    }
    cd "${FFMPEG_SRC}"
    echo "FFmpeg version: ${release_tag} (from tarball)"
}

# Mirror FFmpeg's own configure probes so optional libraries are only forced on
# when the current compiler, sysroot, and linker can actually use them.
split_shell_words() {
    local -n out_ref="$1"
    local words="${2:-}"

    out_ref=()
    [ -n "${words}" ] || return 0

    # pkg-config emits whitespace-delimited flags that are safe to re-split here.
    # shellcheck disable=SC2206
    out_ref=(${words})
}

ffmpeg_collect_pkg_config_flags() {
    local pkg_spec="$1"
    local mode="$2"
    local pkg

    pkg="${pkg_spec%% *}"
    pkg-config --exists "${pkg_spec}" >/dev/null 2>&1 || return 1
    pkg-config "${mode}" "${pkg}" 2>/dev/null
}

ffmpeg_write_includes() {
    local headers="$1"
    local header
    local -a header_list=()

    split_shell_words header_list "${headers}"
    for header in "${header_list[@]}"; do
        if [[ "${header}" == *.h ]]; then
            printf '#include <%s>\n' "${header}"
        else
            printf '#include %s\n' "${header}"
        fi
    done
}

ffmpeg_probe_compiler() {
    if [ -n "${CC:-}" ]; then
        printf '%s' "${CC}"
    elif command -v gcc >/dev/null 2>&1; then
        printf '%s' "gcc"
    else
        printf '%s' "cc"
    fi
}

resolve_ffmpeg_host_compiler() {
    if command -v resolve_host_compiler_for_lang >/dev/null 2>&1; then
        resolve_host_compiler_for_lang c
        return $?
    fi

    local triplet=""
    local candidate
    local resolved=""

    if command -v resolve_build_gcc_tool >/dev/null 2>&1; then
        resolved="$(resolve_build_gcc_tool gcc 2>/dev/null || true)"
        [ -n "${resolved}" ] || resolved="$(resolve_build_gcc_tool cc 2>/dev/null || true)"
        [ -n "${resolved}" ] && { printf '%s' "${resolved}"; return 0; }
    fi

    if command -v build_deb_multiarch_triplet >/dev/null 2>&1; then
        triplet="$(build_deb_multiarch_triplet)"
    fi

    for candidate in \
        "/usr/bin/${triplet}-gcc" \
        /usr/bin/gcc \
        /usr/bin/cc; do
        [ -x "${candidate}" ] && { printf '%s' "${candidate}"; return 0; }
    done

    command -v gcc 2>/dev/null || command -v cc 2>/dev/null || true
}

prepare_ffmpeg_host_compiler_wrapper() {
    local compiler="$1"

    if command -v prepare_host_compiler_wrapper >/dev/null 2>&1; then
        prepare_host_compiler_wrapper "${compiler}" host-gcc "$(mktemp -d "${FFMPEG_HOST_TOOLCHAIN_DIR:-/tmp/ffmpeg-host-toolchain}.XXXXXX")"
        return $?
    fi

    local wrapper_dir; wrapper_dir="$(mktemp -d "${FFMPEG_HOST_TOOLCHAIN_DIR:-/tmp/ffmpeg-host-toolchain}.XXXXXX")"
    if command -v make_named_host_compiler_wrapper >/dev/null 2>&1; then
        make_named_host_compiler_wrapper "${wrapper_dir}" host-gcc "${compiler}"
        return 0
    fi

    mkdir -p "${wrapper_dir}"
    cat > "${wrapper_dir}/host-gcc" <<EOF
#!/usr/bin/env bash
exec env PATH="/usr/bin:/bin" "${compiler}" -B/usr/bin/ "\$@"
EOF
    chmod +x "${wrapper_dir}/host-gcc"
    printf '%s' "${wrapper_dir}/host-gcc"
}

ffmpeg_try_cpp_condition() {
    local headers="$1"
    local condition="$2"
    local cflags_string="${3:-}"
    local compiler_string probe_dir source_file output_file
    local -a compiler_cmd=()
    local -a cflags=()
    local -a cmd=()

    compiler_string="$(ffmpeg_probe_compiler)"
    split_shell_words compiler_cmd "${compiler_string}"
    split_shell_words cflags "${cflags_string}"

    probe_dir="$(mktemp -d)"
    source_file="${probe_dir}/probe.c"
    output_file="${probe_dir}/probe.o"

    {
        ffmpeg_write_includes "${headers}"
        printf '#if !(%s)\n' "${condition}"
        printf '#error condition failed\n'
        printf '#endif\n'
        printf 'int ffmpeg_probe_condition = 0;\n'
    } > "${source_file}"

    cmd=("${compiler_cmd[@]}")
    if cross_build_is_active; then
        cmd+=("--sysroot=/")
    fi
    cmd+=("${cflags[@]}" "-c" "${source_file}" "-o" "${output_file}")

    if "${cmd[@]}" >/dev/null 2>&1; then
        rm -rf "${probe_dir}"
        return 0
    fi

    rm -rf "${probe_dir}"
    return 1
}

ffmpeg_try_link_probe() {
    local headers="$1"
    local symbols="$2"
    local cflags_string="${3:-}"
    local libs_string="${4:-}"
    local compiler_string probe_dir source_file output_file
    local -a compiler_cmd=()
    local -a cflags=()
    local -a libs=()
    local -a cmd=()
    local -a symbol_list=()

    compiler_string="$(ffmpeg_probe_compiler)"
    split_shell_words compiler_cmd "${compiler_string}"
    split_shell_words cflags "${cflags_string}"
    split_shell_words libs "${libs_string}"
    split_shell_words symbol_list "${symbols}"

    probe_dir="$(mktemp -d)"
    source_file="${probe_dir}/probe.c"
    output_file="${probe_dir}/probe"

    {
        local symbol
        ffmpeg_write_includes "${headers}"
        for symbol in "${symbol_list[@]}"; do
            printf 'long ffmpeg_probe_%s(void) { return (long)%s; }\n' "${symbol//[^A-Za-z0-9_]/_}" "${symbol}"
        done
        printf 'int main(void) { return 0'
        for symbol in "${symbol_list[@]}"; do
            printf ' | ((int)(ffmpeg_probe_%s() & 0xFFFF))' "${symbol//[^A-Za-z0-9_]/_}"
        done
        printf '; }\n'
    } > "${source_file}"

    cmd=("${compiler_cmd[@]}")
    if cross_build_is_active; then
        cmd+=("--sysroot=/")
    fi
    if command -v ld.lld >/dev/null 2>&1 && [ "${USE_LLD:-true}" != "false" ]; then
        cmd+=("-fuse-ld=lld")
    fi
    cmd+=("${cflags[@]}" "${source_file}" "-o" "${output_file}" "${libs[@]}")

    if "${cmd[@]}" >/dev/null 2>&1; then
        rm -rf "${probe_dir}"
        return 0
    fi

    rm -rf "${probe_dir}"
    return 1
}

ffmpeg_try_pkg_config_probe() {
    local pkg_spec="$1"
    local headers="$2"
    local symbols="$3"
    local cflags libs

    cflags="$(ffmpeg_collect_pkg_config_flags "${pkg_spec}" --cflags)" || return 1
    libs="$(ffmpeg_collect_pkg_config_flags "${pkg_spec}" --libs)" || return 1

    ffmpeg_try_link_probe "${headers}" "${symbols}" "${cflags}" "${libs}"
}

ffmpeg_probe_pkg_config_feature() {
    local feature="$1"
    local pkg_spec="$2"
    local headers="$3"
    local symbol="$4"

    if ffmpeg_try_pkg_config_probe "${pkg_spec}" "${headers}" "${symbol}"; then
        return 0
    fi

    echo "Skipping ${feature}: FFmpeg-style pkg-config probe failed for ${pkg_spec}."
    return 1
}

ffmpeg_probe_library_feature() {
    local feature="$1"
    local headers="$2"
    local symbol="$3"
    local libs_string="${4:-}"

    if ffmpeg_try_link_probe "${headers}" "${symbol}" "" "${libs_string}"; then
        return 0
    fi

    echo "Skipping ${feature}: FFmpeg-style link probe failed."
    return 1
}

ffmpeg_probe_libmp3lame() {
    ffmpeg_probe_library_feature "libmp3lame" "lame/lame.h" "lame_set_VBR_quality" "-lmp3lame -lm"
}

ffmpeg_probe_libopus() {
    ffmpeg_probe_pkg_config_feature "libopus" "opus" "opus_multistream.h" "opus_multistream_decoder_create opus_multistream_surround_encoder_create"
}

ffmpeg_probe_libvorbis() {
    if ffmpeg_probe_pkg_config_feature "libvorbis" "vorbis" "vorbis/codec.h" "vorbis_info_init" &&
       ffmpeg_probe_pkg_config_feature "libvorbisenc" "vorbisenc" "vorbis/vorbisenc.h" "vorbis_encode_init"; then
        return 0
    fi

    echo "Skipping libvorbis: FFmpeg-style codec and encoder probes did not both pass."
    return 1
}

ffmpeg_probe_libvpx_variant() {
    local feature="$1"
    local headers="$2"
    local symbols="$3"

    ffmpeg_try_pkg_config_probe "vpx >= 1.4.0" "${headers}" "${symbols}" || \
        ffmpeg_try_link_probe "${headers}" "${symbols}" "" "-lvpx -lm -lpthread"
}

ffmpeg_probe_libvpx() {
    local passed=1

    ffmpeg_probe_libvpx_variant "libvpx_vp8_decoder" "vpx/vpx_decoder.h vpx/vp8dx.h" "vpx_codec_vp8_dx VPX_IMG_FMT_HIGHBITDEPTH" && passed=0
    ffmpeg_probe_libvpx_variant "libvpx_vp8_encoder" "vpx/vpx_encoder.h vpx/vp8cx.h" "vpx_codec_vp8_cx VPX_IMG_FMT_HIGHBITDEPTH" && passed=0
    ffmpeg_probe_libvpx_variant "libvpx_vp9_decoder" "vpx/vpx_decoder.h vpx/vp8dx.h" "vpx_codec_vp9_dx VPX_IMG_FMT_HIGHBITDEPTH" && passed=0
    ffmpeg_probe_libvpx_variant "libvpx_vp9_encoder" "vpx/vpx_encoder.h vpx/vp8cx.h" "vpx_codec_vp9_cx VPX_IMG_FMT_HIGHBITDEPTH" && passed=0

    if [ "${passed}" -eq 0 ]; then
        return 0
    fi

    echo "Skipping libvpx: FFmpeg-style decoder and encoder probes failed."
    return 1
}

ffmpeg_probe_libx264() {
    if ffmpeg_probe_pkg_config_feature "libx264" "x264" "stdint.h x264.h" "x264_encoder_encode" &&
       ffmpeg_try_cpp_condition "x264.h" "X264_BUILD >= 155"; then
        return 0
    fi

    echo "Skipping libx264: FFmpeg-style pkg-config or build-version probe failed."
    return 1
}

ffmpeg_probe_libx265() {
    if ffmpeg_probe_pkg_config_feature "libx265" "x265" "x265.h" "x265_api_get" &&
       ffmpeg_try_cpp_condition "x265.h" "X265_BUILD >= 89"; then
        return 0
    fi

    echo "Skipping libx265: FFmpeg-style pkg-config or build-version probe failed."
    return 1
}

ffmpeg_probe_vdpau() {
    if ! ffmpeg_try_cpp_condition "vdpau/vdpau.h" "defined VDP_DECODER_PROFILE_MPEG4_PART2_ASP"; then
        echo "Skipping vdpau: FFmpeg-style header probe failed."
        return 1
    fi

    ffmpeg_probe_library_feature "vdpau" "vdpau/vdpau.h vdpau/vdpau_x11.h" "vdp_device_create_x11" "-lvdpau -lX11"
}

ffmpeg_probe_libfdk_aac() {
    if ffmpeg_try_pkg_config_probe "fdk-aac" "fdk-aac/aacenc_lib.h" "aacEncOpen"; then
        return 0
    fi

    if ffmpeg_try_link_probe "fdk-aac/aacenc_lib.h" "aacEncOpen" "" "-lfdk-aac"; then
        echo "Enabling libfdk-aac without pkg-config metadata."
        return 0
    fi

    echo "Skipping libfdk-aac: FFmpeg-style pkg-config and direct link probes failed."
    return 1
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
    )

    if cross_build_is_active; then
        local host_cc

        setup_linux_cross_env
        host_cc="$(resolve_ffmpeg_host_compiler)"
        if [ -n "${host_cc}" ]; then
            host_cc="$(prepare_ffmpeg_host_compiler_wrapper "${host_cc}")"
        fi
        configure_opts+=(
            "--arch=$(cross_target_arch)"
            "--target-os=linux"
            "--enable-cross-compile"
            "--cross-prefix=${CROSS_TARGET_TRIPLET}-"
            "--pkg-config=pkg-config"
        )
        if [ -n "${host_cc}" ]; then
            configure_opts+=("--host-cc=${host_cc}")
            echo "Using native host C compiler for FFmpeg build tools: ${host_cc}"
        fi
        configure_opts+=("--extra-cflags=--sysroot=/")
        configure_opts+=("--extra-ldflags=--sysroot=/")
        if [ "$(cross_target_arch)" = "riscv64" ]; then
            # Avoid cross-detecting host SDL when the target SDL dev package is unavailable.
            configure_opts+=("--disable-sdl2" "--disable-ffplay")
        fi
    fi

    if ffmpeg_probe_pkg_config_feature "libfreetype" "freetype2" "ft2build.h FT_FREETYPE_H" "FT_Init_FreeType"; then
        configure_opts+=("--enable-libfreetype")
    fi

    if ffmpeg_probe_libmp3lame; then
        configure_opts+=("--enable-libmp3lame")
    fi

    if ffmpeg_probe_libopus; then
        configure_opts+=("--enable-libopus")
    fi

    if ffmpeg_probe_libvorbis; then
        configure_opts+=("--enable-libvorbis")
    fi

    if ffmpeg_probe_libvpx; then
        configure_opts+=("--enable-libvpx")
    fi

    if ffmpeg_probe_libx264; then
        configure_opts+=("--enable-libx264")
    fi

    if ffmpeg_probe_libx265; then
        configure_opts+=("--enable-libx265")
    fi
    
    # Optional codecs - add if libraries are available
    if cross_build_is_active && [ "$(cross_target_arch)" = "riscv64" ]; then
        echo "Skipping gnutls for riscv64 cross builds because FFmpeg's configure probe does not currently pass in this environment."
    elif ffmpeg_probe_pkg_config_feature "gnutls" "gnutls" "gnutls/gnutls.h" "gnutls_global_init"; then
        configure_opts+=("--enable-gnutls")
    fi

    if ffmpeg_probe_pkg_config_feature "libass" "libass >= 0.11.0" "ass/ass.h" "ass_library_init"; then
        configure_opts+=("--enable-libass")
    fi

    if ffmpeg_probe_libfdk_aac; then
        configure_opts+=("--enable-libfdk-aac")
    fi
    
    if ffmpeg_probe_pkg_config_feature "libaom" "aom >= 2.0.0" "aom/aom_codec.h" "aom_codec_version"; then
        configure_opts+=("--enable-libaom")
    fi
    
    if ffmpeg_probe_pkg_config_feature "libdav1d" "dav1d >= 1.0.0" "dav1d/dav1d.h" "dav1d_version"; then
        configure_opts+=("--enable-libdav1d")
    fi
    
    if ffmpeg_probe_pkg_config_feature "libsvtav1" "SvtAv1Enc >= 0.9.0" "EbSvtAv1Enc.h" "svt_av1_enc_init_handle"; then
        configure_opts+=("--enable-libsvtav1")
    fi
    
    # Hardware acceleration (if available)
    if ffmpeg_probe_pkg_config_feature "vaapi" "libva >= 0.35.0" "va/va.h" "vaInitialize"; then
        configure_opts+=("--enable-vaapi")
    fi
    
    if ffmpeg_probe_vdpau; then
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

    # Use lld linker for faster linking if available
    if command -v ld.lld >/dev/null 2>&1 && [ "${USE_LLD:-true}" != "false" ]; then
        configure_opts+=("--extra-ldflags=-fuse-ld=lld")
        echo "Using lld linker for faster linking"
    fi

    # Use ccache if available
    if command -v ccache >/dev/null 2>&1 && [ "${USE_CCACHE:-true}" != "false" ]; then
        if cross_build_is_active; then
            configure_opts+=("--cc=ccache ${CC}")
            configure_opts+=("--cxx=ccache ${CXX}")
        else
            configure_opts+=("--cc=ccache gcc")
            configure_opts+=("--cxx=ccache g++")
        fi
        echo "Using ccache for faster compilation"
    elif cross_build_is_active; then
        configure_opts+=("--cc=${CC}")
        configure_opts+=("--cxx=${CXX}")
    fi

    # Disable features that auto-detect but fail to compile in this env
    configure_opts+=("--disable-libx264" "--disable-libx265")
    
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
        ldconfig 2>/dev/null || true
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
    local _ff_stamp="${FFMPEG_PREFIX}/.ffmpeg_version_stamp"
    if [ -x "${FFMPEG_PREFIX}/bin/ffmpeg" ]; then
        INSTALLED_VERSION=$("${FFMPEG_PREFIX}/bin/ffmpeg" -version 2>/dev/null | head -n1 | awk '{print $3}')
        echo "FFmpeg ${INSTALLED_VERSION} already installed at ${FFMPEG_PREFIX}"
        if [ "${FORCE_REBUILD:-0}" != "1" ]; then
            if [ -f "$_ff_stamp" ] && [ "$(cat "$_ff_stamp")" = "${INSTALLED_VERSION}" ]; then
                echo "Skipping rebuild (set FORCE_REBUILD=1 to force)"
                return 0
            fi
        fi
    fi

    fetch_ffmpeg
    configure_ffmpeg
    build_ffmpeg
    install_ffmpeg
    echo "$(${FFMPEG_PREFIX}/bin/ffmpeg -version 2>/dev/null | head -n1 | awk '{print $3}')" > "$_ff_stamp"
    cleanup
    
    echo "FFmpeg installed successfully to ${FFMPEG_PREFIX}"
    echo "Version: $(${FFMPEG_PREFIX}/bin/ffmpeg -version 2>/dev/null | head -n1 || echo 'unknown')"
}

main "$@"
