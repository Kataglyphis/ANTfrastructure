#!/usr/bin/env bash
# Real TAR fixtures prove source selection and argument boundaries, not native runtime or complete licence coverage.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/lib-contract-fixture.sh
source "${TESTS_DIR}/lib-contract-fixture.sh"
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare _work
t_fixture_workspace_init _work || exit 1
lc_init "${_work}" || exit 1
LIB="${TESTS_DIR}/../lib/app-packaging.sh"
declare out rc
# The packagers clear ~/.pub-cache/hosted, so every call runs with a disposable HOME.
HOME_ENV="export HOME=$(printf '%q' "${_work}/home"); unset APP_PACKAGING_BUNDLE_DIR"
mkdir -p "${_work}/home/.pub-cache/hosted/pub.dev" "${_work}/home/.pub-cache/bin"
_tar_list() { tar -tzf "${_work}/$1" | LC_ALL=C sort | tr '\n' ' '; }

t_case "app_packaging_package_linux_bundle_tar tars the release bundle under out/ and copies it beside the project"
mkdir -p "${_work}/build/linux/x64/release/bundle/lib" "${_work}/build/linux/x64/release/obj"
printf 'app\n' > "${_work}/build/linux/x64/release/bundle/demo"
printf 'lib\n' > "${_work}/build/linux/x64/release/bundle/lib/libapp.so"
lc_call out rc "${LIB}" "${HOME_ENV}; app_packaging_package_linux_bundle_tar x64 demo"
t_assert_eq "0" "${rc}"
t_assert_eq "demo-bundle/ demo-bundle/demo demo-bundle/lib/ demo-bundle/lib/libapp.so " "$(_tar_list out/demo-linux-x64.tar.gz)"
t_assert_ok cmp "${_work}/out/demo-linux-x64.tar.gz" "${_work}/demo-linux-x64.tar.gz"
t_assert_contains "${out}" "Created: out/demo-linux-x64.tar.gz ("
t_assert_fails test -e "${_work}/build/linux/x64/release/obj"

t_case "a selected bundle with spaces supplies the actual TAR payload and ORT notices"
mkdir -p "${_work}/relocated bundle/licenses/onnxruntime"
printf 'staged app\n' > "${_work}/relocated bundle/runner"
printf 'original ORT licence\n' > "${_work}/relocated bundle/licenses/onnxruntime/LICENSE"
printf 'original ORT notices\n' > "${_work}/relocated bundle/licenses/onnxruntime/ThirdPartyNotices.txt"
override_env="export APP_PACKAGING_BUNDLE_DIR=$(printf '%q' "${_work}/relocated bundle")"
lc_call out rc "${LIB}" "${HOME_ENV}; ${override_env}; app_packaging_package_linux_bundle_tar x64 'staged app'"
t_assert_eq "0" "${rc}" "${out}"
t_assert_eq "staged app-bundle/ staged app-bundle/licenses/ staged app-bundle/licenses/onnxruntime/ staged app-bundle/licenses/onnxruntime/LICENSE staged app-bundle/licenses/onnxruntime/ThirdPartyNotices.txt staged app-bundle/runner " "$(_tar_list 'out/staged app-linux-x64.tar.gz')"
t_assert_eq 'original ORT licence' "$(tar -xOf "${_work}/out/staged app-linux-x64.tar.gz" 'staged app-bundle/licenses/onnxruntime/LICENSE')"
t_assert_eq 'original ORT notices' "$(tar -xOf "${_work}/out/staged app-linux-x64.tar.gz" 'staged app-bundle/licenses/onnxruntime/ThirdPartyNotices.txt')"
t_assert_ok cmp "${_work}/out/staged app-linux-x64.tar.gz" "${_work}/staged app-linux-x64.tar.gz"

t_case "an empty selection retains the default Flutter bundle"
lc_call out rc "${LIB}" "${HOME_ENV}; export APP_PACKAGING_BUNDLE_DIR=''; app_packaging_package_linux_bundle_tar x64 demo"
t_assert_eq "0" "${rc}" "${out}"
t_assert_eq 'app' "$(tar -xOf "${_work}/out/demo-linux-x64.tar.gz" demo-bundle/demo)"

t_case "a missing selected bundle refuses the raw fallback even when it exists"
lc_expect 1 "Error: bundle source directory not found: selected-missing" "${LIB}" \
  "${HOME_ENV}; export APP_PACKAGING_BUNDLE_DIR=selected-missing; app_packaging_package_linux_bundle_tar x64 demo"

t_case "bundle resolution failures retain their raw status"
lc_call out rc "${LIB}" "${HOME_ENV}; app_packaging_detect_bundle_dir() { return 7; }; app_packaging_package_linux_bundle_tar x64 demo"
t_assert_eq "7" "${rc}" "${out}"

t_case "preparing the workspace empties only the hosted pub cache"
t_assert_fails test -e "${_work}/home/.pub-cache/hosted"
t_assert_ok test -d "${_work}/home/.pub-cache/bin"

t_case "a missing bundle fails with its path, and both arguments are required"
lc_expect 1 "Error: bundle source directory not found: build/linux/arm64/release/bundle" "${LIB}" "${HOME_ENV}; app_packaging_package_linux_bundle_tar arm64 demo"
lc_call out rc "${LIB}" "${HOME_ENV}; app_packaging_package_linux_bundle_tar x64"
t_assert_contains "${out}" "app_name is required"

t_case "app_packaging_package_android_apk_outputs_tar tars the APK outputs under the same name pattern"
mkdir -p "${_work}/build/app/outputs/flutter-apk"
printf 'apk\n' > "${_work}/build/app/outputs/flutter-apk/app-release.apk"
lc_call out rc "${LIB}" "${HOME_ENV}; export APP_PACKAGING_BUNDLE_DIR=selected-missing; app_packaging_package_android_apk_outputs_tar arm64 demo"
t_assert_eq "0" "${rc}"
t_assert_eq "demo-bundle/ demo-bundle/app-release.apk " "$(_tar_list out/demo-linux-arm64.tar.gz)"
t_assert_contains "${out}" "Created: out/demo-linux-arm64.tar.gz ("
lc_call out rc "${LIB}" "${HOME_ENV}; app_packaging_package_android_apk_outputs_tar"
t_assert_contains "${out}" "matrix_arch is required (x64|arm64)"

t_case "app_packaging_run_command_with_runtime wraps a flatpak build in a D-Bus session and runs anything else as is"
lc_stub dbus-run-session 'shift; "$@"'
lc_stub tool
lc_reset
lc_call out rc "${LIB}" "app_packaging_run_command_with_runtime 'deb, Flatpak' tool build --arch x64"
t_assert_eq "0" "${rc}"
t_assert_eq "dbus-run-session -- tool build --arch x64
tool build --arch x64" "$(lc_argv)"
lc_reset
lc_fail tool 6
lc_call out rc "${LIB}" "app_packaging_run_command_with_runtime deb,appimage tool build"
t_assert_eq "6" "${rc}" "the command's status is the function's"
lc_pass tool
t_assert_eq "tool build" "$(lc_argv)"

t_summary
