#!/usr/bin/env bash
# package-image-wiring.sh - what the package stage does to the toolchain and runtime a
# consumer sees, sourced by setup-package-image.sh. Split out of it on 2026-09-26, when
# these fixes took that file past the size gate. Sets no shell options.

# Ubuntu's libgtk-4-1 (install-deps.sh) is the only thing that pulls a distro GStreamer
# 1.28 runtime back in beside /opt/gstreamer's (BACKLOG CON21). Where our prefix carries
# its own GTK 4 (amd64) nothing loads either, so both go; arm64/riscv64 build GStreamer
# without GTK, and their libgstgtk4.so needs Ubuntu's (BACKLOG § Deliberate).
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

# The tools that read what clang wrote (module PCMs, raw profiles, DWARF) come from clang's
# own LLVM: PATH's were the distro's LLVM 21 (BACKLOG CON15). /usr/local/bin precedes
# /usr/bin. clang-format stays the distro's on purpose, its version is a formatting verdict
# the fleet pins; llvm-config too, since llvm-target's libLLVM is not all-targets.
LLVM_TARGET_TOOLS="clang-tidy run-clang-tidy clang-apply-replacements clangd clang-scan-deps
    llvm-profdata llvm-cov llvm-symbolizer llvm-nm llvm-objdump llvm-objcopy llvm-strip
    llvm-readelf llvm-readobj llvm-dwarfdump llvm-addr2line llvm-cxxfilt llvm-size llvm-strings
    ld.lld lld"

wire_clang_llvm_tools() {
    local dir tool n=0
    dir="$(dirname "$(readlink -f /usr/bin/clang)")"
    for tool in ${LLVM_TARGET_TOOLS}; do
        [ -x "${dir}/${tool}" ] || { echo "WARN: ${dir} has no ${tool}; PATH keeps the distro's"; continue; }
        ln -sfn "${dir}/${tool}" "/usr/local/bin/${tool}"
        n=$((n + 1))
    done
    echo "OK: ${n} LLVM tools on PATH from ${dir}, clang's own"
}

# A bare clang selects ${GCC_PREFIX} through <native-triple>-<driver>.cfg in the directory it was
# REACHED through, so each one linking to it gets the pair (CON16, CON39; docs/linux-cross-builds.md#clang-cross-wrappers).
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

# atheris' find_libfuzzer.sh looks for lib/linux/libclang_rt.<rt>-<arch>.a, the layout before
# per-target runtime directories, and derives the sanitizers it merges from it (BACKLOG CON38).
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
