#!/usr/bin/env bash
# Package-stage fixes to the toolchain and runtime a consumer sees; sourced by setup-package-image.sh.

clear_unmounted_apt_lists() {
    mountpoint -q /var/lib/apt || rm -rf /var/lib/apt/lists/*
}

# Empty where the prefix has no GTK 4: arm64 and riscv64 cross-build GStreamer without it.
prefix_gtk4_lib() {
    find "${GSTREAMER_PREFIX:-/opt/gstreamer}/lib" -maxdepth 2 -name libgtk-4.so.1 -print -quit 2>/dev/null || true
}

# The prefix's own gdk-pixbuf-2.0.pc resolves ahead of the distro's; riscv64 lacked its libtiff-4 (2026-10-21).
prefix_pixbuf_dev_packages() {
    local pc
    pc="$(find "${GSTREAMER_PREFIX:-/opt/gstreamer}/lib" -maxdepth 3 -name gdk-pixbuf-2.0.pc -print -quit 2>/dev/null || true)"
    [ -n "${pc}" ] || return 0
    if grep -q -e 'libpng' "${pc}"; then echo libpng-dev; fi
    if grep -q -e 'libjpeg' "${pc}"; then echo libjpeg-dev; fi
    if grep -q -e 'libtiff-4' "${pc}"; then echo libtiff-dev; fi
    return 0
}

# gtk4-rs builds against the GTK 4 the image runs; the prefix's gtk4.pc lacks only these two Requires (CON129).
gtk4_dev_packages() {
    if [ -n "$(prefix_gtk4_lib)" ]; then
        printf '%s\n' libgraphene-1.0-dev libvulkan-dev
    else
        printf '%s\n' libgtk-4-dev
    fi
    prefix_pixbuf_dev_packages
}

# The floor is gtk4-rs 0.11's v4_10 (OxidANT's GTK GUI); --libs resolves every Requires, ldd -r every symbol.
verify_gtk4_dev_surface() {
    local floor="${1:-4.10}" lib unresolved
    if ! pkg-config --atleast-version="${floor}" gtk4 2>/dev/null || ! pkg-config --cflags --libs gtk4 >/dev/null; then
        echo "ERROR: gtk4 >= ${floor} with every Requires is not reachable: $(pkg-config --modversion gtk4 2>&1 | head -n 1)" >&2
        return 1
    fi
    lib="$(pkg-config --variable=libdir gtk4)/libgtk-4.so.1"
    unresolved="$(ldd -r "${lib}" 2>&1 | grep -E 'not found|undefined symbol' || true)"
    if [ -n "${unresolved}" ]; then
        echo "ERROR: ${lib} does not load: ${unresolved}" >&2
        return 1
    fi
    echo "OK: gtk4 $(pkg-config --modversion gtk4) at ${lib}: every Requires, NEEDED and symbol resolves"
}

# riscv64's GStreamer cross build falls back to its own GLib; a newer distro GLib serves it, GTK 4 and PyGObject (CON129).
yield_older_prefix_glib() {
    local sys="${1:-}" ours theirs dir
    [ -n "${sys}" ] || sys="/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null)"
    ours="$(find "${GSTREAMER_PREFIX:-/opt/gstreamer}/lib" -maxdepth 2 -name libglib-2.0.so.0 -print -quit 2>/dev/null || true)"
    [ -n "${ours}" ] || { echo "KEEP: no GLib in the GStreamer prefix"; return 0; }
    ours="$(readlink -f "${ours}")"
    theirs="$(readlink -f "${sys}/libglib-2.0.so.0" 2>/dev/null || true)"
    if [ ! -f "${theirs}" ] || [ "$(printf '%s\n' "${theirs##*/}" "${ours##*/}" | sort -V | tail -n 1)" = "${ours##*/}" ]; then
        echo "KEEP: the prefix's ${ours##*/} is not older than ${theirs:-a distro GLib}"
        return 0
    fi
    dir="${ours%/*}"
    rm -f "${dir}"/lib{glib,gobject,gio,gmodule,gthread,girepository}-2.0.so* \
        "${dir}"/pkgconfig/{glib,gobject,gio,gio-unix,gmodule,gmodule-export,gmodule-no-export,gthread,girepository}-2.0.pc
    echo "OK: ${ours##*/} left ${dir}; ${theirs##*/} serves GStreamer, GTK 4 and PyGObject"
}

# libgtk-4-1 pulls a distro GStreamer beside ours; drop both only where our prefix has its own GTK 4.
drop_redundant_distro_gtk4() {
    local ours extra
    local -a pkgs=(libgtk-4-1 libgstreamer1.0-0 libgstreamer-plugins-base1.0-0
        libgstreamer-gl1.0-0 libgstreamer-plugins-extra1.0-0)
    ours="$(prefix_gtk4_lib)"
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

# PATH puts /opt/vulkan/active/bin first, and the SDK ships DXC's LLVM 3.7 llvm-tblgen; a clashing name moves to vulkan-sdk-<name> (BACKLOG CON71).
unshadow_pinned_llvm_tools() {
    local pinned="${1:-}" vk f
    local -a moved=()
    [ -n "${pinned}" ] || pinned="$(dirname "$(readlink -f /usr/bin/clang)")"
    vk="$(readlink -f "${2:-/opt/vulkan/active/bin}" 2>/dev/null || true)"
    [ -n "${vk}" ] && [ -d "${vk}" ] || { echo "OK: no Vulkan SDK bin at ${2:-/opt/vulkan/active/bin}; nothing can shadow ${pinned}"; return 0; }
    while IFS= read -r f; do
        [ -x "${pinned}/${f##*/}" ] || continue
        mv "${f}" "${vk}/vulkan-sdk-${f##*/}"
        moved+=("${f##*/}")
    done < <(find "${vk}" -maxdepth 1 -type f -perm -u+x | LC_ALL=C sort)
    echo "OK: ${#moved[@]} Vulkan SDK name(s) that shadowed the pinned LLVM renamed to vulkan-sdk-<name>: ${moved[*]:-none}"
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

# <env file> <version key> <sha key>: "<version> <sha>", or an error naming both keys.
_pwsh_pins() {
    local version sha
    version="$(sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1)"
    sha="$(sed -n "s/^$3=//p" "$1" 2>/dev/null | head -n 1)"
    if [ -n "${version}" ] && [ -n "${sha}" ]; then
        printf '%s %s\n' "${version}" "${sha}"
        return 0
    fi
    echo "ERROR: $2 or $3 is not pinned in $1" >&2
    return 1
}

# <url> <sha> <dest>: the verified release asset (a .tar.gz, else a zip) in a fresh <dest>; the caller sources downloads.sh.
_pwsh_unpack_verified() {
    local url="$1" sha="$2" dest="$3" dir rc=0
    dir="$(mktemp -d)" || return 1
    download_verified_file "${url}" "${sha}" "${dir}/asset" && rm -rf "${dest}" && mkdir -p "${dest}" || rc=1
    case "${rc}:${url}" in
        0:*.tar.gz) tar -xzf "${dir}/asset" -C "${dest}" || rc=1 ;;
        0:*) unzip -q "${dir}/asset" -d "${dest}" || rc=1 ;;
    esac
    rm -rf "${dir}"
    [ "${rc}" -eq 0 ] || echo "ERROR: ${url##*/} did not download, verify or unpack from ${url}" >&2
    return "${rc}"
}

# <pin> <what> <pwsh> <command>: fails unless pwsh answers <command> with the pin.
_pwsh_reports() {
    local report
    report="$("$3" -NoLogo -NoProfile -NonInteractive -Command "$4" 2>&1)" || true
    [ "${report}" = "$1" ] && return 0
    echo "ERROR: $2 reports '${report}', the pin is $1" >&2
    return 1
}

# pwsh at PWSH_VERSION for the tests that drive it (OrchestrANT's benchmark harness, CON131); upstream builds no riscv64 one.
install_pwsh() {
    local env_file="${1:-/opt/scripts/core/versions.env}" prefix="${2:-/opt/microsoft/powershell/7}"
    local bindir="${3:-/usr/local/bin}" machine="${4:-}" arch key version sha
    [ -n "${machine}" ] || machine="$(uname -m)"
    case "${machine}" in
        x86_64)  arch=x64;   key=PWSH_LINUX_X64_SHA256 ;;
        aarch64) arch=arm64; key=PWSH_LINUX_ARM64_SHA256 ;;
        *) echo "NOTE: PowerShell publishes no ${machine} build; no pwsh on this arch (docs/image-decisions.md)"; return 0 ;;
    esac
    read -r version sha < <(_pwsh_pins "${env_file}" PWSH_VERSION "${key}") || return 1
    _pwsh_unpack_verified "https://github.com/PowerShell/PowerShell/releases/download/v${version}/powershell-${version}-linux-${arch}.tar.gz" \
        "${sha}" "${prefix}" || return 1
    chmod 0755 "${prefix}/pwsh" && mkdir -p "${bindir}" && ln -sf "${prefix}/pwsh" "${bindir}/pwsh" || return 1
    _pwsh_reports "${version}" pwsh "${bindir}/pwsh" '$PSVersionTable.PSVersion.ToString()' || return 1
    echo "OK: pwsh ${version} at ${bindir}/pwsh (${arch})"
    install_psscriptanalyzer "${env_file}" "${prefix}"
}

# PSScriptAnalyzer in $PSHOME/Modules, on every user's module path: the lab's pwsh tests lint with it (CON131).
install_psscriptanalyzer() {
    local env_file="$1" prefix="$2" version sha mod
    read -r version sha < <(_pwsh_pins "${env_file}" PSSCRIPTANALYZER_VERSION PSSCRIPTANALYZER_NUPKG_SHA256) || return 1
    mod="${prefix}/Modules/PSScriptAnalyzer/${version}"
    rm -rf "${prefix:?}/Modules/PSScriptAnalyzer"
    _pwsh_unpack_verified "https://github.com/PowerShell/PSScriptAnalyzer/releases/download/${version}/PSScriptAnalyzer.${version}.nupkg" \
        "${sha}" "${mod}" || return 1
    # The nupkg's packaging parts are not the module's; Install-Module drops them too.
    rm -rf "${mod:?}/_rels" "${mod:?}/package" "${mod:?}/[Content_Types].xml" "${mod:?}/PSScriptAnalyzer.nuspec"
    _pwsh_reports "${version}" "pwsh's PSScriptAnalyzer" "${prefix}/pwsh" \
        '(Get-Module -ListAvailable -Name PSScriptAnalyzer).Version.ToString()' || return 1
    echo "OK: PSScriptAnalyzer ${version} in ${prefix}/Modules"
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
