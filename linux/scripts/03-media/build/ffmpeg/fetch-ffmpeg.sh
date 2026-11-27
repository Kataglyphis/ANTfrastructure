#!/usr/bin/env bash
# FFmpeg's source into FFMPEG_SRC: the pinned tag verified by its archive's stream hash or its clone's commit; sourced by build-ffmpeg.sh.

# _ffmpeg_tarball_url <ref>: GitHub's archive of a branch, a 40-hex commit or a tag.
_ffmpeg_tarball_url() {
    case "$1" in
      main|master|develop) printf 'https://github.com/FFmpeg/FFmpeg/archive/refs/heads/%s.tar.gz\n' "$1" ;;
      *)
        if [[ "$1" =~ ^[0-9a-f]{40}$ ]]; then
            printf 'https://github.com/FFmpeg/FFmpeg/archive/%s.tar.gz\n' "$1"
        else
            printf 'https://github.com/FFmpeg/FFmpeg/archive/refs/tags/%s.tar.gz\n' "$1"
        fi
        ;;
    esac
}

# _ffmpeg_pinned_tag <ref>: true for FFMPEG_VERSION's tag, whose bytes FFMPEG_SHA256 and FFMPEG_TAG_COMMIT pin.
_ffmpeg_pinned_tag() {
    if [[ "$1" == "${FFMPEG_VERSION:-}" && ! "$1" =~ ^(main|master|develop)$ ]]; then return 0; fi
    return 1
}

# _ffmpeg_tarball <url> <ref>: the archive extracted into FFMPEG_SRC, the pinned tag's checked against FFMPEG_SHA256 first.
_ffmpeg_tarball() {
    local url="$1" ref="$2" archive
    if ! _ffmpeg_pinned_tag "${ref}"; then
        download_and_extract "${url}" "${FFMPEG_SRC}" 1
        return
    fi
    archive="$(mktemp "${TMPDIR:-/tmp}/ffmpeg-XXXXXX.tar.gz")" || return 1
    if ! download_verified_file "${url}" "${FFMPEG_SHA256}" "${archive}" stream; then rm -f "${archive}"; return 1; fi
    if ! tar -xf "${archive}" -C "${FFMPEG_SRC}" --strip-components=1; then rm -f "${archive}"; return 1; fi
    rm -f "${archive}"
    return 0
}

# _ffmpeg_clone <remote> <ref>: a shallow clone into FFMPEG_SRC; the pinned tag must land on FFMPEG_TAG_COMMIT.
_ffmpeg_clone() {
    local remote="$1" ref="$2" head
    rm -rf "${FFMPEG_SRC}"
    mkdir -p "${FFMPEG_SRC}"
    git clone --depth 1 --branch "${ref}" "${remote}" "${FFMPEG_SRC}" || return 1
    if ! _ffmpeg_pinned_tag "${ref}"; then return 0; fi
    head="$(git -C "${FFMPEG_SRC}" rev-parse HEAD)" || return 1
    if [[ "${head}" != "${FFMPEG_TAG_COMMIT}" ]]; then
        printf 'FFmpeg %s from %s is commit %s, not the pinned FFMPEG_TAG_COMMIT %s\n' "${ref}" "${remote}" "${head}" "${FFMPEG_TAG_COMMIT}" >&2
        return 1
    fi
    return 0
}

# fetch_ffmpeg: FFMPEG_COMMIT (40-hex) wins over FFMPEG_VERSION (a tag); unset, it tracks master. Leaves the shell in FFMPEG_SRC.
fetch_ffmpeg() {
    local ref="${FFMPEG_COMMIT:-${FFMPEG_VERSION:-master}}" url origin=tarball
    if _ffmpeg_pinned_tag "${ref}" && [[ -z "${FFMPEG_SHA256:-}" || -z "${FFMPEG_TAG_COMMIT:-}" ]]; then
        die "FFmpeg ${ref} is the pinned tag: FFMPEG_SHA256 and FFMPEG_TAG_COMMIT in versions.env must name its bytes"
    fi
    rm -rf "${FFMPEG_SRC}"
    mkdir -p "${FFMPEG_SRC}"
    url="$(_ffmpeg_tarball_url "${ref}")"
    echo "Downloading FFmpeg ${ref} from ${url}..."
    # The tarball alone is a single point of failure, so fall back to both git remotes.
    if ! _ffmpeg_tarball "${url}" "${ref}"; then
        origin=git
        echo "Tarball download failed; falling back to git clone (${FFMPEG_GIT})..." >&2
        if ! _ffmpeg_clone "${FFMPEG_GIT}" "${ref}"; then
            echo "Canonical clone failed; trying mirror (${FFMPEG_GIT_MIRROR})..." >&2
            _ffmpeg_clone "${FFMPEG_GIT_MIRROR}" "${ref}" || die "All FFmpeg sources failed: tarball, ${FFMPEG_GIT}, ${FFMPEG_GIT_MIRROR}"
        fi
    fi
    cd "${FFMPEG_SRC}" || die "FFmpeg source ${FFMPEG_SRC} vanished"
    echo "FFmpeg version: ${ref} (from ${origin})"
}
