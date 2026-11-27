#!/usr/bin/env bash
# fetch-ffmpeg.sh's choice of source and its pins, with downloads, tar and git stubbed; a real download runs only in the media stage.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
FETCH="${TESTS_DIR}/../03-media/build/ffmpeg/fetch-ffmpeg.sh"

_work="$(t_mktemp -d)"
PIN_SHA=cb3432eba99ce67f4ef6381c2fdbc0483d796f9e36d16c2b0cc0b7f9a71b46e8
PIN_COMMIT=946fcce07b6dcd0331c8cc609192aeff5e1924f8

# _fetch <env assignments...>: runs fetch_ffmpeg in a subshell with every network tool stubbed; prints its output and calls.
_fetch() {
  (
    export FFMPEG_SRC="${_work}/src" FFMPEG_GIT=https://git.example/canonical FFMPEG_GIT_MIRROR=https://git.example/mirror
    export FFMPEG_VERSION=n9.0.2 FFMPEG_SHA256="${PIN_SHA}" FFMPEG_TAG_COMMIT="${PIN_COMMIT}" FFMPEG_COMMIT=
    FAKE_TARBALL=ok FAKE_CLONE_FAILS="" FAKE_MOVED=""
    for assignment in "$@"; do export "${assignment?}"; done
    calls="${_work}/calls"
    : > "${calls}"
    die() { echo "DIE: $*"; exit 1; }
    download_verified_file() { echo "verified $*" >> "${calls}"; [[ "${FAKE_TARBALL}" == ok ]]; }
    download_and_extract() { echo "unverified $*" >> "${calls}"; return 0; }
    tar() { echo "tar $*" >> "${calls}"; return 0; }
    git() {
      if [[ "$1" == clone ]]; then
        local remote="${*: -2:1}" dir="${*: -1}"
        echo "clone ${remote}" >> "${calls}"
        mkdir -p "${dir}" && printf '%s' "${remote}" > "${dir}/.remote"
        [[ " ${FAKE_CLONE_FAILS} " != *" ${remote} "* ]]
        return
      fi
      if [[ "$1" == -C && "$3" == rev-parse ]]; then
        if [[ " ${FAKE_MOVED} " == *" $(cat "$2/.remote") "* ]]; then echo 0123456789012345678901234567890123456789; else echo "${PIN_COMMIT}"; fi
        return 0
      fi
      return 99
    }
    # shellcheck source=../03-media/build/ffmpeg/fetch-ffmpeg.sh
    source "${FETCH}"
    fetch_ffmpeg 2>&1
    echo "cwd=$(pwd)"
    cat "${calls}"
  )
}

# _absent <text> <pattern>: the harness greps files, so the text goes to one first.
_absent() { printf '%s\n' "$1" > "${_work}/out"; t_assert_no_grep "${_work}/out" "$2"; }

t_case "the pinned tag's archive is checked by its stream hash before it is unpacked"
out="$(_fetch)"
t_assert_contains "${out}" "verified https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n9.0.2.tar.gz ${PIN_SHA} "
t_assert_contains "${out}" " stream"
t_assert_contains "${out}" "FFmpeg version: n9.0.2 (from tarball)"
t_assert_contains "${out}" "cwd=${_work}/src"
_absent "${out}" "unverified"

t_case "an archive that fails its hash falls back to a clone, which must land on the pinned commit"
out="$(_fetch FAKE_TARBALL=bad)"
t_assert_contains "${out}" "clone https://git.example/canonical"
t_assert_contains "${out}" "FFmpeg version: n9.0.2 (from git)"
out="$(_fetch FAKE_TARBALL=bad "FAKE_MOVED=https://git.example/canonical")"
t_assert_contains "${out}" "is commit 0123456789012345678901234567890123456789, not the pinned FFMPEG_TAG_COMMIT ${PIN_COMMIT}"
t_assert_contains "${out}" "clone https://git.example/mirror"
t_assert_contains "${out}" "(from git)"

t_case "a tag moved on both remotes, or a pin left empty, stops the build"
out="$(_fetch FAKE_TARBALL=bad "FAKE_MOVED=https://git.example/canonical https://git.example/mirror")"
t_assert_contains "${out}" "DIE: All FFmpeg sources failed"
_absent "${out}" "FFmpeg version:"
out="$(_fetch FFMPEG_SHA256=)"
t_assert_contains "${out}" "DIE: FFmpeg n9.0.2 is the pinned tag: FFMPEG_SHA256 and FFMPEG_TAG_COMMIT"
out="$(_fetch FFMPEG_TAG_COMMIT=)"
t_assert_contains "${out}" "DIE: FFmpeg n9.0.2 is the pinned tag"

t_case "a branch or an explicit commit is no pinned tag, so it needs no hash"
out="$(_fetch FFMPEG_VERSION=master FFMPEG_SHA256=)"
t_assert_contains "${out}" "unverified https://github.com/FFmpeg/FFmpeg/archive/refs/heads/master.tar.gz"
out="$(_fetch FFMPEG_COMMIT=c29d710cd5d0f80bbb56f7ec1f35d5fb7ed44d05)"
t_assert_contains "${out}" "unverified https://github.com/FFmpeg/FFmpeg/archive/c29d710cd5d0f80bbb56f7ec1f35d5fb7ed44d05.tar.gz"
_absent "${out}" "^verified "

t_summary
