#!/usr/bin/env bash
# materialize-llvm-target.sh — select/repair the per-arch native Clang at the
# canonical /opt/llvm-target (DF2 2026-08-18: extracted VERBATIM from the
# 86-line inline RUN in Dockerfile.sdk; logic unchanged, one comment-preserving
# home instead of a backslash-escaped string).
#
# The SHARED compiler stage installs each cross target-clang into
# /opt/llvm-target-<arch> (a single fixed prefix would clobber across arches
# and leak one arch's clang into every image). Select THIS build's arch; amd64
# is native so it ships the host LLVM as its target-native clang. Downstream
# (media/android/package) then inherits a correct, self-contained
# /opt/llvm-target for every arch — the package image COPYs it to
# /usr/local/llvm-target so each runtime ships its own native clang.
#
# Inputs (env): TARGET_ARCH / TARGETARCH, LLVM_RELEASE.
# Requires: /opt/scripts/core/platform.sh (assert_elf_arch).
set -euo pipefail

# One reader of DT_NEEDED for both the amd64 fill and the self-containment walk.
_elf_needed() {
    LC_ALL=C readelf -d "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p'
}

# Materialise into <prefix>/lib exactly the LLVM-family sonames the prefix's own
# objects DT_NEED and cannot resolve there, from <src>; repeat until a round adds
# nothing, because a filled lib brings its own NEEDED.
# docs/artifact-copy-completeness.md#the-llvm-target-prefix-fills-what-it-needs-and-nothing-else
_llvm_target_fill_needed() {
    local prefix="$1" src="$2" round=0 added=1 e n
    while [ "${added}" = 1 ] && [ "${round}" -lt 4 ]; do
        added=0
        round=$((round + 1))
        for e in "${prefix}"/bin/* "${prefix}"/lib/*.so*; do
            [ -f "${e}" ] || continue
            for n in $(_elf_needed "${e}"); do
                case "${n}" in libLLVM*|libclang*) ;; *) continue ;; esac
                [ ! -e "${prefix}/lib/${n}" ] || continue
                [ -e "${src}/${n}" ] || continue
                rm -f "${prefix}/lib/${n}"
                cp -a "${src}/${n}" "${prefix}/lib/${n}"
                added=1
            done
        done
    done
}

_arch="${TARGET_ARCH:-${TARGETARCH:-amd64}}"
_major="${LLVM_RELEASE%%.*}"
rm -rf /opt/llvm-target

if [ "${_arch}" = "amd64" ]; then
    # Ship the SOURCE-built host clang (LLVM_RELEASE) at /usr/local/llvm-<major>
    # as amd64's target-native clang. /usr/lib/llvm-<major> is the APT bootstrap
    # clang (apt.llvm.org LAGS point releases) and must NOT become the shipped
    # clang, or amd64 ships a stale clang that mismatches LLVM_RELEASE (caught
    # by the runtime clang-version smoke). Prefer source; fall back to the apt
    # path / PATH clang only if the source build is somehow absent.
    _hostllvm=""
    for _cand in "/usr/local/llvm-${_major}" "/usr/lib/llvm-${_major}"; do
        if [ -x "${_cand}/bin/clang" ]; then _hostllvm="${_cand}"; break; fi
    done
    if [ -z "${_hostllvm}" ]; then
        _cc="$(command -v clang || true)"
        [ -n "${_cc}" ] && _hostllvm="$(dirname "$(dirname "$(readlink -f "${_cc}")")")"
    fi
    [ -n "${_hostllvm}" ] && [ -d "${_hostllvm}" ] || {
        echo "ERROR: host LLVM dir not found for amd64 (tried /usr/local/llvm-${_major}, /usr/lib/llvm-${_major})"; exit 1; }
    echo "amd64 target-native clang from ${_hostllvm} ($("${_hostllvm}/bin/clang" --version 2>/dev/null | head -1))"
    cp -a "${_hostllvm}" /opt/llvm-target

    mkdir -p /opt/llvm-target/lib
    _llvm_target_fill_needed /opt/llvm-target /usr/lib/x86_64-linux-gnu

    # The cache is captured ONCE and matched with `case` -- `ldconfig -p | grep -q`
    # would die of SIGPIPE under pipefail.
    _ldcache="$(ldconfig -p 2>/dev/null || true)"
    _missing=""
    for _e in /opt/llvm-target/bin/* /opt/llvm-target/lib/*.so*; do
        [ -f "${_e}" ] || continue
        LC_ALL=C readelf -h "${_e}" >/dev/null 2>&1 || continue
        for _n in $(_elf_needed "${_e}"); do
            [ ! -e "/opt/llvm-target/lib/${_n}" ] || continue
            case "${_n}" in
                libLLVM*|libclang*) _missing="${_missing} ${_e##*/}:${_n}" ;;
                *) case "${_ldcache}" in
                       *"${_n} ("*) ;;
                       *) _missing="${_missing} ${_e##*/}:${_n}" ;;
                   esac ;;
            esac
        done
    done
    [ -z "${_missing}" ] || {
        echo "ERROR: /opt/llvm-target is NOT self-contained; unresolved NEEDED (binary:lib):${_missing}" >&2; exit 1; }
    echo "amd64 /opt/llvm-target NEEDED walk clean: all LLVM-family sonames resolve inside the prefix"
elif [ -d "/opt/llvm-target-${_arch}" ]; then
    mv "/opt/llvm-target-${_arch}" /opt/llvm-target
else
    echo "ERROR: no target-clang toolchain for ${_arch} at /opt/llvm-target-${_arch}"; exit 1
fi

for _d in /opt/llvm-target-*; do [ -e "${_d}" ] && rm -rf "${_d}"; done

# Real gate: the old `clang --version || true` was decorative on
# arm64/riscv64 — a target-arch ELF cannot exec on the amd64 builder, so the
# || true always fired and only file existence was implicitly checked. Assert
# executability + the ELF machine type actually matching this build's
# TARGET_ARCH instead (assert_elf_arch/readelf never executes the binary, so
# it works for foreign arches; it hard-fails on mismatch).
test -x /opt/llvm-target/bin/clang || {
    echo "ERROR: /opt/llvm-target/bin/clang missing or not executable for ${_arch}" >&2; exit 1; }
# shellcheck disable=SC1091
source /opt/scripts/core/platform.sh
assert_elf_arch /opt/llvm-target/bin/clang "${_arch}"
echo "Resolved /opt/llvm-target for ${_arch}:"; /opt/llvm-target/bin/clang --version 2>&1 | head -1 || true
