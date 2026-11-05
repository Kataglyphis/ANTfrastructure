#!/usr/bin/env bash
# QNN SDK, arm64 only: a zip staged in linux/qnn-sdk/ wins, else the pinned Community zip is fetched. Mirrors Resolve-QnnSdk on Windows.

[ -n "${_QNN_SDK_LOADED:-}" ] && return 0
_QNN_SDK_LOADED=1

: "${QNN_SDK_LINUX_LIBDIR:=aarch64-oe-linux-gcc11.2}"
# community (default) fetches QNN_SDK_VERSION's public zip when nothing is staged; drop uses only a staged zip. docs/qnn-linux.md#staging
: "${QNN_SDK_SOURCE:=community}"
# A cache mount in Dockerfile.media; outside one the zip lands in the layer, so keep the mount.
: "${QNN_SDK_CACHE_DIR:=/var/cache/qnn-sdk}"

qnn_community_zip_url() {
    printf 'https://softwarecenter.qualcomm.com/api/download/software/sdks/Qualcomm_AI_Runtime_Community/All/%s/v%s.zip\n' "$1" "$1"
}

# Echoes the pinned zip's path after a verified fetch (asset mirror first); empty = no pin or QNN_SDK_SOURCE=drop.
qnn_pinned_community_zip() {
    local version="${QNN_SDK_VERSION:-}" sha="${QNN_SDK_ZIP_SHA256:-}" dest
    [ "${QNN_SDK_SOURCE}" = community ] || { info "QNN: QNN_SDK_SOURCE=${QNN_SDK_SOURCE}, the pinned Community zip is not fetched" >&2; return 0; }
    [ -n "${version}" ] || { info "QNN: QNN_SDK_VERSION empty, nothing to fetch" >&2; return 0; }
    [ -n "${sha}" ] || err "QNN: QNN_SDK_VERSION=${version} without QNN_SDK_ZIP_SHA256 -- a pin moves with its sha (bump_versions.py spec_qnn_sdk)"
    command -v download_verified_file >/dev/null 2>&1 || err "QNN: download_verified_file is not loaded (01-core/downloads.sh)"
    dest="${QNN_SDK_CACHE_DIR}/qairt-${version}.zip"
    mkdir -p "${QNN_SDK_CACHE_DIR}"
    if [ -f "${dest}" ] && download_verify_sha256 "${sha,,}" "${dest}" >/dev/null 2>&1; then
        info "QNN: pinned Community zip ${version} already in ${QNN_SDK_CACHE_DIR}" >&2
    else
        info "QNN: fetching the pinned Community zip ${version} (asset mirror first)" >&2
        download_verified_file "$(qnn_community_zip_url "${version}")" "${sha,,}" "${dest}" \
            || err "QNN: the Community zip ${version} could not be fetched or did not match QNN_SDK_ZIP_SHA256"
    fi
    printf '%s\n' "${dest}"
}

# Echoes QNN_HOME (empty = QNN off); logs go to stderr because info() writes to the captured stdout.
resolve_qnn_sdk() {
    local drop_dir="${1:-/opt/scripts/qnn-sdk}"
    local arch
    arch="$(arch_oci)"

    [ "${arch}" = "arm64" ] || { info "QNN: arm64-only on Linux (arch=${arch}), skipping" >&2; return 0; }

    local zips
    zips="$(find "$drop_dir" -maxdepth 1 -name '*.zip' -type f 2>/dev/null | sort)" || true
    local zip_count
    zip_count="$(printf '%s\n' "$zips" | grep -c . 2>/dev/null)" || zip_count=0

    if [ "$zip_count" -gt 1 ]; then
        err "QNN: exactly one SDK zip may sit in ${drop_dir} (found ${zip_count})"
    fi

    local zip
    if [ "$zip_count" -eq 0 ]; then
        zip="$(qnn_pinned_community_zip)"
        if [ -z "${zip}" ]; then
            info "QNN: no SDK zip in ${drop_dir} and no pinned Community zip — QNN off (supported state)" >&2
            return 0
        fi
    else
        zip="$(printf '%s\n' "$zips" | head -1)"
    fi

    local sha="${QNN_SDK_ZIP_SHA256:-}"
    if [ -n "$sha" ]; then
        local actual
        actual="$(sha256sum "$zip" | awk '{print $1}')"
        if [ "${actual^^}" != "${sha^^}" ]; then
            err "QNN: SDK zip SHA256 mismatch: expected ${sha}, got ${actual}"
        fi
        info "QNN: SDK zip SHA256 verified (QNN_SDK_ZIP_SHA256)" >&2
    else
        warn "QNN: QNN_SDK_ZIP_SHA256 empty — extracting UNVERIFIED (pin in versions.env)"
    fi

    : "${QNN_SDK_EXTRACT_DIR:=/tmp/qnn-sdk-extract}"
    local extract_dir="${QNN_SDK_EXTRACT_DIR}"
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

qnn_has_runtime_libraries() {
    find "$1" -maxdepth 1 -name "$2" -type f 2>/dev/null | grep -q .
}

# stage_qnn_runtime <qnn_home> <target_dir> [provider_pattern]: mirrors Copy-QnnRuntime; a named provider must exist.
stage_qnn_runtime() {
    local qnn_home="${1:?qnn_home required}"
    local target_dir="${2:?target dir required}"
    local provider_pattern="${3:-}"

    local lib_dir="$target_dir"
    if [ -d "${target_dir}/lib" ]; then
        lib_dir="${target_dir}/lib"
        if ! qnn_has_runtime_libraries "${lib_dir}" '*.so*'; then
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
