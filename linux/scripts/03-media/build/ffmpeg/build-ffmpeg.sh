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
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../core/common.sh"
media_common_init "${SCRIPT_DIR}"

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

    # Use latest stable release tag (default from versions.env via orchestrator or env),
    # or "main" to track the latest development branch.
    local release_ref="${FFMPEG_VERSION:-n8.1.2}"

    local tarball_url
    case "${release_ref}" in
      main|master|develop) tarball_url="https://github.com/FFmpeg/FFmpeg/archive/refs/heads/${release_ref}.tar.gz" ;;
      *)                   tarball_url="https://github.com/FFmpeg/FFmpeg/archive/refs/tags/${release_ref}.tar.gz" ;;
    esac
    echo "Downloading FFmpeg ${release_ref} from ${tarball_url}..."
    curl -sL "${tarball_url}" | tar -xzf - -C "${FFMPEG_SRC}" --strip-components=1 || {
        echo "Tarball download failed for ${tarball_url}" >&2
        exit 1
    }
    cd "${FFMPEG_SRC}"
    echo "FFmpeg version: ${release_ref} (from tarball)"
}

# ==============================================================================
# FFmpeg dependency probe infrastructure (~180 lines)
#
# FFmpeg's `configure` script probes for optional libraries by compiling small
# test programs with the target compiler and linker. During cross builds,
# FFmpeg's bundled cross-pkg-config may fail to find target libraries, and its
# own probe tests may silently skip libraries that ARE available.
#
# These functions replicate FFmpeg's C/C++ compile-and-link probe logic so we
# can independently verify each optional dependency and configure the right
# --enable-* / --disable-* flags BEFORE invoking FFmpeg's configure.
#
# Key functions:
#   ffmpeg_try_cpp_condition  — compile a C++ #if test
#   ffmpeg_try_header         — compile a #include test
#   ffmpeg_try_link_probe     — compile + link a function-call test
#   ffmpeg_try_pkg_config_probe — resolve via pkg-config + compile+link test
#
# These are specific to FFmpeg's dependency graph and are NOT intended as
# general-purpose cross-compilation probes.
# ==============================================================================
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
    local wrapper_dir
    wrapper_dir="$(mktemp -d "${FFMPEG_HOST_TOOLCHAIN_DIR:-/tmp/ffmpeg-host-toolchain}.XXXXXX")"
    local wrapper_path="${wrapper_dir}/host-gcc"

    if command -v make_named_host_compiler_wrapper >/dev/null 2>&1; then
        make_named_host_compiler_wrapper "${wrapper_dir}" host-gcc "${compiler}" >/dev/null
        printf '%s' "${wrapper_path}"
        return 0
    fi

    mkdir -p "${wrapper_dir}"
    cat > "${wrapper_path}" <<EOF
#!/usr/bin/env bash
exec env PATH="/usr/bin:/bin" "${compiler}" "\$@"
EOF
    chmod +x "${wrapper_path}"
    printf '%s' "${wrapper_path}"
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

ffmpeg_probe_libonnx() {
    if ffmpeg_probe_pkg_config_feature "libonnxruntime" "libonnxruntime" \
        "onnxruntime_c_api.h" "OrtGetApiBase"; then
        return 0
    fi
    echo "Skipping libonnx: ONNX Runtime pkg-config probe failed."
    return 1
}

# ---------------------------------------------------------------------------
# DNN backend probes — TensorFlow and OpenVINO
# ---------------------------------------------------------------------------

# Download TensorFlow C API SDK into a cache directory so it persists across
# rebuilds. FFmpeg's --enable-libtensorflow needs libtensorflow.so + headers.
ensure_tensorflow_c_sdk() {
    local cache_dir="${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}"
    local tf_dir="${cache_dir}/tensorflow-c"
    local tf_version="${TENSORFLOW_C_VERSION:-2.16.1}"
    local tf_archive tf_url

    if [ -f "${tf_dir}/lib/libtensorflow.so" ] && [ -f "${tf_dir}/include/tensorflow/c/c_api.h" ]; then
        echo "TensorFlow C SDK ${tf_version} already cached at ${tf_dir}"
        return 0
    fi

    mkdir -p "${cache_dir}" "${tf_dir}/lib" "${tf_dir}/include"

    case "$(uname -m)" in
        x86_64)
            tf_archive="libtensorflow-cpu-linux-x86_64-${tf_version}.tar.gz"
            ;;
        aarch64|arm64)
            tf_archive="libtensorflow-cpu-linux-aarch64-${tf_version}.tar.gz"
            ;;
        *)
            echo "Skipping TensorFlow C SDK: unsupported arch $(uname -m)"
            return 1
            ;;
    esac

    tf_url="https://github.com/tensorflow/tensorflow/archive/refs/tags/v${tf_version}.tar.gz"
    echo "Downloading TensorFlow C SDK ${tf_version}..."
    # Download just the C library from the TF release
    local tf_release_url="https://github.com/tensorflow/tensorflow/releases/download/v${tf_version}/${tf_archive}"
    if     curl -sL --connect-timeout 30 --max-time 300 -o "${cache_dir}/${tf_archive}" "${tf_release_url}" 2>/dev/null \
        && [ -s "${cache_dir}/${tf_archive}" ]; then
        tar -xzf "${cache_dir}/${tf_archive}" -C "${cache_dir}" 2>/dev/null || true
        # The tarball extracts to ./lib/ and ./include/ relative to cache_dir
        if [ -d "${cache_dir}/lib" ] && [ -f "${cache_dir}/lib/libtensorflow.so" ]; then
            mv "${cache_dir}/lib" "${tf_dir}/lib" 2>/dev/null || true
            mv "${cache_dir}/include" "${tf_dir}/include" 2>/dev/null || true
        fi
        # Create a pkg-config file for FFmpeg's configure to find
        cat > "${cache_dir}/tensorflow.pc" <<PKGCONF
prefix=${tf_dir}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: TensorFlow
Description: TensorFlow C API
Version: ${tf_version}
Libs: -L\${libdir} -ltensorflow
Cflags: -I\${includedir}
PKGCONF
        export PKG_CONFIG_PATH="${cache_dir}:${PKG_CONFIG_PATH:-}"
        echo "TensorFlow C SDK ${tf_version} installed to ${tf_dir}"
        return 0
    fi

    echo "TensorFlow C SDK download failed (trying alternate URL)..."
    # Fallback: use the full TF source release (much larger but always available)
    local alt_url="https://github.com/tensorflow/tensorflow/releases/download/v${tf_version}/libtensorflow-cpu-linux-x86_64-${tf_version}.tar.gz"
    if curl -sL --connect-timeout 30 --max-time 600 -o "${cache_dir}/${tf_archive}" "${alt_url}" 2>/dev/null \
        && [ -s "${cache_dir}/${tf_archive}" ]; then
        tar -xzf "${cache_dir}/${tf_archive}" -C "${tf_dir}" 2>/dev/null || true
        echo "TensorFlow C SDK ${tf_version} installed (fallback URL)"
        return 0
    fi

    echo "WARNING: TensorFlow C SDK download failed. libtensorflow will not be available."
    return 1
}

ffmpeg_probe_libtensorflow() {
    local tf_cache="${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}/tensorflow-c"

    if [ ! -d "${tf_cache}/lib" ]; then
        ensure_tensorflow_c_sdk || return 1
    fi

    # The pkg-config file was written to the parent cache dir; ensure it's on PKG_CONFIG_PATH
    export PKG_CONFIG_PATH="${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}:${PKG_CONFIG_PATH:-}"

    # Also try a direct pkg-config probe through the cached .pc file
    if [ -f "${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}/tensorflow.pc" ]; then
        local pc_dir="${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}"
        if PKG_CONFIG_PATH="${pc_dir}" pkg-config --exists tensorflow 2>/dev/null; then
            echo "TensorFlow C SDK pkg-config resolved at ${pc_dir}"
        fi
    fi

    if ffmpeg_probe_pkg_config_feature "libtensorflow" "tensorflow" \
        "tensorflow/c/c_api.h" "TF_Version TF_NewGraph"; then
        return 0
    fi

    # Fallback: probe with explicit paths
    local tf_base=""
    for d in "${tf_cache}" /usr/local/lib/tensorflow-c /opt/tensorflow-c; do
        [ -f "${d}/lib/libtensorflow.so" ] && { tf_base="${d}"; break; }
    done
    [ -z "${tf_base}" ] && { echo "Skipping libtensorflow: SDK not found."; return 1; }

    if ffmpeg_try_link_probe "tensorflow/c/c_api.h" "TF_Version TF_NewGraph" \
        "-I${tf_base}/include" "-L${tf_base}/lib -ltensorflow"; then
        export CFLAGS="${CFLAGS:-} -I${tf_base}/include"
        export LDFLAGS="${LDFLAGS:-} -L${tf_base}/lib -ltensorflow"
        # FFmpeg's --extra-cflags/--extra-ldflags override pkg-config; append them
        # so configure can link the probe test correctly.
        echo "TensorFlow C SDK found at ${tf_base} (direct link)"
        return 0
    fi

    echo "Skipping libtensorflow: FFmpeg-style link probe failed."
    return 1
}

ffmpeg_probe_libopenvino() {
    local ov_dir="${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}/openvino"
    local ov_pkg="${ov_dir}/runtime/lib/pkgconfig"

    if [ -d "${ov_pkg}" ]; then
        if PKG_CONFIG_PATH="${ov_pkg}:${PKG_CONFIG_PATH:-}" \
            ffmpeg_probe_pkg_config_feature "libopenvino" "openvino" \
            "openvino/openvino.hpp openvino/c/openvino.h" "ov_get_openvino_version"; then
            return 0
        fi
    fi

    # If openvino is installed system-wide via apt, try pkg-config directly
    if ffmpeg_probe_pkg_config_feature "libopenvino" "openvino" \
        "openvino/openvino.hpp openvino/c/openvino.h" "ov_get_openvino_version"; then
        return 0
    fi

    # Direct link probe without pkg-config
    local ov_base=""
    for d in "${ov_dir}" /opt/intel/openvino /usr/local/openvino; do
        if [ -f "${d}/runtime/lib/libopenvino.so" ] || [ -f "${d}/lib/libopenvino.so" ]; then
            ov_base="${d}"
            break
        fi
    done
    [ -z "${ov_base}" ] && { echo "Skipping libopenvino: SDK not found."; return 1; }

    local ov_lib_dir
    [ -d "${ov_base}/runtime/lib" ] && ov_lib_dir="${ov_base}/runtime/lib" || ov_lib_dir="${ov_base}/lib"
    if ffmpeg_try_link_probe "openvino/c/openvino.h" "ov_get_openvino_version" \
        "-I${ov_base}/runtime/include" "-L${ov_lib_dir} -lopenvino"; then
        export CFLAGS="${CFLAGS:-} -I${ov_base}/runtime/include"
        export LDFLAGS="${LDFLAGS:-} -L${ov_lib_dir} -lopenvino"
        return 0
    fi

    echo "Skipping libopenvino: FFmpeg-style link probe failed."
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
        # DNN module is auto-detected (no --enable-dnn flag; removed in FFmpeg master).
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
            # RVV assembly uses absolute relocations; allow text rels in shared libs
            configure_opts+=("--extra-ldflags=-Wl,-z,notext")
        fi
    fi

    # Workaround for glibc 2.43+ __pthread_cond_timedwait64 symbol (Clang sets __USE_TIME_BITS64)
    configure_opts+=("--extra-cflags=-U__USE_TIME_BITS64")

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
    
    if ffmpeg_probe_libonnx; then
        configure_opts+=("--enable-libonnx")
    fi

    # Deep Neural Network backends (always try; skip if SDK not available)
    if ffmpeg_probe_libtensorflow; then
        configure_opts+=("--enable-libtensorflow")
    fi
    
    if ffmpeg_probe_libopenvino; then
        configure_opts+=("--enable-libopenvino")
    fi
    
    # Hardware acceleration (if available)
    if ffmpeg_probe_pkg_config_feature "vaapi" "libva >= 0.35.0" "va/va.h" "vaInitialize"; then
        configure_opts+=("--enable-vaapi")
    fi
    
    if ffmpeg_probe_vdpau; then
        configure_opts+=("--enable-vdpau")
    fi
    
    # NVIDIA Hardware acceleration — auto-probe for CUDA SDK
    CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
    if [ -f "${CUDA_HOME}/include/cuda.h" ] && [ -d "${CUDA_HOME}/lib64" ]; then
        echo "NVIDIA CUDA SDK detected at ${CUDA_HOME}. Enabling NVENC/NVDEC/CUDA..."
        configure_opts+=("--enable-nvenc")
        configure_opts+=("--enable-nvdec")
        configure_opts+=("--enable-cuvid")
        configure_opts+=("--enable-ffnvcodec")
        configure_opts+=("--enable-cuda-nvcc")
        configure_opts+=("--extra-cflags=-I${CUDA_HOME}/include")
        configure_opts+=("--extra-ldflags=-L${CUDA_HOME}/lib64")
    elif [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
        echo "ENABLE_NVIDIA=true but CUDA SDK not found at ${CUDA_HOME}. Skipping NVIDIA acceleration."
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

    # Disable x265 if the installed library API is incompatible with this FFmpeg
    # version (the configure probe passes but compilation fails with newer x265).
    configure_opts+=("--disable-libx265")
    
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
