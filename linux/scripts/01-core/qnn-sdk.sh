#!/usr/bin/env bash
# qnn-sdk.sh - Qualcomm QAIRT/QNN SDK resolution + runtime staging (Linux).
# Backlog QNN-LINUX: arm64-only, OPT-IN by staging the login-gated zip in
# linux/qnn-sdk/ (mounted at /opt/scripts/qnn-sdk on every heavy RUN). No zip
# = QNN off, on every framework. Mirrors Windows Resolve-QnnSdk / Copy-QnnRuntime
# (WindowsSourceBuild.Common.psm1, #121) so the Linux and Windows lanes stay
# in step. Loaded by media_common_init, and by tvm.sh / build-app-wheelhouse.sh
# via source_module.

[ -n "${_QNN_SDK_LOADED:-}" ] && return 0
_QNN_SDK_LOADED=1

: "${QNN_SDK_LINUX_LIBDIR:=aarch64-oe-linux-gcc11.2}"

# Resolves the staged QAIRT SDK. Echoes QNN_HOME on stdout; EMPTY = QNN off.
# info() writes to stdout (fd 1), so every log call here goes to stderr (>&2)
# to keep the $(...) capture clean. Mirrors Resolve-QnnSdk; asserts the same
# canaries (QnnInterface.h anchor, libQnnCpu.so, QNN_OP_STFT for ORT 1.29).
resolve_qnn_sdk() {
    local drop_dir="${1:-/opt/scripts/qnn-sdk}"
    local arch
    arch="$(arch_oci)"

    [ "${arch}" = "arm64" ] || { info "QNN: arm64-only on Linux (arch=${arch}), skipping" >&2; return 0; }

    local zips
    zips="$(find "$drop_dir" -maxdepth 1 -name '*.zip' -type f 2>/dev/null | sort)" || true
    local zip_count
    zip_count="$(printf '%s\n' "$zips" | grep -c . 2>/dev/null)" || zip_count=0

    if [ "$zip_count" -eq 0 ]; then
        info "QNN: no SDK zip in ${drop_dir} — QNN off (default, supported state)" >&2
        return 0
    fi
    if [ "$zip_count" -gt 1 ]; then
        err "QNN: exactly one SDK zip may sit in ${drop_dir} (found ${zip_count})"
    fi

    local zip
    zip="$(printf '%s\n' "$zips" | head -1)"

    local sha="${QNN_SDK_LINUX_ZIP_SHA256:-}"
    if [ -n "$sha" ]; then
        local actual
        actual="$(sha256sum "$zip" | awk '{print $1}')"
        if [ "${actual^^}" != "${sha^^}" ]; then
            err "QNN: SDK zip SHA256 mismatch: expected ${sha}, got ${actual}"
        fi
        info "QNN: SDK zip SHA256 verified (QNN_SDK_LINUX_ZIP_SHA256)" >&2
    else
        warn "QNN: QNN_SDK_LINUX_ZIP_SHA256 empty — extracting UNVERIFIED (pin in versions.env)"
    fi

    local extract_dir="${QNN_SDK_EXTRACT_DIR:-/tmp/qnn-sdk-extract}"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    unzip -q -o "$zip" -d "$extract_dir"

    local anchor
    anchor="$(find "$extract_dir" -path '*/QNN/QnnInterface.h' -type f 2>/dev/null | head -1)" || true
    if [ -z "$anchor" ]; then
        err "QNN: include/QNN/QnnInterface.h not found under ${extract_dir} — not a QAIRT SDK zip?"
    fi
    # anchor = .../include/QNN/QnnInterface.h → SDK root = parent of include/
    local qnn_home
    qnn_home="$(dirname "$(dirname "$(dirname "$anchor")")")"

    local lib_dir="${qnn_home}/lib/${QNN_SDK_LINUX_LIBDIR}"
    if [ ! -f "${lib_dir}/libQnnCpu.so" ]; then
        err "QNN: ${lib_dir}/libQnnCpu.so missing — SDK carries no ${QNN_SDK_LINUX_LIBDIR} backend"
    fi

    # ORT version compat canary: QNN_OP_STFT added in QNN API 2.25+, ORT 1.29 needs it.
    local op_def="${qnn_home}/include/QNN/QnnOpDef.h"
    if [ -f "$op_def" ] && ! grep -q 'QNN_OP_STFT' "$op_def"; then
        warn "QNN: SDK too old (QNN_OP_STFT missing) — QNN off. Stage QAIRT 2.25+ API."
        return 0
    fi

    printf '%s\n' "$qnn_home"
}

# Stage the QNN backend .so + hexagon-v* skel dirs into the framework lib dir.
# Mirrors Copy-QnnRuntime: finds the lib dir under <target_dir> (prefer
# <target_dir>/lib, else the first dir holding a .so, else create lib/).
# Args: <qnn_home> <target_dir> [provider_pattern] — when a pattern is given,
# the matching provider file must exist under the found lib dir (fail-loud).
stage_qnn_runtime() {
    local qnn_home="${1:?qnn_home required}"
    local target_dir="${2:?target dir required}"
    local provider_pattern="${3:-}"

    local lib_dir="$target_dir"
    if [ -d "${target_dir}/lib" ]; then
        lib_dir="${target_dir}/lib"
        if ! find "${lib_dir}" -maxdepth 1 -name '*.so*' -type f 2>/dev/null | grep -q .; then
            local first_dir
            first_dir="$(find "${target_dir}" -type f -name '*.so*' 2>/dev/null | head -1 | xargs -r dirname 2>/dev/null || true)"
            [ -n "${first_dir}" ] && lib_dir="${first_dir}"
        fi
    fi
    mkdir -p "${lib_dir}"

    if [ -n "$provider_pattern" ]; then
        local provider
        provider="$(find "$lib_dir" -maxdepth 1 -name "$provider_pattern" -type f 2>/dev/null | head -1)" || true
        if [ -z "$provider" ]; then
            err "QNN: ${provider_pattern} not found under ${lib_dir} although the QNN build flag was ON — the EP did not build"
        fi
    fi

    local sdk_lib="${qnn_home}/lib/${QNN_SDK_LINUX_LIBDIR}"
    local staged=0
    local so
    while IFS= read -r so; do
        [ -f "$so" ] || continue
        cp "$so" "${lib_dir}/"
        staged=$((staged + 1))
    done < <(find "$sdk_lib" -maxdepth 1 -name 'libQnn*.so' -type f 2>/dev/null || true)

    local skel_dir
    while IFS= read -r skel_dir; do
        [ -d "$skel_dir" ] || continue
        cp -a "$skel_dir" "${lib_dir}/"
    done < <(find "${qnn_home}/lib" -maxdepth 1 -type d -name 'hexagon-v*' 2>/dev/null || true)

    info "QNN: staged ${staged} backend .so + hexagon skel dirs into ${lib_dir}" >&2
}
