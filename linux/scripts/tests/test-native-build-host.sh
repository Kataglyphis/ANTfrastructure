#!/usr/bin/env bash
# Tests for building the chain on a NON-amd64 build host, where the Android NDK
# (prebuilt/linux-x86_64 only) cannot be installed and the android stage builds
# payload-off instead. Three mechanisms must agree, none of which had ANY test
# coverage before this suite: the host predicate (platform.sh), swap-native-gcc's
# early return, and the payload-off marker android-sdk.sh writes / smoke-android
# reads. Why the stage is not simply removed from the graph, and what each
# consumer does with the marker: docs/linux-cross-builds.md#non-amd64-build-hosts
#
# Every case pins BUILDARCH — unpinned rows assert whatever machine runs them.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/platform.sh"

REPO_SCRIPTS="${TESTS_DIR}/.."
SWAP="${REPO_SCRIPTS}/06-packaging/swap-native-gcc.sh"
SMOKE_ANDROID="${REPO_SCRIPTS}/06-packaging/smoke-android.sh"
SMOKE_COMMON="${REPO_SCRIPTS}/06-packaging/smoke-common.sh"
ANDROID_SDK="${REPO_SCRIPTS}/02-toolchain/android-sdk.sh"

MARKER_PATH="/opt/android/.android-payload-off"

# ---------------------------------------------------------------------------
t_case "android_build_host_supported answers for the BUILD host, not the target"
BUILDARCH=amd64   t_assert_ok android_build_host_supported
BUILDARCH=arm64   t_assert_fails    android_build_host_supported
BUILDARCH=riscv64 t_assert_fails    android_build_host_supported

# The fallback ladder in _platform_raw_build_arch is BUILDARCH -> BUILDPLATFORM
# -> dpkg -> uname. A caller that only sets BUILDPLATFORM must get the same
# answer, or a Dockerfile that forgets `ARG BUILDARCH` silently takes the amd64
# path on an arm64 machine.
_supported_via_buildplatform() {
  ( unset BUILDARCH; BUILDPLATFORM="$1" android_build_host_supported )
}
t_assert_ok _supported_via_buildplatform linux/amd64
t_assert_fails    _supported_via_buildplatform linux/arm64
t_assert_fails    _supported_via_buildplatform linux/riscv64

t_case "android_require_amd64_build_host names the scope it is skipping"
_require_msg="$(BUILDARCH=arm64 android_require_amd64_build_host "Android SDK/NDK installation" 2>&1)"
t_assert_eq "Skipping Android SDK/NDK installation on non-amd64 build host" "${_require_msg}"
BUILDARCH=arm64 t_assert_fails    android_require_amd64_build_host "X"
BUILDARCH=amd64 t_assert_ok android_require_amd64_build_host "X"

# ---------------------------------------------------------------------------
# swap-native-gcc.sh. Neither branch can COMPLETE on a machine with no /opt/gcc-* tree: both end in
# assert_elf_arch / _assert_and_relocate_native_gcc against a path that does not
# exist, and elf_machine_name's unreadable-file return kills the script under
# errexit with no message at all. Asserting on stdout would therefore be an
# absence test that also passes when the script dies for an unrelated reason.
# The execution trace names the branch positively instead.
_swap_trace() {
  TARGET_ARCH="$1" BUILDARCH="$2" BUILD_MODE=cross GCC_VERSION=0.0.0 \
    bash -x "${SWAP}" 2>&1 | grep -E '^\+ (assert_elf_arch|_assert_and_relocate_native_gcc)'
}

t_case "swap-native-gcc keys its early return on the build host"
# THE AMD64 TRIPWIRE: an amd64 host targeting arm64 must still demand the
# Canadian cross prefix. If anyone ever generalises this early return into a
# no-op, the cross build silently ships an amd64 GCC in an arm64 image.
t_assert_contains "$(_swap_trace arm64 amd64)" "_assert_and_relocate_native_gcc /opt/gcc-0.0.0-native-arm64" \
  "the amd64 cross path must be unchanged"
t_assert_contains "$(_swap_trace riscv64 amd64)" "_assert_and_relocate_native_gcc /opt/gcc-0.0.0-native-riscv64"

# target == build host: gcc.sh:376 took link_amd64_host_as_cross and never
# produced a native prefix, so the swap must assert the HOST GCC instead of
# demanding one that is never built.
t_assert_contains "$(_swap_trace arm64 arm64)" "assert_elf_arch /opt/gcc-0.0.0/bin/gcc arm64" \
  "a native arm64 host must accept its own GCC, not demand a Canadian cross"
t_assert_contains "$(_swap_trace riscv64 riscv64)" "assert_elf_arch /opt/gcc-0.0.0/bin/gcc riscv64"
t_assert_contains "$(_swap_trace amd64 amd64)" "assert_elf_arch /opt/gcc-0.0.0/bin/gcc amd64" \
  "an amd64 host targeting amd64 keeps the historical behaviour"

# ...and must NOT have looked for a Canadian prefix at all.
_count() { printf '%s' "$1" | grep -c -- "$2" || true; }
t_assert_eq "0" "$(_count "$(_swap_trace arm64 arm64)" "native-arm64")" \
  "the native host must never reach _assert_and_relocate_native_gcc"

# ---------------------------------------------------------------------------
# The payload-off marker: one literal path written by android-sdk.sh and read by
# smoke-android.sh. Neither file may be run for real here (android-sdk.sh
# installs an SDK; the path is under /opt), so the producer is asserted
# structurally and the reader behaviourally against a redirected copy.
t_case "the marker's producer and reader name the SAME path"
t_assert_contains "$(cat "${ANDROID_SDK}")" "${MARKER_PATH}" \
  "android-sdk.sh must write the marker"
t_assert_contains "$(cat "${SMOKE_ANDROID}")" "${MARKER_PATH}" \
  "smoke-android.sh must read the same literal the producer writes"

t_case "the marker is written inside the skip branch, not unconditionally"
# Everything from the guard to its `exit 0` — the write must live in there, or
# an amd64 build would stamp its own image payload-off.
_skip_branch="$(awk '/android_require_amd64_build_host "Android SDK\/NDK installation"/,/^fi$/' "${ANDROID_SDK}")"
t_assert_contains "${_skip_branch}" "${MARKER_PATH}"
t_assert_contains "${_skip_branch}" "build_host="

# ---------------------------------------------------------------------------
# smoke-android.sh against a redirected marker. Copy both files so the script's
# own `source "${_SCRIPT_DIR}/smoke-common.sh"` still resolves, then rewrite only
# the marker literal. This runs the REAL main(), not a re-implementation.
_SMOKE_DIR="$(mktemp -d)"
trap 'rm -rf "${_SMOKE_DIR}"' EXIT
cp "${SMOKE_COMMON}" "${_SMOKE_DIR}/smoke-common.sh"
sed "s|${MARKER_PATH}|${_SMOKE_DIR}/marker|g" "${SMOKE_ANDROID}" > "${_SMOKE_DIR}/smoke-android.sh"

t_case "smoke-android runs every check when no marker is present"
rm -f "${_SMOKE_DIR}/marker"
_no_marker="$(bash "${_SMOKE_DIR}/smoke-android.sh" 2>&1)"
t_assert_contains "${_no_marker}" "--- Android SDK root ---" \
  "an amd64 image has no marker, so the strict path must be unchanged"
t_assert_eq "0" "$(_count "${_no_marker}" "android payload off")"

t_case "smoke-android self-skips, green, on a recorded payload-off marker"
printf 'reason=Android NDK ships as prebuilt/linux-x86_64 only\nbuild_host=arm64\n' \
  > "${_SMOKE_DIR}/marker"
_with_marker="$(bash "${_SMOKE_DIR}/smoke-android.sh" 2>&1)"
_with_marker_rc=$?
t_assert_eq "0" "${_with_marker_rc}" "a payload-off image must not fail its own smoke"
t_assert_contains "${_with_marker}" "build_host=arm64" \
  "the smoke must echo WHY the payload is absent, not just skip silently"
for _c in sdk_root sdkmanager adb ndk build_tools android_cmake opencv; do
  t_assert_contains "${_with_marker}" "SKIP ${_c}"
done
t_assert_eq "0" "$(_count "${_with_marker}" -- "--- sdkmanager ---")" \
  "the strict checks must not run at all"

t_summary
