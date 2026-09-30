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

    if [ "${FFMPEG_PROBE_DEBUG:-0}" = "1" ]; then
        # `|| true`: this compile is expected to fail, and set -e would abort the build.
        _FFMPEG_LAST_PROBE_ERR="$("${cmd[@]}" 2>&1 >/dev/null || true)"
    fi
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
        # Without the multiarch dirs every cross codec probe fails.
        ffmpeg_append_cross_search_flags cmd
    fi
    if command -v ld.lld >/dev/null 2>&1 && { case "${USE_LLD:-true}" in 0|false|FALSE|no|NO|off|OFF) false ;; *) true ;; esac; }; then
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
