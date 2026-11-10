#!/usr/bin/env bash
# Stub child interpreters exercise isolated GIL/FT dispatch and raw verdicts; no real ORT registration or GPU runs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../06-packaging/check-ort-runtime.sh"
source "${TESTS_DIR}/../06-packaging/check-free-threaded-wheels.sh"
work="$(mktemp -d)"
trap 'command rm -r -- "${work}"' EXIT
pass() { printf 'PASS %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf 'FAIL %s\n' "$*"; }
_rt_versions_env_pin() { printf '%s' 'v1.31.1'; }
_rt_run() { printf '%s\n' "$@" >> "${work}/gil-argv"; echo 'WEBGPU-FACTORY OK: fixture'; }
FAILURES=0
check_webgpu_factories image arm64 > "${work}/gil-output"
t_assert_eq 0 "${FAILURES}"
t_assert_eq $'/opt/venv/bin/python\n-I\n/opt/scripts/03-media/final/ort_webgpu_runtime.py\n--phase\nnative\n--source-ref\nv1.31.1\n/opt/venv/bin/python\n-I\n/opt/scripts/03-media/final/ort_webgpu_runtime.py\n--phase\ngil\n--source-ref\nv1.31.1' "$(cat "${work}/gil-argv")"
t_assert_contains "$(t_fn_src "${TESTS_DIR}/../06-packaging/smoke-runtime-image.sh" main)" 'check_webgpu_factories "${image_tag}" "${target_arch}"'
mkdir -p "${work}/bin" "${work}/opt/wheels-free-threaded" "${work}/opt/scripts/03-media"
cp "${TESTS_DIR}/../03-media/free-threaded-wheels.sh" "${TESTS_DIR}/../03-media/free-threaded-twins.txt" "${work}/opt/scripts/03-media/"
cat > "${work}/bin/uv" <<'UV'
#!/usr/bin/env bash
if [ "$1" = venv ]; then
  mkdir -p "${!#}/bin"
  cp "${FT_FAKE_PY}" "${!#}/bin/python"
fi
UV
cat > "${work}/python" <<'STUB_INTERPRETER'
#!/usr/bin/env bash
case "$*" in
  *ort_webgpu_runtime.py*)
    printf '%s\n' "$0" "$@" > "${FT_FACTORY_LOG}"
    if [ "${FT_FACTORY_STATUS}" = 0 ]; then echo 'WEBGPU-FACTORY OK: actual-child-fixture'; else echo 'WEBGPU-FACTORY FAIL: child failed' >&2; fi
    exit "${FT_FACTORY_STATUS}" ;;
  *) echo 'compiled modules proved' ;;
esac
STUB_INTERPRETER
chmod +x "${work}/bin/uv" "${work}/python"
program="$(ft_store_probe_script)"
program="${program//\/opt\//${work}/opt/}"
program="${program//\/tmp\/fts./${work}/fts.}"
for distribution in onnxruntime_dnnl onnxruntime_gpu onnxruntime onnxruntime_genai; do
  wheel="${work}/opt/wheels-free-threaded/${distribution}-1.31.1-cp314-cp314t-linux_x86_64.whl"
  : > "${wheel}"
  for child_status in 0 7; do
    command rm -f -- "${work}/factory-argv"
    PATH="${work}/bin:${PATH}" FT_FAKE_PY="${work}/python" FT_FACTORY_LOG="${work}/factory-argv" \
      FT_FACTORY_STATUS="${child_status}" WEBGPU_EXPECT_REF=v1.31.1 PYTHON_MAJOR_MINOR=3.14 \
      bash -c "${program}" > "${work}/ft-output" 2>&1
    output="$(cat "${work}/ft-output")"
    if [ "${distribution}" = onnxruntime_genai ]; then
      t_assert_fails test -e "${work}/factory-argv"
    else
      t_assert_ok test -s "${work}/factory-argv"
      argv="$(tail -n +2 "${work}/factory-argv")"
      t_assert_eq "$(printf '%s\n' -I "${work}/opt/scripts/03-media/final/ort_webgpu_runtime.py" --phase free-threaded --source-ref v1.31.1)" "${argv}"
      interpreter="$(head -n 1 "${work}/factory-argv")"
      [[ "${interpreter}" == "${work}/fts."*/venv/bin/python ]] || t_fail 'FT probe used a different interpreter'
      if [ "${child_status}" = 0 ]; then
        t_assert_contains "${output}" "FTS WEBGPU ${distribution} WEBGPU-FACTORY OK: actual-child-fixture"
      else
        t_assert_contains "${output}" "FTS WEBGPU-FAIL ${distribution} WEBGPU-FACTORY FAIL: child failed"
      fi
    fi
    t_assert_contains "${output}" 'FTS DONE'
  done
  command rm -- "${wheel}"
done
t_summary
