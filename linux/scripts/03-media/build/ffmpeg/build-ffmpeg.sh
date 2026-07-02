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

# Append the extra -I/-L search flags the custom cross-GCC needs into the named
# command array. Verified empirically: with --sysroot=/ it searches ONLY its own
# /opt/gcc-*/... dirs, NOT /usr/include or /usr/lib/<triplet>, and it ignores
# LIBRARY_PATH/CPATH — so apt-installed target headers/libs (x264, openjpeg, …)
# are invisible unless passed explicitly. Flags are appended as INDIVIDUAL array
# elements (NOT a space-joined string through split_shell_words, which the
# script's IFS=$'\n\t' would fail to re-split). No-op on native builds.
ffmpeg_append_cross_search_flags() {
    local -n _cmd_ref="$1"
    cross_build_is_active || return 0
    local t="${CROSS_TARGET_TRIPLET:-}"
    if [ -z "${t}" ] && command -v cross_target_triplet >/dev/null 2>&1; then
        t="$(cross_target_triplet 2>/dev/null || true)"
    fi
    _cmd_ref+=("-I/usr/include")
    if [ -n "${t}" ]; then
        [ -d "/usr/include/${t}" ] && _cmd_ref+=("-I/usr/include/${t}")
        [ -d "/usr/lib/${t}" ] && _cmd_ref+=("-L/usr/lib/${t}")
        [ -d "/lib/${t}" ] && _cmd_ref+=("-L/lib/${t}")
    fi
    return 0
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
        ffmpeg_append_cross_search_flags cmd
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
        # The custom cross-GCC searches only its own dirs (not /usr/include or
        # /usr/lib/<triplet>) and ignores LIBRARY_PATH — add them explicitly so
        # apt-installed target headers/libs are found. Without it every cross
        # codec probe fails and the feature is dropped.
        ffmpeg_append_cross_search_flags cmd
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

    # Gate on pkg-config resolution — the SAME mechanism FFmpeg's own configure
    # uses, so a module that resolves here resolves there too. If it does not
    # resolve, the library genuinely is not available for this arch (in cross
    # builds this correctly reflects the target's pkg-config view).
    if ! pkg-config --exists "${pkg_spec}" >/dev/null 2>&1; then
        echo "Skipping ${feature}: pkg-config cannot resolve ${pkg_spec}."
        return 1
    fi

    # Definitive check: compile+link a micro-probe with the SAME compiler ($CC)
    # and pkg-config flags FFmpeg's configure uses. If it passes, FFmpeg will too.
    if ffmpeg_try_pkg_config_probe "${pkg_spec}" "${headers}" "${symbol}"; then
        return 0
    fi

    # The link step failed. Decide using the pkg-config cflags whether this is a
    # spurious probe artifact or a genuinely unusable module:
    #   (a) headers DO compile with the .pc cflags -> the .pc is valid and the
    #       link failure is an artifact of our generated test (e.g. a missing
    #       transitive -l). FFmpeg's fuller link will succeed; gating on this
    #       previously produced false negatives that silently dropped installed
    #       codecs (x264/opus/vpx/mp3lame/webp/svtav1/vmaf, …). Enable it.
    #   (b) headers do NOT compile with the .pc cflags -> the .pc resolves via
    #       --exists but its -I does not locate the header (broken/incomplete
    #       .pc, e.g. libonnxruntime). Passing --enable-${feature} would make
    #       FFmpeg's configure hard-FAIL and abort the whole build, so skip and
    #       let the caller fall back to a direct-path probe if it has one.
    local pc_cflags pc_libs
    pc_cflags="$(ffmpeg_collect_pkg_config_flags "${pkg_spec}" --cflags 2>/dev/null || true)"
    pc_libs="$(ffmpeg_collect_pkg_config_flags "${pkg_spec}" --libs 2>/dev/null || true)"
    # Two conditions must BOTH hold to treat the link failure as spurious:
    #   1. headers compile with the .pc cflags (the .pc's -I is valid), AND
    #   2. an EMPTY main links against the .pc's libs (the target .so actually
    #      exists and is linkable for this arch).
    # Checking headers alone is not enough for cross builds: a host .pc can
    # resolve via --exists and its arch-independent headers compile, while the
    # target library is absent — so `-l<lib>` fails with "unable to find
    # library" and FFmpeg's own require_pkg_config aborts the whole build (this
    # is exactly what happened for libopenjp2/libdrm on arm64/riscv64). The
    # empty-main link uses the same cross sysroot/lld path as the real probe, so
    # it faithfully predicts whether FFmpeg's link will find the library, while
    # still enabling codecs whose only issue was a missing transitive -l in our
    # symbol test program (x264/opus/vpx/…).
    local _hdr_ok=1 _lnk_ok=1
    ffmpeg_try_cpp_condition "${headers}" "1" "${pc_cflags}" || _hdr_ok=0
    ffmpeg_try_link_probe "" "" "${pc_cflags}" "${pc_libs}" || _lnk_ok=0
    if [ "${_hdr_ok}" = 1 ] && [ "${_lnk_ok}" = 1 ]; then
        echo "Note: ${feature} symbol micro-probe failed but its headers compile and its libraries link; enabling (FFmpeg's configure will verify the link)."
        return 0
    fi

    echo "Skipping ${feature}: ${pkg_spec} resolves via pkg-config but is not usable for this target (header_compile=${_hdr_ok} lib_link=${_lnk_ok}); not enabling to avoid a hard FFmpeg configure failure."
    echo "  probe-detail ${feature}: CC='${CC:-}' headers='${headers}' cflags='${pc_cflags}' libs='${pc_libs}'"
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

    # No pkg-config file for these libraries, so fall back to header-presence
    # AND an empty-main link against the given libs. Headers alone are not enough
    # on cross builds: arch-independent headers can be present while the target
    # .so is absent, so enabling would make FFmpeg's configure link hard-fail.
    # The empty-main link (same libs, same cross sysroot/lld path) confirms the
    # library is actually linkable, while still enabling libs whose only issue
    # was a missing transitive -l in the symbol test program.
    if ffmpeg_try_cpp_condition "${headers}" "1" \
       && ffmpeg_try_link_probe "" "" "" "${libs_string}"; then
        echo "Note: ${feature} symbol micro-probe failed but its headers are present and its libraries link; enabling (FFmpeg's configure will verify the link)."
        return 0
    fi

    echo "Skipping ${feature}: headers or libraries not usable for this target (dev package missing / not linkable?)."
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
       ffmpeg_try_cpp_condition "stdint.h x264.h" "X264_BUILD >= 155"; then
        return 0
    fi

    echo "Skipping libx264: FFmpeg-style pkg-config or build-version probe failed."
    return 1
}

ffmpeg_probe_libx265() {
    if ffmpeg_probe_pkg_config_feature "libx265" "x265" "stdint.h x265.h" "x265_api_get" &&
       ffmpeg_try_cpp_condition "stdint.h x265.h" "X265_BUILD >= 89"; then
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

# FFmpeg enables its external DNN backends (libonnxruntime/libtensorflow/
# libopenvino) via require_pkg_config, so ONLY a valid .pc — not bare
# CFLAGS/LDFLAGS — satisfies its configure. When a backend is installed at a
# known path but ships no (or a broken) .pc, synthesize a correct one here and
# re-run the standard pkg-config probe. Enabling only when that re-probe passes
# guarantees FFmpeg's own require_pkg_config will succeed, so we can never turn
# on a backend that would hard-abort the whole build.
ffmpeg_enable_via_synth_pkgconfig() {
    local feature="$1" pkg_name="$2" headers="$3" symbols="$4"
    local prefix="$5" cflags="$6" libs="$7" version="${8:-1.0}"
    [ -n "${version}" ] || version="1.0"

    local pc_dir="${prefix}/lib/pkgconfig"
    mkdir -p "${pc_dir}" 2>/dev/null || return 1
    cat > "${pc_dir}/${pkg_name}.pc" <<EOF
prefix=${prefix}
Name: ${pkg_name}
Description: ${feature} (pkg-config synthesized by build-ffmpeg.sh)
Version: ${version}
Cflags: ${cflags}
Libs: ${libs}
EOF
    # Prepend so this shadows any broken vendor .pc already on the path, and
    # export it so FFmpeg's configure (a child process) resolves the same module.
    export PKG_CONFIG_PATH="${pc_dir}${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
    ffmpeg_probe_pkg_config_feature "${feature}" "${pkg_name}" "${headers}" "${symbols}"
}

ffmpeg_probe_libonnxruntime() {
    # A working pkg-config module is the only thing FFmpeg's require_pkg_config
    # accepts; try it first.
    if ffmpeg_probe_pkg_config_feature "libonnxruntime" "libonnxruntime" \
        "onnxruntime_c_api.h" "OrtGetApiBase"; then
        return 0
    fi

    # ONNX Runtime is built into this stage but ships no usable libonnxruntime.pc
    # (the vendor one resolves via --exists yet its -I does not locate the
    # header). Synthesize a correct .pc from the known install path and re-probe.
    local onnx_base="/usr/local/lib/onnxruntime-cpu"
    if [ -f "${onnx_base}/lib/libonnxruntime.so" ] && [ -f "${onnx_base}/include/onnxruntime_c_api.h" ]; then
        if ffmpeg_enable_via_synth_pkgconfig "libonnxruntime" "libonnxruntime" \
            "onnxruntime_c_api.h" "OrtGetApiBase" "${onnx_base}" \
            "-I${onnx_base}/include -I${onnx_base}/include/onnxruntime/core/session" \
            "-L${onnx_base}/lib -lonnxruntime" "${ONNXRUNTIME_VERSION#v}"; then
            echo "ONNX Runtime enabled via synthesized pkg-config at ${onnx_base}."
            return 0
        fi
    fi

    echo "Skipping libonnxruntime: no usable pkg-config module (ONNX Runtime absent or its headers do not compile)."
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
    # NOTE: LiteRT/TFLite (built in-stage) exposes a DIFFERENT API than the full
    # TensorFlow C API FFmpeg's libtensorflow backend requires
    # (tensorflow/c/c_api.h + TF_Version). Passing it off as libtensorflow made
    # FFmpeg's configure hard-fail, so we no longer do that — only the full TF C
    # SDK, resolved through a working pkg-config module, can back this backend.

    # Ensure the full TensorFlow C SDK is present (best-effort, cached download;
    # unavailable for arm64/riscv64, which then skip cleanly).
    local tf_cache="${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}/tensorflow-c"
    if [ ! -f "${tf_cache}/lib/libtensorflow.so" ]; then
        ensure_tensorflow_c_sdk || { echo "Skipping libtensorflow: full TensorFlow C SDK unavailable."; return 1; }
    fi

    export PKG_CONFIG_PATH="${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}:${PKG_CONFIG_PATH:-}"
    if ffmpeg_probe_pkg_config_feature "libtensorflow" "tensorflow" \
        "tensorflow/c/c_api.h" "TF_Version TF_NewGraph"; then
        return 0
    fi

    # SDK present but no usable .pc — synthesize one and re-probe.
    local tf_base=""
    for d in "${tf_cache}" /usr/local/lib/tensorflow-c /opt/tensorflow-c; do
        [ -f "${d}/lib/libtensorflow.so" ] && { tf_base="${d}"; break; }
    done
    if [ -n "${tf_base}" ] && ffmpeg_enable_via_synth_pkgconfig "libtensorflow" "tensorflow" \
        "tensorflow/c/c_api.h" "TF_Version TF_NewGraph" "${tf_base}" \
        "-I${tf_base}/include" "-L${tf_base}/lib -ltensorflow" "${TENSORFLOW_C_VERSION:-2.16.1}"; then
        echo "TensorFlow C SDK enabled via synthesized pkg-config at ${tf_base}."
        return 0
    fi

    echo "Skipping libtensorflow: SDK not found or unusable."
    return 1
}

ffmpeg_probe_libopenvino() {
    local ov_dir="${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}/openvino"
    local ov_pkg="${ov_dir}/runtime/lib/pkgconfig"

    # Vendored SDK with its own pkg-config dir — export it (not just inline) so
    # FFmpeg's configure child process resolves the same module our probe did.
    if [ -d "${ov_pkg}" ]; then
        export PKG_CONFIG_PATH="${ov_pkg}:${PKG_CONFIG_PATH:-}"
        if ffmpeg_probe_pkg_config_feature "libopenvino" "openvino" \
            "openvino/openvino.hpp openvino/c/openvino.h" "ov_get_openvino_version"; then
            return 0
        fi
    fi

    # If openvino is installed system-wide via apt, try pkg-config directly
    if ffmpeg_probe_pkg_config_feature "libopenvino" "openvino" \
        "openvino/openvino.hpp openvino/c/openvino.h" "ov_get_openvino_version"; then
        return 0
    fi

    # Direct install without a usable .pc — synthesize one and re-probe.
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
    if ffmpeg_enable_via_synth_pkgconfig "libopenvino" "openvino" \
        "openvino/c/openvino.h" "ov_get_openvino_version" "${ov_base}" \
        "-I${ov_base}/runtime/include" "-L${ov_lib_dir} -lopenvino" "${OPENVINO_VERSION:-2024.0}"; then
        return 0
    fi

    echo "Skipping libopenvino: SDK not found or unusable."
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
            configure_opts+=("--extra-ldflags=-L/usr/lib/${_ma_triplet} -L/lib/${_ma_triplet}")
            # -I/usr/include is required too: the custom cross-GCC does not search
            # it by default, so headers like x264.h (in /usr/include, not the
            # triplet dir) are otherwise invisible to FFmpeg's own compiles.
            configure_opts+=("--extra-cflags=-I/usr/include -I/usr/include/${_ma_triplet}")
            echo "Cross: added multiarch lib/include dirs for ${_ma_triplet} (-L/-I incl /usr/include) so apt-installed target codecs link"
        fi
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

    # NOTE: libx265 is intentionally NOT enabled here. The configure probe
    # passes but compilation fails with newer x265 releases (see the explicit
    # --disable-libx265 later in this function). Re-enable only after upstream
    # x265/FFmpeg source compatibility is restored.
    
    # Optional codecs - add if libraries are available
    if cross_build_is_active && [ "$(cross_target_arch)" = "riscv64" ]; then
        echo "Skipping gnutls for riscv64 cross builds because FFmpeg's configure probe does not currently pass in this environment."
    elif ffmpeg_probe_pkg_config_feature "gnutls" "gnutls" "gnutls/gnutls.h" "gnutls_global_init"; then
        configure_opts+=("--enable-gnutls")
    fi

    if ffmpeg_probe_pkg_config_feature "libass" "libass >= 0.11.0" "ass/ass.h" "ass_library_init"; then
        configure_opts+=("--enable-libass")
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
    
    if ffmpeg_probe_libonnxruntime; then
        configure_opts+=("--enable-libonnxruntime")
    fi

    # Deep Neural Network backends (always try; skip if SDK not available)
    if ffmpeg_probe_libtensorflow; then
        configure_opts+=("--enable-libtensorflow")
    fi
    
    if ffmpeg_probe_libopenvino; then
        configure_opts+=("--enable-libopenvino")
    fi

    # Image codecs
    if ffmpeg_probe_pkg_config_feature "libwebp" "libwebp" "webp/decode.h" "WebPGetDecoderVersion"; then
        configure_opts+=("--enable-libwebp")
    fi

    # Video quality metrics (if installed)
    if ffmpeg_probe_pkg_config_feature "libvmaf" "libvmaf" "libvmaf/libvmaf.h" "vmaf_version"; then
        configure_opts+=("--enable-libvmaf")
    fi

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
    local _ff_feat _ff_flag _ff_pkg _ff_hdrs _ff_syms _ff_libs
    for _ff_feat in "${_ff_extra_pkgconfig[@]}"; do
        IFS='|' read -r _ff_flag _ff_pkg _ff_hdrs _ff_syms <<<"${_ff_feat}"
        if ffmpeg_probe_pkg_config_feature "${_ff_flag}" "${_ff_pkg}" "${_ff_hdrs}" "${_ff_syms}"; then
            configure_opts+=("${_ff_flag}")
        fi
    done

    # Libraries that ship no pkg-config file — direct link probe instead.
    local _ff_extra_link=(
        "--enable-libtwolame|twolame.h|twolame_init|-ltwolame"
        "--enable-libgsm|gsm/gsm.h|gsm_create|-lgsm"
        "--enable-libxvid|xvid.h|xvid_global|-lxvidcore"
    )
    for _ff_feat in "${_ff_extra_link[@]}"; do
        IFS='|' read -r _ff_flag _ff_hdrs _ff_syms _ff_libs <<<"${_ff_feat}"
        if ffmpeg_probe_library_feature "${_ff_flag}" "${_ff_hdrs}" "${_ff_syms}" "${_ff_libs}"; then
            configure_opts+=("${_ff_flag}")
        fi
    done

    # Hardware acceleration (if available)
    if ffmpeg_probe_pkg_config_feature "vaapi" "libva >= 0.35.0" "va/va.h" "vaInitialize"; then
        configure_opts+=("--enable-vaapi")
    fi
    
    if ffmpeg_probe_vdpau; then
        configure_opts+=("--enable-vdpau")
    fi

    # Vulkan HW acceleration — auto-detected by FFmpeg's configure but also
    # explicitly enabled via pkg-config probe for cross-build reliability.
    if ffmpeg_probe_pkg_config_feature "vulkan" "vulkan" "vulkan/vulkan.h" "vkCreateInstance"; then
        configure_opts+=("--enable-vulkan")
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

    # Explicitly disable libx265: the configure probe passes but FFmpeg
    # compilation fails against newer x265 releases (see note above).
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

    local failures=0

    # Basic version check
    local version
    version="$("${ffmpeg_bin}" -version 2>&1 | head -1)"
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

    # Only run version check / stamp read when the binary is native — cross-compiled
    # binaries cannot execute on the build host.
    if [ "${_arch}" = "$(uname -m)" ]; then
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
    fi

    fetch_ffmpeg
    configure_ffmpeg
    build_ffmpeg
    install_ffmpeg

    # Only write stamp and run smoke test for native builds
    if [ "${_arch}" = "$(uname -m)" ]; then
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
