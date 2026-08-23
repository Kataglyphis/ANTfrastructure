#!/usr/bin/env bash
# litert-eigen-fetch.sh — THE definition of LiteRT's mirrored eigen fetch.
#
# EIGEN-NET (2026-08-21): every TFLite/LiteRT cmake tree fetches eigen from ONE
# host -- tools/cmake/modules/eigen.cmake declares GIT_REPOSITORY
# gitlab.com/libeigen/eigen -- so a momentary gitlab outage ("fatal: expected
# flush after ref listing") took all three android lanes down inside a single
# window. Two knobs of upstream's OverridableFetchContent module give that fetch
# a second home WITHOUT pinning a commit here (the tag stays upstream's):
#   * GIT_REPOSITORY_AND_TAG_TO_URL_eigen=ON converts the clone into an archive
#     download of the SAME pinned commit (already how the C-API/wheel configure
#     paths fetch it), and
#   * <content>_MATCH/_REPLACE rewrite that archive URL -- a ';' in the
#     replacement makes it a cmake LIST, which ExternalProject downloads "in
#     turn until one succeeds".
# The second home is TensorFlow's own mirror of the same gitlab path (the
# tf_mirror_urls() rule in third_party/eigen3/workspace.bzl), verified
# byte-identical on 2026-08-23: both URLs for commit ea13a98d... returned
# sha256 35c6126e..., 2870994 bytes. Degrades safely -- if the regex ever stops
# matching, the URL is left untouched and the fetch behaves as it does today.
#
# WHY THIS FILE LIVES UNDER android/ (it is shared, not android-specific):
# this is the only directory both LiteRT build scripts can reach, because the
# two images are cut differently --
#   * Dockerfile.android's android-litert stage COPYs exactly
#     linux/scripts/03-media/build/litert/android/ (and nothing else from the
#     litert tree) to /opt/scripts/03-media/litert/android/;
#   * Dockerfile.media bind-mounts the WHOLE linux/scripts/03-media/build/litert
#     directory, so it sees this android/ subdirectory as well.
# Both consumers source it by a path relative to their own location, so no
# Dockerfile change is needed. Hoisting it one level up to litert/ would break
# the android lane at build time ("no such file"), NOT silently fall back.
#
# Sourced, never executed:
#   build-litert.sh          source "${SCRIPT_DIR}/android/litert-eigen-fetch.sh"
#   android/build-android.sh source "$(dirname "${BASH_SOURCE[0]}")/litert-eigen-fetch.sh"

# Array form, for the call sites that build a cmake argv.
LITERT_EIGEN_FETCH_FLAGS=(
    "-DOVERRIDABLE_FETCH_CONTENT_GIT_REPOSITORY_AND_TAG_TO_URL_eigen=ON"
    "-DOVERRIDABLE_FETCH_CONTENT_eigen_MATCH=^https://gitlab[.]com/(.*)$"
    '-DOVERRIDABLE_FETCH_CONTENT_eigen_REPLACE=https://gitlab.com/\1;https://storage.googleapis.com/mirror.tensorflow.org/gitlab.com/\1'
)

# Space-joined form for the one call site that hands cmake flags over as a
# STRING (the wheel build's EXTRA_CMAKE_FLAGS, word-split by upstream's patched
# build_pip_package_with_cmake.sh -- so the flags must stay space-free).
# ${arr[*]} joins on the first IFS character and build-litert.sh runs under
# IFS=$'\n\t', so scope the join to a subshell instead of touching global IFS.
litert_eigen_fetch_flags_str() {
    (IFS=' '; printf '%s' "${LITERT_EIGEN_FETCH_FLAGS[*]}")
}
