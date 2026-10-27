#!/usr/bin/env bash
# Tests actual tar/DEB contents and AppImage verifier wiring, not the complete dependency-license set.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/python-app-license-fixture.sh"
SCRIPT_DIR="$(cd "${TESTS_DIR}/../06-packaging" && pwd)"
SUBJECT="${SCRIPT_DIR}/python-app-package.sh"
t_skip_unless 'dpkg-deb' command -v dpkg-deb
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
repo="${work}/project with spaces"
bundle="${repo}/bundle"
python_app_license_fixture "$repo" "$bundle"
mkdir -p "${work}/out" "${work}/staging"
printf '#!/bin/sh\nexit 0\n' > "${bundle}/bin/demo"
chmod +x "${bundle}/bin/demo"
printf '{"wheel":"demo-1.2.3-py3-none-any.whl","glibc":true}\n' > "${bundle}/bundle.json"

package_fixture() {
  bash "$SUBJECT" --repo-root "$repo" --bundle "$bundle" --out-dir "${2:-${work}/out}" \
    --work-dir "${work}/staging" --formats "$1" --no-test > "${work}/output" 2>&1
}

for format in tar deb; do
  t_case "$format accepts the full project text in its built payload"
  cp "${repo}/LICENSE" "${bundle}/LICENSE"
  t_assert_ok package_fixture "$format"
  t_case "$format rejects missing or different bundle license even with --no-test"
  printf 'wrong license\n' > "${bundle}/LICENSE"
  t_assert_fails package_fixture "$format"
  rm "${bundle}/LICENSE"
  t_assert_fails package_fixture "$format"
done

t_case 'the package config must name a nonempty existing source license'
cp "${repo}/LICENSE" "${bundle}/LICENSE"
mv "${repo}/LICENSE" "${repo}/saved"
t_assert_fails package_fixture tar "${work}/missing-output"
: > "${repo}/LICENSE"
t_assert_fails package_fixture tar "${work}/empty-output"
t_assert_eq 0 "$(find "${work}/empty-output" -name '*.tar.gz' | wc -l | tr -d ' ')" 'empty source license fails before an artifact is written'
mv "${repo}/saved" "${repo}/LICENSE"

t_case 'AppImage packaging invokes the native verifier on its exact output and license'
_appimage="$(t_fn_src "$SUBJECT" package_appimage)" || exit 1
t_assert_contains "${_appimage}" 'bash "${SCRIPT_DIR}/verify-native-appimage-license.sh" "${output}" "${UNAME_ARCH}" "usr/lib/${APP_ID}/LICENSE" "${LICENSE_FILE}" || return $?'

t_summary
