#!/usr/bin/env bash
# FFmpeg dependency probes mirroring configure's own checks; sourced by build-ffmpeg.sh, whose set -euo pipefail and IFS they assume.

split_shell_words() {
    local -n out_ref="$1"
    local words="${2:-}"

    out_ref=()
    [ -n "${words}" ] || return 0

    # pkg-config flags are space-delimited but the caller's IFS is $'\n\t', so split with a local whitespace IFS.
    local IFS=$' \t\n'
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

# The cross GCC ignores /usr/include, the multiarch dirs and LIBRARY_PATH/CPATH; flags go in as separate elements because IFS lacks a space.
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
    resolve_host_compiler_for_lang c
}

prepare_ffmpeg_host_compiler_wrapper() {
    local wrapper_dir
    : "${FFMPEG_HOST_TOOLCHAIN_DIR:=/tmp/ffmpeg-host-toolchain}"
    wrapper_dir="$(mktemp -d "${FFMPEG_HOST_TOOLCHAIN_DIR}.XXXXXX")" || return 1
    prepare_host_compiler_wrapper "$1" host-gcc "${wrapper_dir}"
}

_ffmpeg_condition_source() {
    ffmpeg_write_includes "$1"
    printf '#if !(%s)\n' "$2"
    printf '#error condition failed\n#endif\nint ffmpeg_probe_condition = 0;\n'
}

_ffmpeg_link_source() {
    local symbol
    local -a symbol_list=()
    split_shell_words symbol_list "$2"
    ffmpeg_write_includes "$1"
    for symbol in "${symbol_list[@]}"; do
        printf 'long ffmpeg_probe_%s(void) { return (long)%s; }\n' "${symbol//[^A-Za-z0-9_]/_}" "${symbol}"
    done
    printf 'int main(void) { return 0'
    for symbol in "${symbol_list[@]}"; do
        printf ' | ((int)(ffmpeg_probe_%s() & 0xFFFF))' "${symbol//[^A-Za-z0-9_]/_}"
    done
    printf '; }\n'
}

_ffmpeg_try_source_probe() {
    local mode="$1" cflags_string="$2" libs_string="$3" writer="$4"
    shift 4
    local compiler_string probe_dir source_file output_file status=0
    local -a cmd=() cflags=() libs=()
    compiler_string="$(ffmpeg_probe_compiler)"
    split_shell_words cmd "${compiler_string}"
    split_shell_words cflags "${cflags_string}"
    split_shell_words libs "${libs_string}"
    probe_dir="$(mktemp -d)"
    source_file="${probe_dir}/probe.c"
    output_file="${probe_dir}/probe"
    "${writer}" "$@" > "${source_file}"
    if cross_build_is_active; then
        cmd+=("--sysroot=/")
        ffmpeg_append_cross_search_flags cmd
    fi
    case "${mode}" in
        compile)
            output_file+=.o
            cmd+=("${cflags[@]}" -c "${source_file}" -o "${output_file}")
            ;;
        link)
            if compiler_tool_enabled ld.lld "${USE_LLD:-true}"; then
                cmd+=(-fuse-ld=lld)
            fi
            cmd+=("${cflags[@]}" "${source_file}" -o "${output_file}" "${libs[@]}")
            ;;
    esac
    if [ "${mode}" = compile ] && [ "${FFMPEG_PROBE_DEBUG:-0}" = 1 ]; then
        # Debug capture is advisory; the following compile owns the verdict.
        _FFMPEG_LAST_PROBE_ERR="$("${cmd[@]}" 2>&1 >/dev/null || true)"
    fi
    "${cmd[@]}" >/dev/null 2>&1 || status=1
    rm -rf "${probe_dir}"
    return "${status}"
}

ffmpeg_try_cpp_condition() {
    _ffmpeg_try_source_probe compile "${3:-}" '' _ffmpeg_condition_source "$1" "$2"
}

ffmpeg_try_link_probe() {
    _ffmpeg_try_source_probe link "${3:-}" "${4:-}" _ffmpeg_link_source "$1" "$2"
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

    # Gate on pkg-config, the mechanism FFmpeg's configure uses, so what resolves here resolves there.
    if ! pkg-config --exists "${pkg_spec}" >/dev/null 2>&1; then
        echo "Skipping ${feature}: pkg-config cannot resolve ${pkg_spec}."
        return 1
    fi

    # Same $CC and pkg-config flags as FFmpeg's configure, so a pass here passes there.
    if ffmpeg_try_pkg_config_probe "${pkg_spec}" "${headers}" "${symbol}"; then
        return 0
    fi

    # A failed symbol link can be our probe's artifact (a missing transitive -l), but enabling an unusable .pc hard-fails configure.
    local pc_cflags pc_libs
    pc_cflags="$(ffmpeg_collect_pkg_config_flags "${pkg_spec}" --cflags 2>/dev/null || true)"
    pc_libs="$(ffmpeg_collect_pkg_config_flags "${pkg_spec}" --libs 2>/dev/null || true)"
    # Spurious only if the headers compile AND an empty main links the .pc's libs: on cross, a host .pc resolves while the target lib is absent.
    local _hdr_ok=1 _lnk_ok=1
    _FFMPEG_LAST_PROBE_ERR=""
    ffmpeg_try_cpp_condition "${headers}" "1" "${pc_cflags}" || _hdr_ok=0
    local _hdr_err="${_FFMPEG_LAST_PROBE_ERR}"
    ffmpeg_try_link_probe "" "" "${pc_cflags}" "${pc_libs}" || _lnk_ok=0
    if [ "${_hdr_ok}" = 1 ] && [ "${_lnk_ok}" = 1 ]; then
        echo "Note: ${feature} symbol micro-probe failed but its headers compile and its libraries link; enabling (FFmpeg's configure will verify the link)."
        return 0
    fi

    echo "Skipping ${feature}: ${pkg_spec} resolves via pkg-config but is not usable for this target (header_compile=${_hdr_ok} lib_link=${_lnk_ok}); not enabling to avoid a hard FFmpeg configure failure."
    echo "  probe-detail ${feature}: CC='${CC:-}' headers='${headers}' cflags='${pc_cflags}' libs='${pc_libs}'"
    if [ "${FFMPEG_PROBE_DEBUG:-0}" = "1" ] && [ "${_hdr_ok}" = 0 ] && [ -n "${_hdr_err}" ]; then
        echo "  header-stderr ${feature}: $(printf '%s' "${_hdr_err}" | head -3 | tr '\n' '|')"
    fi
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

    # Headers alone can exist without the target .so on cross, so an empty main must link the libs too.
    if ffmpeg_try_cpp_condition "${headers}" "1" \
       && ffmpeg_try_link_probe "" "" "" "${libs_string}"; then
        echo "Note: ${feature} symbol micro-probe failed but its headers are present and its libraries link; enabling (FFmpeg's configure will verify the link)."
        return 0
    fi

    echo "Skipping ${feature}: headers or libraries not usable for this target (dev package missing / not linkable?)."
    return 1
}

# For a backend installed without a usable .pc: synthesize one, and enable only when the standard probe then passes.
ffmpeg_enable_via_synth_pkgconfig() {
    local feature="$1" pkg_name="$2" headers="$3" symbols="$4"
    local prefix="$5" cflags="$6" libs="$7" version="${8:-1.0}"
    [ -n "${version}" ] || version="1.0"

    # Not inside ${prefix}: the backend prefix is mounted read-only, and the .pc's paths are absolute anyway.
    local pc_dir="${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}/synth-pkgconfig"
    if ! mkdir -p "${pc_dir}"; then
        pc_dir="$(mktemp -d 2>/dev/null)/pkgconfig"
        mkdir -p "${pc_dir}" 2>/dev/null || { echo "  synth-pc ${feature}: no writable dir for synthesized .pc"; return 1; }
    fi
    if ! cat > "${pc_dir}/${pkg_name}.pc" <<EOF
prefix=${prefix}
Name: ${pkg_name}
Description: ${feature} (pkg-config synthesized by build-ffmpeg.sh)
Version: ${version}
Cflags: ${cflags}
Libs: ${libs}
EOF
    then
        echo "  synth-pc ${feature}: FAILED to write ${pc_dir}/${pkg_name}.pc"
        return 1
    fi
    echo "  synth-pc ${feature}: wrote ${pc_dir}/${pkg_name}.pc (Cflags='${cflags}' Libs='${libs}')"
    # Prepend to shadow a broken vendor .pc, and export so configure's child process resolves the same module.
    export PKG_CONFIG_PATH="${pc_dir}${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
    ffmpeg_probe_pkg_config_feature "${feature}" "${pkg_name}" "${headers}" "${symbols}"
}
