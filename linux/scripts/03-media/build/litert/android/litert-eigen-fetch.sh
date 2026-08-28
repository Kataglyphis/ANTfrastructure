#!/usr/bin/env bash
# Gives LiteRT's single-homed eigen fetch a second host; the ';' in _REPLACE makes
# the URL a cmake LIST, tried in turn (docs/failure-modes.md, "expected flush").
#
# Under android/ because Dockerfile.android COPYs only that dir while Dockerfile.media
# mounts all of litert/ -- moving it up breaks the android build.
# Sourced by build-litert.sh and android/build-android.sh; never executed.

# Array form, for the call sites that build a cmake argv.
LITERT_EIGEN_FETCH_FLAGS=(
    "-DOVERRIDABLE_FETCH_CONTENT_GIT_REPOSITORY_AND_TAG_TO_URL_eigen=ON"
    "-DOVERRIDABLE_FETCH_CONTENT_eigen_MATCH=^https://gitlab[.]com/(.*)$"
    '-DOVERRIDABLE_FETCH_CONTENT_eigen_REPLACE=https://gitlab.com/\1;https://storage.googleapis.com/mirror.tensorflow.org/gitlab.com/\1'
)

# Space-joined form for the wheel build's EXTRA_CMAKE_FLAGS (a word-split STRING, so
# flags must stay space-free); subshell IFS, because callers run under IFS=$'\n\t'.
litert_eigen_fetch_flags_str() {
    (IFS=' '; printf '%s' "${LITERT_EIGEN_FETCH_FLAGS[*]}")
}
