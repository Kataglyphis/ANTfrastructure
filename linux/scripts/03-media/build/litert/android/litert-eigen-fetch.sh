#!/usr/bin/env bash
# Under android/ because Dockerfile.android COPYs only that dir; see docs/failure-modes.md#litert-configure-fatal-expected-flush-after-ref-listing

# Array form, for the call sites that build a cmake argv.
LITERT_EIGEN_FETCH_FLAGS=(
    "-DOVERRIDABLE_FETCH_CONTENT_GIT_REPOSITORY_AND_TAG_TO_URL_eigen=ON"
    "-DOVERRIDABLE_FETCH_CONTENT_eigen_MATCH=^https://gitlab[.]com/(.*)$"
    '-DOVERRIDABLE_FETCH_CONTENT_eigen_REPLACE=https://gitlab.com/\1;https://storage.googleapis.com/mirror.tensorflow.org/gitlab.com/\1'
)

# EXTRA_CMAKE_FLAGS is word-split, so flags stay space-free; subshell IFS because callers run under IFS=$'\n\t'.
litert_eigen_fetch_flags_str() {
    (IFS=' '; printf '%s' "${LITERT_EIGEN_FETCH_FLAGS[*]}")
}
