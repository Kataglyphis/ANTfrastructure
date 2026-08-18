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

    # Make the amd64 prefix SELF-CONTAINED (root fix for the 2026-08-11
    # franken-toolchain incident): an apt LLVM tree ships lib/ as dev SYMLINKS
    # into /usr/lib/x86_64-linux-gnu — the runtime sonames (libLLVM.so.22.1,
    # libclang-cpp.so.22.1) never entered the prefix, so the shipped clang
    # silently bound to whatever ambient libLLVM the consuming image carried.
    # Copy the multiarch runtime sonames next to the driver (no-op when the
    # source-built prefix already ships real files), then HARD-GATE below:
    # every LLVM-family NEEDED of the shipped binaries must resolve inside the
    # prefix. Dockerfile.package keeps a matching copy as belt-and-braces for
    # older sdk artifacts.
    mkdir -p /opt/llvm-target/lib
    for _so in /usr/lib/x86_64-linux-gnu/libLLVM*.so.2* \
               /usr/lib/x86_64-linux-gnu/libclang-cpp*.so.2* \
               /usr/lib/x86_64-linux-gnu/libclang*.so.2*; do
        [ -e "${_so}" ] || continue
        _b="$(basename "${_so}")"
        if [ ! -e "/opt/llvm-target/lib/${_b}" ]; then
            # -e is FALSE for a dangling symlink (the apt tree links
            # lib/<soname> into the multiarch dir it was copied away from) —
            # rm it first or cp refuses "not writing through dangling
            # symlink". A REAL file short-circuits the copy.
            rm -f "/opt/llvm-target/lib/${_b}"
            cp -a "${_so}" "/opt/llvm-target/lib/${_b}"
        fi
    done

    # NEEDED walk: every DT_NEEDED of the prefix's binaries/libs must resolve
    # inside <prefix>/lib or (for non-LLVM system deps like libc/libstdc++/
    # zlib) against the base image's ldconfig cache. The cache is captured
    # ONCE into a variable and matched with `case` — `ldconfig -p | grep -q`
    # would die of SIGPIPE under pipefail.
    _ldcache="$(ldconfig -p 2>/dev/null || true)"
    _missing=""
    for _e in /opt/llvm-target/bin/* /opt/llvm-target/lib/*.so*; do
        [ -f "${_e}" ] || continue
        LC_ALL=C readelf -h "${_e}" >/dev/null 2>&1 || continue
        for _n in $(LC_ALL=C readelf -d "${_e}" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p'); do
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
