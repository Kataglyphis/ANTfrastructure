#!/usr/bin/env bash
# The android-sdk-shared cache id in linux/Dockerfile.android must name every pin that
# android-sdk.sh's sdk_packages installs. The two API 37 pins were missing from it, so
# every build after 2bb0410f restored an SDK tree cached on 2026-08-22 and shipped
# without API 37 (BACKLOG CON14). android-sdk.sh also re-checks a restored tree; this
# keeps the id from depending on that.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

SDK="${TESTS_DIR}/../02-toolchain/android-sdk.sh"
DF="${TESTS_DIR}/../../Dockerfile.android"

# _unkeyed_pins <android-sdk.sh> <Dockerfile.android> - prints each ${ANDROID_*} that
# sdk_packages uses and the cache id does not name.
_unkeyed_pins() {
  local id var
  id="$(grep -o 'id=android-sdk-shared-[^,]*' "$2" | head -1)"
  [ -n "${id}" ] || { echo "NO-CACHE-ID"; return 0; }
  sed -n '/^sdk_packages=(/,/^)/p' "$1" | grep -o '\${ANDROID_[A-Z_]*}' | sort -u |
    while read -r var; do
      case "${id}" in *"${var}"*) ;; *) printf '%s\n' "${var}" ;; esac
    done
}

t_case "the real cache id names every pin sdk_packages installs"
t_assert_eq "" "$(_unkeyed_pins "${SDK}" "${DF}")" "unkeyed pins"
t_assert_contains "$(sed -n '/^sdk_packages=(/,/^)/p' "${SDK}")" '${ANDROID_EXTRA_COMPILE_SDK}' "the API 37 platform is in the list"

t_case "an id missing a pin is caught, and names it (mutation)"
_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
sed 's/-${ANDROID_EXTRA_BUILD_TOOLS}//' "${DF}" > "${_work}/Dockerfile.android"
t_assert_eq '${ANDROID_EXTRA_BUILD_TOOLS}' "$(_unkeyed_pins "${SDK}" "${_work}/Dockerfile.android")" "the dropped pin"

t_case "no cache id at all is a failure, not an empty answer (mutation)"
sed 's/id=android-sdk-shared-/id=android-sdk-other-/' "${DF}" > "${_work}/Dockerfile.noid"
t_assert_eq "NO-CACHE-ID" "$(_unkeyed_pins "${SDK}" "${_work}/Dockerfile.noid")" "missing id"

t_summary
