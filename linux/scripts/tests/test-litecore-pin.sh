#!/usr/bin/env bash
# The LiteCore headers the android LiteRT build compiles against: pinned in versions.env, fetched verified (CON227).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
ROOT="${TESTS_DIR}/../../.."
BUILD="${ROOT}/linux/scripts/03-media/build/litert/android/build-android.sh"
_src="$(cat "${BUILD}")"
_env="$(cat "${ROOT}/linux/scripts/01-core/versions.env")"
_df="$(cat "${ROOT}/linux/Dockerfile.android")"

t_case "the pin lives in versions.env with its sha, and Dockerfile.android forwards both into the stage"
t_assert_contains "${_env}" $'\nLITECORE_VERSION=' "LITECORE_VERSION is a versions.env key"
t_assert_contains "${_env}" $'\nLITECORE_SHA256=' "LITECORE_SHA256 sits beside it"
t_assert_contains "${_df}" $'\nARG LITECORE_VERSION\nARG LITECORE_SHA256\n' "both ARGs, undefaulted, so an unforwarded pin fails the guard"
t_assert_contains "${_df}" '    LITECORE_VERSION=${LITECORE_VERSION} \' "the ENV forward"
t_assert_contains "${_df}" '    LITECORE_SHA256=${LITECORE_SHA256} \' "the ENV forward of the sha"

t_case "build-android.sh guards both and fetches through download_verified_file, never plain curl"
t_assert_contains "${_src}" ': "${LITECORE_VERSION:?' "a missing version fails before any download"
t_assert_contains "${_src}" ': "${LITECORE_SHA256:?' "a missing sha fails before any download"
t_assert_contains "${_src}" 'download_verified_file "${litecore_url}" "${LITECORE_SHA256}" "${litecore_root}/litecore.tar.gz"' \
  "the asset mirror is asked first and the sha is the only gate"
t_assert_eq "" "$(printf '%s\n' "${_src}" | grep -e 'curl .*litecore')" "no plain curl of the archive"
t_assert_eq "" "$(printf '%s\n' "${_src}" | grep -e 'litecore_sha256=')" "no literal sha in the script"
t_assert_contains "${_src}" 'exynos-ai-litecore-v${LITECORE_VERSION}/include' "the include dir follows the pin"

t_summary
