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
  if [ "$format" = deb ]; then
    deb="${work}/out/demo_1.2.3_$(dpkg --print-architecture).deb"
    t_assert_contains "$(ar t "$deb")" 'control.tar.gz' 'older dpkg must read the control archive'
    t_assert_contains "$(ar t "$deb")" 'data.tar.gz' 'older dpkg must read the payload archive'
  fi
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

t_case 'a GPU bundle cannot be packaged with its provider test disabled'
printf '{"wheel":"demo-1.2.3-py3-none-any.whl","required_provider":"MIGraphXExecutionProvider"}\n' > "${bundle}/bundle.json"
t_assert_fails package_fixture tar "${work}/gpu-output"
t_assert_contains "$(cat "${work}/output")" 'GPU package must run its MIGraphXExecutionProvider self-test'

t_case 'a fake GPU bundle is rejected after writing its distinctly named candidate'
cat > "${bundle}/bin/demo" <<'SH'
#!/bin/sh
printf '{\n  "ok": true,\n  "available_providers": ["MIGraphXExecutionProvider"]\n}\n'
SH
chmod +x "${bundle}/bin/demo"
gpu_package_fixture() {
  bash "$SUBJECT" --repo-root "$repo" --bundle "$bundle" --out-dir "${work}/gpu-output" \
    --work-dir "${work}/staging" --formats tar > "${work}/gpu-proof-output" 2>&1
}
t_assert_fails gpu_package_fixture
t_assert_contains "$(cat "${work}/gpu-proof-output")" 'exactly one in-bundle ORT capi directory'
t_assert_ok test -f "${work}/gpu-output/demo-gpu-amd-1.2.3-linux-$(uname -m).tar.gz"

t_case 'hardware validation requires the active provider while a build requires availability'
eval "$(t_fn_src "$SUBJECT" prove)" || exit 1
SELFTEST=checker
RUN_TESTS=true
required_provider=MIGraphXExecutionProvider
python3() { printf '%s\n' "$@" > "${work}/provider-args"; }
info() { :; }
err() { return 1; }
PYTHON_APP_REQUIRE_ACTIVE_PROVIDER=false t_assert_ok prove /bundle demo
t_assert_contains "$(cat "${work}/provider-args")" '--require-available-provider'
t_assert_eq 0 "$(grep -xcF -- '--require-provider' "${work}/provider-args" || true)"
PYTHON_APP_REQUIRE_ACTIVE_PROVIDER=true t_assert_ok prove /bundle demo
t_assert_contains "$(cat "${work}/provider-args")" '--require-provider'

t_case 'AppImage packaging invokes the native verifier on its exact output and license'
_appimage="$(t_fn_src "$SUBJECT" package_appimage)" || exit 1
t_assert_contains "${_appimage}" 'bash "${SCRIPT_DIR}/verify-native-appimage-license.sh" "${output}" "${UNAME_ARCH}" "usr/lib/${APP_ID}/LICENSE" "${LICENSE_FILE}" || return $?'

t_summary
