#!/usr/bin/env bash
# Moves this arch's native clang from its per-arch prefix to /opt/llvm-target, self-contained for later stages.
set -euo pipefail

# One reader of DT_NEEDED for the fill, the repair and the self-containment walk.
_elf_needed() {
    LC_ALL=C readelf -d "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p'
}

# The one owner of "this toolchain's own library", which the prefix must carry rather than borrow.
_is_llvm_family() {
    case "${1}" in libLLVM*|libclang*|liblldb*) return 0 ;; *) return 1 ;; esac
}

# Repeats until a round adds nothing. docs/artifact-copy-completeness.md#the-llvm-target-prefix-fills-what-it-needs-and-nothing-else
_llvm_target_fill_needed() {
    local prefix="$1" src="$2" round=0 added=1 e n
    while [ "${added}" = 1 ] && [ "${round}" -lt 4 ]; do
        added=0
        round=$((round + 1))
        for e in "${prefix}"/bin/* "${prefix}"/lib/*.so*; do
            [ -f "${e}" ] || continue
            for n in $(_elf_needed "${e}"); do
                _is_llvm_family "${n}" || continue
                [ ! -e "${prefix}/lib/${n}" ] || continue
                [ -e "${src}/${n}" ] || continue
                rm -f "${prefix}/lib/${n}"
                cp -a "${src}/${n}" "${prefix}/lib/${n}"
                added=1
            done
        done
    done
}

# Repairs against <root>, the copy's origin. docs/artifact-copy-completeness.md#a-copied-prefix-carries-links-that-only-resolved-where-it-came-from
_llvm_target_repair_links() {
    local prefix="$1" root="$2" links e real base
    links="$(find "${prefix}" -xtype l 2>/dev/null || true)"
    while IFS= read -r e; do
        [ -n "${e}" ] || continue
        real="$(readlink -f "${root}/${e#"${prefix}/"}" 2>/dev/null || true)"
        base="${real##*/}"
        if [ -n "${real}" ] && [ -d "${real}" ]; then
            rm -rf "${e}"; cp -a "${real}" "${e}"; continue
        fi
        if [ -n "${real}" ] && [ -f "${real}" ] && [ ! -e "${prefix}/lib/${base}" ] \
           && _is_llvm_family "${base}"; then
            rm -f "${prefix}/lib/${base}"
            cp -a "${real}" "${prefix}/lib/${base}"
        fi
        if [ -n "${base}" ] && [ -f "${prefix}/lib/${base}" ]; then
            # Not when the copy landed on the link's own path: relinking would point it at itself.
            [ "${prefix}/lib/${base}" = "${e}" ] \
                || ln -sfn "$(realpath -m --relative-to="${e%/*}" "${prefix}/lib/${base}")" "${e}"
        else
            rm -f "${e}"
        fi
    done <<< "${links}"
    links="$(find "${prefix}" -xtype l 2>/dev/null || true)"
    [ -z "${links}" ] || {
        echo "ERROR: ${prefix} still holds link(s) that resolve to nothing:" >&2
        printf '%s\n' "${links}" >&2; exit 1; }
}

_arch="${TARGET_ARCH:-${TARGETARCH:-amd64}}"
_major="${LLVM_RELEASE%%.*}"
rm -rf /opt/llvm-target

# The build host's arch, from dpkg rather than a literal amd64: this standalone script has no platform.sh yet.
_host_arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
_host_multiarch="$(gcc -dumpmachine 2>/dev/null || echo x86_64-linux-gnu)"

if [ "${_arch}" = "${_host_arch}" ]; then
    # Only a source-built clang at LLVM_RELEASE ships; the apt bootstrap tracks the branch head, so it is never a fallback.
    _hostllvm=""
    for _cand in "/opt/llvm-target-${_arch}" "/usr/local/llvm-${_major}"; do
        if [ -x "${_cand}/bin/clang" ]; then _hostllvm="${_cand}"; break; fi
    done
    [ -n "${_hostllvm}" ] && [ -d "${_hostllvm}" ] || {
        echo "ERROR: no SOURCE-built host LLVM for ${_arch} (tried /opt/llvm-target-${_arch}, /usr/local/llvm-${_major}). The apt bootstrap is not a substitute: it tracks the ${_major}.x branch head, not LLVM_RELEASE=${LLVM_RELEASE}." >&2; exit 1; }
    echo "${_arch} target-native clang from ${_hostllvm} ($("${_hostllvm}/bin/clang" --version 2>/dev/null | head -1))"
    cp -a "${_hostllvm}" /opt/llvm-target

    mkdir -p /opt/llvm-target/lib
    _llvm_target_repair_links /opt/llvm-target "${_hostllvm}"
    _llvm_target_fill_needed /opt/llvm-target "/usr/lib/${_host_multiarch}"

    # Capture the cache once and match with case: ldconfig -p | grep -q would SIGPIPE under pipefail.
    _ldcache="$(ldconfig -p 2>/dev/null || true)"
    _missing=""
    for _e in /opt/llvm-target/bin/* /opt/llvm-target/lib/*.so*; do
        [ -f "${_e}" ] || continue
        LC_ALL=C readelf -h "${_e}" >/dev/null 2>&1 || continue
        for _n in $(_elf_needed "${_e}"); do
            [ ! -e "/opt/llvm-target/lib/${_n}" ] || continue
            if _is_llvm_family "${_n}"; then
                _missing="${_missing} ${_e##*/}:${_n}"
            else
                case "${_ldcache}" in
                    *"${_n} ("*) ;;
                    *) _missing="${_missing} ${_e##*/}:${_n}" ;;
                esac
            fi
        done
    done
    [ -z "${_missing}" ] || {
        echo "ERROR: /opt/llvm-target is NOT self-contained; unresolved NEEDED (binary:lib):${_missing}" >&2; exit 1; }
    echo "amd64 /opt/llvm-target NEEDED walk clean: all LLVM-family sonames resolve inside the prefix"
elif [ -d "/opt/llvm-target-${_arch}" ]; then
    mv "/opt/llvm-target-${_arch}" /opt/llvm-target
    _llvm_target_repair_links /opt/llvm-target /opt/llvm-target
else
    echo "ERROR: no target-clang toolchain for ${_arch} at /opt/llvm-target-${_arch}"; exit 1
fi

for _d in /opt/llvm-target-*; do [ -e "${_d}" ] && rm -rf "${_d}"; done

# Check the ELF machine instead of running clang: a foreign-arch binary cannot execute on the builder.
test -x /opt/llvm-target/bin/clang || {
    echo "ERROR: /opt/llvm-target/bin/clang missing or not executable for ${_arch}" >&2; exit 1; }
# shellcheck disable=SC1091
source /opt/scripts/core/platform.sh
assert_elf_arch /opt/llvm-target/bin/clang "${_arch}"
echo "Resolved /opt/llvm-target for ${_arch}:"; /opt/llvm-target/bin/clang --version 2>&1 | head -1 || true
