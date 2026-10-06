#!/usr/bin/env bash
# Package-stage fixes to the toolchain and runtime a consumer sees; sourced by setup-package-image.sh.

# libgtk-4-1 pulls a distro GStreamer beside ours; drop both only where our prefix has its own GTK 4.
drop_redundant_distro_gtk4() {
    local ours extra
    local -a pkgs=(libgtk-4-1 libgstreamer1.0-0 libgstreamer-plugins-base1.0-0
        libgstreamer-gl1.0-0 libgstreamer-plugins-extra1.0-0)
    ours="$(find "${GSTREAMER_PREFIX:-/opt/gstreamer}/lib" -maxdepth 2 -name libgtk-4.so.1 -print -quit 2>/dev/null || true)"
    if [ -z "${ours}" ] || ! dpkg -s libgtk-4-1 >/dev/null 2>&1; then
        echo "KEEP: distro GTK 4 (${ours:-no GTK 4 in the GStreamer prefix}${ours:+, libgtk-4-1 not installed})"
        return 0
    fi
    extra="$(apt-get purge -s "${pkgs[@]}" | awk '/^Purg /{print $2}' | grep -vxF -f <(printf '%s\n' "${pkgs[@]}") || true)"
    if [ -n "${extra}" ]; then
        echo "WARN: KEEP distro GTK 4: purging it would also remove $(tr '\n' ' ' <<<"${extra}")"
        return 0
    fi
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${pkgs[@]}"
    echo "OK: dropped the distro GTK 4 and GStreamer runtime; ${ours} is the GTK 4"
}

# Unversioned names under <usr_bin> that resolve into a distro LLVM; a -NN name asks for one by name, rust-* are the distro rustc's.
llvm_distro_unversioned_names() {
    local usr_bin="${1:-/usr/bin}" f
    for f in "${usr_bin}"/*; do
        [ -L "${f}" ] || continue
        case "$(readlink -f "${f}")" in */lib/llvm-[0-9]*/bin/*) ;; *) continue ;; esac
        case "${f##*/}" in *-[0-9] | *-[0-9][0-9] | *-[0-9]*.py | rust-*) continue ;; esac
        printf '%s\n' "${f##*/}"
    done
}

# Every unversioned LLVM tool name is the pinned LLVM's (owner 2026-10-06); dpkg-divert keeps an apt run from undoing it.
wire_pinned_llvm_tools() {
    local clang="${1:-/usr/bin/clang}" usr_bin="${2:-/usr/bin}" local_bin="${3:-/usr/local/bin}"
    local stash="${4:-/usr/lib/distro-llvm-names}" dir tool name n=0 kept=0
    local -a gone=()
    dir="$(dirname "$(readlink -f "${clang}")")"
    mkdir -p "${stash}"
    for tool in "${dir}"/*; do
        name="${tool##*/}"
        [ -f "${tool}" ] && [ -x "${tool}" ] || continue
        case "${name}" in *.cfg | clang-[0-9]*) continue ;; esac
        [ "$(readlink -f "${usr_bin}/${name}" 2>/dev/null)" = "$(readlink -f "${tool}")" ] && continue
        ln -sfn "${tool}" "${local_bin}/${name}"
        n=$((n + 1))
    done
    while IFS= read -r name; do
        tool="${usr_bin}/${name}"
        dpkg-divert --local --rename --divert "${stash}/${name}" --add "${tool}" >/dev/null
        if [ -x "${dir}/${name}" ]; then
            ln -sfn "${dir}/${name}" "${tool}"
            kept=$((kept + 1))
        else
            gone+=("${name}")
        fi
    done < <(llvm_distro_unversioned_names "${usr_bin}")
    echo "OK: ${n} pinned LLVM tools linked into ${local_bin}; ${kept} distro name(s) in ${usr_bin} now point into ${dir}"
    [ "${#gone[@]}" -eq 0 ] || echo "OK: ${#gone[@]} name(s) the pinned LLVM lacks left ${usr_bin}, their -NN alias stays: ${gone[*]}"
}

# A bare clang selects ${GCC_PREFIX} via <native-triple>-<driver>.cfg beside the path it was reached through (docs/linux-cross-builds.md#clang-cross-wrappers).
write_clang_gcc_toolchain_cfg() {
    local link="${1:-/usr/bin/clang}" real dir triple drv d
    local -a link_dirs=("${@:2}")
    [ "${#link_dirs[@]}" -gt 0 ] || link_dirs=(/usr/bin /usr/local/bin)
    real="$(readlink -f "${link}")"
    dir="$(dirname "${real}")"
    [ -d "${GCC_PREFIX:?GCC_PREFIX is required}/lib/gcc" ] || { echo "ERROR: ${GCC_PREFIX} holds no GCC for clang to select" >&2; return 1; }
    triple="$("${dir}/clang" -print-target-triple)"
    while IFS= read -r d; do
        for drv in clang clang++; do
            printf -- '--gcc-toolchain=%s\n' "${GCC_PREFIX}" > "${d}/${triple}-${drv}.cfg"
        done
        echo "OK: ${d}/${triple}-clang{,++}.cfg select ${GCC_PREFIX}"
    done < <({ printf '%s\n' "${dir}"; find -L "${link_dirs[@]}" -maxdepth 1 -samefile "${real}" -printf '%h\n' 2>/dev/null || true; } | sort -u)
}

# atheris' find_libfuzzer.sh wants the pre-per-target lib/linux/libclang_rt.<rt>-<arch>.a names (CON38).
link_compiler_rt_legacy_names() {
    local clang="${1:-/usr/bin/clang}" resdir triple arch rt src n=0
    resdir="$("${clang}" -print-resource-dir)"
    triple="$("${clang}" -print-target-triple)"
    arch="${triple%%-*}"
    mkdir -p "${resdir}/lib/linux"
    for rt in fuzzer fuzzer_no_main fuzzer_interceptors asan ubsan_standalone ubsan_standalone_cxx; do
        src="libclang_rt.${rt}.a"
        [ -f "${resdir}/lib/${triple}/${src}" ] || src="libclang_rt.${rt}-${arch}.a"
        if [ ! -f "${resdir}/lib/${triple}/${src}" ]; then
            echo "WARN: ${resdir}/lib/${triple} has no libclang_rt.${rt}; no legacy name for it"
            continue
        fi
        ln -sfn "../${triple}/${src}" "${resdir}/lib/linux/libclang_rt.${rt}-${arch}.a"
        n=$((n + 1))
    done
    echo "OK: ${n} compiler-rt archives linked under ${resdir}/lib/linux for ${arch}"
}
