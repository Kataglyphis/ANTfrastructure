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

# A bare clang took the distro GCC's libstdc++ instead of ${GCC_PREFIX}'s, which built every
# library the image ships, so linking one failed (BACKLOG CON16). Clang reads
# <triple>-<driver>.cfg beside itself; the native triple's pair leaves --target builds alone.
write_clang_gcc_toolchain_cfg() {
    local dir triple drv
    dir="$(dirname "$(readlink -f /usr/bin/clang)")"
    [ -d "${GCC_PREFIX:?GCC_PREFIX is required}/lib/gcc" ] || { echo "ERROR: ${GCC_PREFIX} holds no GCC for clang to select" >&2; return 1; }
    triple="$("${dir}/clang" -print-target-triple)"
    for drv in clang clang++; do
        printf -- '--gcc-toolchain=%s\n' "${GCC_PREFIX}" > "${dir}/${triple}-${drv}.cfg"
    done
    echo "OK: ${dir}/${triple}-clang{,++}.cfg select ${GCC_PREFIX}"
}
