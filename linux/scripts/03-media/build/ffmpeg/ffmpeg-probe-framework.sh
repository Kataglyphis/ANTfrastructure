#!/usr/bin/env bash
# ffmpeg-probe-framework.sh - General FFmpeg dependency probe helpers
# Split out of build-ffmpeg.sh (pure structural refactor; no behavior change).
# Source-only helper; sourced by build-ffmpeg.sh — expects its set -euo pipefail and IFS.

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

    # pkg-config emits SPACE-delimited flags, but this script runs with a global
    # IFS=$'\n\t' (no space), so a bare `out_ref=(${words})` would NOT split on
    # spaces — a multi-flag string like "-I/a -I/b" collapses into ONE garbled
    # argv element, breaking every probe whose .pc returns >1 flag (freetype,
    # vpx, theora, svtav1, …). Force a whitespace IFS locally so the re-split
    # works regardless of the caller's IFS.
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

    if [ "${FFMPEG_PROBE_DEBUG:-0}" = "1" ]; then
        # `|| true`: the probe compile is EXPECTED to fail here (that's what we're
        # diagnosing); without it the failing command substitution trips set -e
        # and aborts the whole FFmpeg build.
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

    # Write the synthesized .pc to a WRITABLE scratch dir, NOT inside ${prefix}:
    # the backend prefix (e.g. /usr/local/lib/onnxruntime-cpu) is mounted
    # read-only in the ffmpeg stage, so mkdir there fails. The .pc's Cflags/Libs
    # are absolute paths, so the file itself can live anywhere on PKG_CONFIG_PATH.
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
    # Prepend so this shadows any broken vendor .pc already on the path, and
    # export it so FFmpeg's configure (a child process) resolves the same module.
    export PKG_CONFIG_PATH="${pc_dir}${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
    ffmpeg_probe_pkg_config_feature "${feature}" "${pkg_name}" "${headers}" "${symbols}"
}
