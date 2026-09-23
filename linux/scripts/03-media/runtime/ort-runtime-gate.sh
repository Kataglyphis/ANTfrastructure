#!/usr/bin/env bash
# ort-runtime-gate.sh - no apt ONNX Runtime, and every libonnxruntime on a loader path is a chain file.
# Source-only (configure-runtime.sh, validate-media-runtime.sh). NOT covered: wheels, dlopen by path.

# ort_is_distro_package <name[:arch]>: 0 for an apt package that ships ONNX Runtime.
ort_is_distro_package() {
    case "${1%%:*}" in
        libonnxruntime*|onnxruntime*|python3-onnxruntime*) return 0 ;;
    esac
    return 1
}

# ort_is_denied_soname <soname>: 0 for an ORT soname -- the chain builds it, apt may never repair it.
ort_is_denied_soname() {
    case "$1" in
        libonnxruntime*) return 0 ;;
    esac
    return 1
}

# ort_dpkg_findings <dpkg-query -W -f='${Status}\t${Package}\n' output>: one line per ORT
# package whose files are on disk.
ort_dpkg_findings() {
    local status pkg
    while IFS=$'\t' read -r status pkg; do
        case "${status}" in
            *" installed"|*" unpacked"|*" half-configured"|*" half-installed"|*" triggers-"*) ;;
            *) continue ;;
        esac
        if ort_is_distro_package "${pkg}"; then
            echo "APT ${pkg} is installed (${status}): a distro ONNX Runtime beside the chain build"
        fi
    done <<< "$1"
    return 0
}

# ort_apt_plan_findings <apt-get -s install output>: one line per ORT package the plan would install.
ort_apt_plan_findings() {
    local verb pkg rest
    while IFS=' ' read -r verb pkg rest; do
        [ "${verb}" = "Inst" ] || continue
        if ort_is_distro_package "${pkg}"; then
            echo "APT-PLAN ${pkg} would be installed (${rest})"
        fi
    done <<< "$1"
    return 0
}

# ort_apt_plan_gate <package>...: simulate the install a resolver is about to run; 1 when the plan pulls
# a distro ORT. A plan apt cannot compute proves nothing -- ort_dpkg_gate is the backstop.
ort_apt_plan_gate() {
    local p
    local -a names=()
    for p in "$@"; do
        if command -v cross_resolve_target_package >/dev/null 2>&1; then
            p="$(cross_resolve_target_package "${p}" || printf '%s' "${p}")"
        fi
        [ -z "${p}" ] || names+=("${p}")
    done
    [ "${#names[@]}" -gt 0 ] || return 0
    _ort_fail_on "FAIL: this apt install would pull a distro ONNX Runtime:" \
        "$(ort_apt_plan_findings "$(apt-get -s install --no-install-recommends "${names[@]}" 2>/dev/null || true)")"
}

# ort_dpkg_gate: 1 when a distro ORT package is on disk, however it got there.
ort_dpkg_gate() {
    # shellcheck disable=SC2016 # dpkg-query's own ${field} syntax, not bash's
    _ort_fail_on "FAIL: a distro ONNX Runtime is installed beside the chain build:" \
        "$(ort_dpkg_findings "$(dpkg-query -W -f='${Status}\t${Package}\n' 2>/dev/null || true)")"
}

# _ort_fail_on <headline> <findings>: 0 when <findings> is empty, else both to stderr and 1.
_ort_fail_on() {
    [ -n "$2" ] || return 0
    printf '%s\n%s\n' "$1" "$2" >&2
    return 1
}

# ort_conf_dirs <ld.so.conf.d>: every directory its *.conf files hand to ldconfig.
ort_conf_dirs() {
    local conf line
    for conf in "$1"/*.conf; do
        [ -f "${conf}" ] || continue
        while IFS= read -r line || [ -n "${line}" ]; do
            line="${line%%#*}"
            line="${line//[[:space:]]/}"
            case "${line}" in ""|include*) continue ;; esac
            printf '%s\n' "${line}"
        done < "${conf}"
    done
}

# ort_loader_findings <chain-lib-dirs, ':'-separated> <dir>...: one line per ORT library in a
# loader-searched dir that is not a chain file, plus NONE when the chain holds no ORT at all.
ort_loader_findings() {
    local chain_list="$1" d f have=0
    local -a roots=() chains=()
    IFS=':' read -r -a chains <<< "${chain_list}"
    shift
    for d in "${chains[@]}"; do
        [ -n "${d}" ] && [ -d "${d}" ] || continue
        roots+=("$(readlink -f -- "${d}")")
        for f in "${d}"/libonnxruntime.so.*; do
            [ -f "${f}" ] && [ ! -L "${f}" ] && have=1
        done
    done
    [ "${have}" = 1 ] || echo "NONE no real libonnxruntime.so.* in the chain dirs (${chain_list})"
    for d in "$@"; do
        _ort_scan_dir "${d}" "${roots[@]}"
    done
}

# _ort_scan_dir <dir> <root>...: FOREIGN/DANGLING lines for the ORT libraries in one loader dir.
_ort_scan_dir() {
    local d="$1" f real
    shift
    [ -n "${d}" ] && [ -d "${d}" ] || return 0
    for f in "${d}"/libonnxruntime.so* "${d}"/libonnxruntime_providers_*.so*; do
        [ -e "${f}" ] || [ -L "${f}" ] || continue
        [ -e "${f}" ] || { echo "DANGLING ${f}"; continue; }
        real="$(readlink -f -- "${f}")"
        _ort_in_roots "${real}" "$@" || echo "FOREIGN ${f} -> ${real} (not a chain file)"
    done
    return 0
}

# _ort_in_roots <real> <root>...: 0 when <real> sits inside one of the roots.
_ort_in_roots() {
    local real="$1" r
    shift
    for r in "$@"; do
        case "${real}" in "${r}"/*) return 0 ;; esac
    done
    return 1
}

# ort_runtime_gate <chain-lib-dirs, ':'-separated>: fail unless the image's loader can only ever
# reach the chain ORT and no apt ORT is installed.
ort_runtime_gate() {
    local -a dirs=() ldp=()
    ort_dpkg_gate || return 1
    mapfile -t dirs < <(ort_conf_dirs /etc/ld.so.conf.d)
    IFS=':' read -r -a ldp <<< "${LD_LIBRARY_PATH:-}"
    _ort_fail_on "FAIL: a loader path reaches an ONNX Runtime that is not the chain build:" \
        "$(ort_loader_findings "$1" "${dirs[@]}" "${ldp[@]}" /lib /usr/lib /usr/local/lib)" || return 1
    echo "OK: every loader path reaches the chain ONNX Runtime only; no apt ONNX Runtime installed"
}
