#!/usr/bin/env bash
# Shared native-binding transport preserves raw failures; the WebGPU gate proves registration, not a usable device.

_rt_run_python_probe() {
  local variable="$1" tag="$2" program="$3"
  shift 3
  _rt_run -e "${variable}=${program}" "$@" bash -lc "$(smoke_python_probe_command "${variable}" "${tag}")"
}

# Both probes require an OK sentinel; only GenAI may be absent from an image.
_rt_native_python_verdict() {
  local kind="$1" out="$2" rc="$3" target_arch="$4" sentinel tag
  local -A _rt_native_tags=([onnx]=ONNX-EP [genai]=GENAI-BIND)
  local -A _rt_native_names=([onnx]='onnxruntime session check' [genai]='onnxruntime-genai binding check')
  local -A _rt_native_nouns=([onnx]=provider [genai]=binding)
  local -A _rt_native_successes=([onnx]='onnxruntime executed a real graph on-target' [genai]='onnxruntime-genai native binding exercised on-target')
  local -A _rt_native_failures=([onnx]='onnxruntime InferenceSession FAILED on the generated Add graph' [genai]='onnxruntime-genai binding check FAILED')
  tag="${_rt_native_tags[${kind}]}"
  printf '%s\n' "${out}" | sed 's/^/  /'
  sentinel="$(printf '%s\n' "${out}" | grep -Eo "${tag} (OK|FAIL|SKIP|ABSENT):.*" | head -1 || true)"
  if [ -z "${sentinel}" ]; then
    fail "${_rt_native_names[${kind}]} exited ${rc} but printed NO ${tag} sentinel (${target_arch}) -- the generated program did not run; an exit 0 here means python got an EMPTY stdin, not a working ${_rt_native_nouns[${kind}]}"
  elif [ "${rc}" = 0 ]; then
    case "${sentinel}" in
      "${tag} OK:"*) pass "${_rt_native_successes[${kind}]} (${target_arch}) -- ${sentinel}" ;;
      *) fail "${_rt_native_names[${kind}]} exited 0 but reported '${sentinel}' (${target_arch}) -- a non-OK verdict must never pass" ;;
    esac
  elif [ "${rc}" = 3 ]; then
    case "${kind}" in
      onnx) fail "onnxruntime/numpy not importable in the runtime image (${target_arch}) -- the HEALTHCHECK imports onnxruntime, so this is a defect: ${sentinel}" ;;
      genai) echo "  SKIP: onnxruntime_genai not installed in this image (${target_arch}); presence is asserted by ARCH-PARITY, not here" ;;
    esac
  else
    fail "${_rt_native_failures[${kind}]} (${target_arch}, rc=${rc}): ${sentinel}"
  fi
}
# A pass needs the ONNX-EP OK: sentinel: an empty SMOKE_ONNX_PY makes `python -` exit 0 having run nothing.
check_onnx_execution_provider() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: onnxruntime InferenceSession (generated Add graph) ---"
    local out rc
    out="$(_rt_run_python_probe SMOKE_ONNX_PY ONNX-EP "$(smoke_minimal_onnx_py)" 2>&1)" \
      && rc=0 || rc=$?
    _rt_native_python_verdict onnx "${out}" "${rc}" "${target_arch}"
    echo ""
}

# A pass needs the GENAI-BIND sentinel in the output, not exit 0 (docs/gen1-riscv64-genai.md).
check_genai_binding() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- Functional: onnxruntime-genai native binding (GEN1) ---"
    local expect_version out rc tiny_py="${_SCRIPT_DIR}/../lib/tiny-genai-model.py" tiny_src=""
    expect_version="$(_rt_versions_env_pin ONNXRUNTIME_GENAI_VERSION)"
    if [ -s "${tiny_py}" ]; then tiny_src="$(cat "${tiny_py}")"; else fail "no tiny GenAI model generator at ${tiny_py}"; fi
    out="$(_rt_run_python_probe SMOKE_GENAI_PY GENAI-BIND "$(smoke_genai_py)" -e "GENAI_TINY_MODEL_PY=${tiny_src}" \
      -e "GENAI_EXPECT_VERSION=${expect_version}" -e "GENAI_EXPECT_ARCH=${target_arch}" 2>&1)" && rc=0 || rc=$?
    _rt_native_python_verdict genai "${out}" "${rc}" "${target_arch}"
    echo ""
}

check_webgpu_factory_phase() {
  # shellcheck disable=SC2034  # _rt_run reads image_tag and target_arch by dynamic scope.
  local image_tag="$1" target_arch="$2" phase="$3" output status expected sentinels
  expected="$(_rt_versions_env_pin ONNXRUNTIME_VERSION)"
  output="$(_rt_run /opt/venv/bin/python -I /opt/scripts/03-media/final/ort_webgpu_runtime.py \
    --phase "${phase}" --source-ref "${expected}" 2>&1)" && status=0 || status=$?
  printf '%s\n' "${output}"
  sentinels="$(printf '%s\n' "${output}" | grep -c -e '^WEBGPU-FACTORY OK: ' || true)"
  if [ "${status}" = 0 ] && [ "${sentinels}" = 1 ]; then
    pass "WebGPU ${phase} factory and negative control passed (${target_arch})"
  else
    fail "WebGPU ${phase} factory failed (${target_arch}, rc=${status}): ${output}"
  fi
}

check_webgpu_factories() {
  local phase
  for phase in native gil; do
    check_webgpu_factory_phase "$1" "$2" "${phase}"
  done
}
