#!/usr/bin/env bash
# Tests plan rejection and runtime shadowing; it does not contact package indexes.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=linux/scripts/lib/test-harness.sh
source "${here}/lib/test-harness.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
plan="${here}/01-core/verify-uv-image-plan.py"
modules="${here}/01-core/verify-uv-image-modules.py"
mkdir -p "${work}/bin"
printf '#!/usr/bin/env bash\ntouch "$UV_CALLED"\n' > "${work}/bin/uv"
chmod +x "${work}/bin/uv"
base_python="$(python3 -I -c 'import sys; print(sys._base_executable)')"
cat > "${work}/base-python" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -I ] && [ "${2:-}" = -c ]; then exec "${BASE_PYTHON}" "$@"; fi
if [ "${1:-}" = -I ] && [ "${2:-}" = -m ] && [ "${3:-}" = pip ]; then echo demo==1; exit 0; fi
exit 1
EOF
chmod +x "${work}/base-python"
t_case 'a non-venv target fails even with Python optimizations enabled'
t_assert_rc 1 env PYTHONOPTIMIZE=1 BASE_PYTHON="${base_python}" UV_CALLED="${work}/called" PATH="${work}/bin:${PATH}" bash -c 'source "$1"; uv_image_overlay_install "$2" "$2" "$3"' _ "${here}/01-core/uv-image-overlay.sh" "${work}/base-python" "${work}"
t_assert_rc 1 test -e "${work}/called"
t_case 'all overlay uv calls ignore inherited working-directory and project overrides'
cat > "${work}/bin/uv" <<'EOF'
#!/usr/bin/env bash
printf '%s:%s:%s\n' "$1" "${UV_WORKING_DIR-unset}" "${UV_PROJECT-unset}" >> "$UV_CALLS"
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "${work}/target-python"
chmod +x "${work}/bin/uv" "${work}/target-python"
t_assert_rc 0 env BASE_PYTHON="${base_python}" UV_CALLS="${work}/uv-calls" UV_WORKING_DIR=wrong UV_PROJECT=wrong PATH="${work}/bin:${PATH}" \
  bash -c 'cd "$1"; source "$2"; uv_image_overlay_install ./base-python ./target-python .' _ "${work}" "${here}/01-core/uv-image-overlay.sh"
t_assert_eq 3 "$(grep -c '^export:unset:unset$' "${work}/uv-calls")"
t_assert_eq 1 "$(grep -c '^pip:unset:unset$' "${work}/uv-calls")"
t_case 'successful cleanup removes its directory'
mkdir -p "${work}/cleanup"
t_assert_rc 0 bash -c 'source "$1"; uv_image_overlay_cleanup 0 "$2"' _ "${here}/01-core/uv-image-overlay.sh" "${work}/cleanup"
t_assert_rc 1 test -e "${work}/cleanup"
t_case 'failed cleanup fails a successful run and preserves an earlier failure'
mkdir -p "${work}/cleanup" "${work}/fake-rm"
printf '#!/usr/bin/env bash\nexit 7\n' > "${work}/fake-rm/rm"
chmod +x "${work}/fake-rm/rm"
t_assert_rc 1 env PATH="${work}/fake-rm:${PATH}" bash -c 'source "$1"; uv_image_overlay_cleanup 0 "$2"' _ "${here}/01-core/uv-image-overlay.sh" "${work}/cleanup"
t_assert_rc 42 env PATH="${work}/fake-rm:${PATH}" bash -c 'source "$1"; uv_image_overlay_cleanup 42 "$2"' _ "${here}/01-core/uv-image-overlay.sh" "${work}/cleanup"
t_case 'the EXIT handler propagates cleanup failure and a prior failure'
t_assert_rc 1 env PATH="${work}/fake-rm:${PATH}" bash -c 'source "$1"; trap '\''uv_image_overlay_exit "$?" "$2"'\'' EXIT; exit 0' _ "${here}/01-core/uv-image-overlay.sh" "${work}/cleanup"
t_assert_rc 42 env PATH="${work}/fake-rm:${PATH}" bash -c 'source "$1"; trap '\''uv_image_overlay_exit "$?" "$2"'\'' EXIT; exit 42' _ "${here}/01-core/uv-image-overlay.sh" "${work}/cleanup"
t_case 'a successful removal command that leaves the directory still fails'
printf '#!/usr/bin/env bash\nexit 0\n' > "${work}/fake-rm/rm"
t_assert_rc 1 env PATH="${work}/fake-rm:${PATH}" bash -c 'source "$1"; uv_image_overlay_cleanup 0 "$2"' _ "${here}/01-core/uv-image-overlay.sh" "${work}/cleanup"
reset_inputs() {
  printf 'demo_pkg==1.2.3\n' > "${work}/requirements"
  printf 'demo_pkg==1.2.3\n' > "${work}/full-lock"
  printf 'demo-pkg==1.2.3\n' > "${work}/constraints"
  printf '{"install":[{"metadata":{"name":"demo-pkg","version":"1.2.3"}}]}' > "${work}/report"
}
reset_inputs
t_case 'the install plan accepts the exact normalized locked package'
t_assert_rc 0 python3 "${plan}" "${work}/requirements" "${work}/report" "${work}/full-lock" "${work}/constraints"
t_case 'an unpinned planned package is rejected'
printf '{"install":[{"metadata":{"name":"torch","version":"2.14.1"}}]}' > "${work}/report"
t_assert_rc 1 python3 "${plan}" "${work}/requirements" "${work}/report" "${work}/full-lock" "${work}/constraints"
t_case 'an image local version is not the exact locked version'
reset_inputs
printf 'demo-pkg==1.2.3+local\n' > "${work}/constraints"
t_assert_rc 1 python3 "${plan}" "${work}/requirements" "${work}/report" "${work}/full-lock" "${work}/constraints"
t_case 'a direct URL in the full lock is rejected'
reset_inputs
printf 'demo-pkg @ https://example.invalid/demo.whl\n' > "${work}/full-lock"
t_assert_rc 1 python3 "${plan}" "${work}/requirements" "${work}/report" "${work}/full-lock" "${work}/constraints"
t_case 'a different version of a locked package is rejected'
reset_inputs
printf '{"install":[{"metadata":{"name":"demo-pkg","version":"1.2.4"}}]}' > "${work}/report"
t_assert_rc 1 python3 "${plan}" "${work}/requirements" "${work}/report" "${work}/full-lock" "${work}/constraints"
t_case 'a broken pip report cannot pass'
reset_inputs
printf '{}' > "${work}/report"
t_assert_rc 1 python3 "${plan}" "${work}/requirements" "${work}/report" "${work}/full-lock" "${work}/constraints"
t_case 'an omitted image package with the wrong version is rejected'
reset_inputs
printf '{"install":[]}' > "${work}/report"
printf 'demo-pkg==1.0.0\n' > "${work}/constraints"
t_assert_rc 1 python3 "${plan}" "${work}/requirements" "${work}/report" "${work}/full-lock" "${work}/constraints"
mkdir -p "${work}/image" "${work}/shadow"
printf 'value = 1\n' > "${work}/image/overlay_fixture.py"
printf 'value = 2\n' > "${work}/shadow/overlay_fixture.py"
t_case 'an image module is accepted and a shadowed module is rejected'
t_assert_rc 0 env PYTHONPATH="${work}/image" python3 "${modules}" "${work}/image" overlay_fixture
t_assert_rc 1 env PYTHONPATH="${work}/shadow" python3 "${modules}" "${work}/image" overlay_fixture
t_case 'missing image modules fail'
t_assert_rc 1 env PYTHONPATH="${work}/image" python3 "${modules}" "${work}/image" missing_overlay_fixture
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$PY_ARGS"\nexit "${PY_RC:-0}"\n' > "${work}/record-python"
chmod +x "${work}/record-python"
t_case 'the module check needs at least one module and runs the verifier beside it, isolated'
t_assert_rc 1 bash -c 'source "$1"; uv_image_overlay_verify_modules "$2" "$3"' _ "${here}/01-core/uv-image-overlay.sh" "${work}/record-python" "${work}/image"
t_assert_rc 0 env PY_ARGS="${work}/py-args" bash -c 'source "$1"; uv_image_overlay_verify_modules "$2" "$3" overlay_fixture numpy' _ "${here}/01-core/uv-image-overlay.sh" "${work}/record-python" "${work}/image"
t_assert_eq "-I
${modules}
${work}/image
overlay_fixture
numpy" "$(cat "${work}/py-args")"
t_assert_rc 3 env PY_ARGS="${work}/py-args" PY_RC=3 bash -c 'source "$1"; uv_image_overlay_verify_modules "$2" "$3" overlay_fixture' _ "${here}/01-core/uv-image-overlay.sh" "${work}/record-python" "${work}/image"
t_summary
