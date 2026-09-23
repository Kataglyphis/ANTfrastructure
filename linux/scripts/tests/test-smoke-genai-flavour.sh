#!/usr/bin/env bash
# The runtime smoke's ARCH-PARITY and VENV-SET gates count a flavoured chain GenAI (nvidia) as the GenAI.
# NOT covered: a real image (recorded probe text only) and the GEN1 binding gate (test-genai-smoke-payload.sh).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PKG_DIR="${TESTS_DIR}/../06-packaging"
RT_SMOKE="${PKG_DIR}/smoke-runtime-image.sh"

# The smoke minus its main() call, beside every sibling it sources.
_SB="$(mktemp -d)"; trap 'rm -rf "${_SB}"' EXIT
cp "${PKG_DIR}"/*.sh "${PKG_DIR}"/*.py "${_SB}/"
sed '$d' "${RT_SMOKE}" > "${_SB}/rt.sh"
_rt() { bash -c "source '${_SB}/rt.sh' >/dev/null 2>&1"$'\n'"$1" 2>&1; }

t_case "the sandbox holds: main() is the smoke's last line, and the smoke sources cleanly"
t_assert_eq 'main "$@"' "$(tail -1 "${RT_SMOKE}")"
t_assert_eq "loaded" "$(_rt 'echo loaded')"

# check_arch_parity against a recorded probe; $1 = arch, $2 = ENABLE_NVIDIA, rest = dist-info names.
_parity() {
  local arch="$1" nv="$2"; shift 2
  NV="${nv}" DISTS="$(printf 'DIST %s\n' "$@")" _rt "_rt_run() { printf 'NVIDIA %s\nAMD false\n' \"\${NV}\"
for p in \${_PARITY_PREFIXES}; do printf 'PREFIX %s\n' \"\${p}\"; done; printf '%s\n' \"\${DISTS}\"; }
check_arch_parity img ${arch}; echo \"FAILURES=\${FAILURES}\""
}
_BASE=(torch torchvision ai_edge_litert iree_base_compiler iree_base_runtime)

t_case "ARCH-PARITY: an nvidia image's chain GenAI counts under its flavour name"
_out="$(_parity amd64 true "${_BASE[@]}" onnxruntime_gpu onnxruntime_genai_trt_rtx)"
t_assert_contains "${_out}" "FAILURES=0" "amd64 nvidia, TensorRT on: onnxruntime-genai-trt-rtx"
_out="$(_parity arm64 true "${_BASE[@]}" onnxruntime_gpu onnxruntime_genai_cuda)"
t_assert_contains "${_out}" "FAILURES=0" "arm64 nvidia (Jetson): onnxruntime-genai-cuda"

t_case "ARCH-PARITY: the plain GenAI still passes, and no GenAI at all still fails"
t_assert_contains "$(_parity amd64 false "${_BASE[@]}" onnxruntime_dnnl onnxruntime_genai)" "FAILURES=0" "cpu amd64"
_out="$(_parity amd64 true "${_BASE[@]}" onnxruntime_gpu)"
t_assert_contains "${_out}" "ARCH-PARITY: onnxruntime_genai missing on amd64" "absent"
t_assert_contains "${_out}" "FAILURES=1" "and only that"
t_assert_contains "$(_parity amd64 true "${_BASE[@]}" onnxruntime_gpu onnxruntime_genaix)" \
  "onnxruntime_genai missing on amd64" "a lookalike name is not a flavour"

t_case "_pkg_count: GenAI is the one package with flavours; every other name is exact"
t_assert_eq "1" "$(_rt '_pkg_count onnxruntime-genai onnxruntime-genai-cuda')" "venv-set spelling"
t_assert_eq "0" "$(_rt '_pkg_count torch torch_tensorrt')" "torch_tensorrt is not torch"
t_assert_eq "0" "$(_rt '_pkg_count pandas pandas-stubs')" "pandas-stubs is not pandas"
t_assert_eq "1" "$(_rt '_pkg_count iree_base_compiler iree_base_compiler')" "parity spelling"

# _venv_set_verdicts against a recorded probe; $1 = arch, $2 = installed packages (space separated).
_venvset() {
  PKGS="$2" _rt "p=\"\$(printf 'ADV PYTORCH_EXTRA none\nREQ ml-ai onnxruntime-genai\nREQ ml-ai pandas\nREQ docs sphinx\n'
printf 'PKG %s\n' \${PKGS})\"; _venv_set_verdicts $1 \"\${p}\""
}

t_case "VENV-SET: the app's onnxruntime-genai edge is met by the nvidia flavour"
_out="$(_venvset amd64 'pandas sphinx onnxruntime-gpu onnxruntime-genai-trt-rtx')"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -E '^(MISS|STALE)' || true)" "no MISS, no STALE"
t_assert_contains "${_out}" "ASSERTED 3" "the GenAI edge is asserted, not skipped"
t_assert_contains "$(_venvset arm64 'pandas sphinx onnxruntime-gpu onnxruntime-genai-cuda')" "ASSERTED 3" "Jetson"

t_case "VENV-SET: the plain GenAI is asserted too, so no blanket exemption may exist"
t_assert_contains "$(_venvset amd64 'pandas sphinx onnxruntime-dnnl onnxruntime-genai')" "ASSERTED 3" "cpu"
t_assert_fails _rt '_venv_pkg_exempt amd64 ml-ai onnxruntime-genai'

t_case "VENV-SET: an absent GenAI, a lookalike, or a lookalike of another package is a MISS"
t_assert_contains "$(_venvset amd64 'pandas sphinx onnxruntime-gpu')" "MISS ml-ai onnxruntime-genai" "absent"
t_assert_contains "$(_venvset amd64 'pandas sphinx onnxruntime-genaix')" "MISS ml-ai onnxruntime-genai" "lookalike"
t_assert_contains "$(_venvset amd64 'pandas-stubs sphinx onnxruntime-genai')" "MISS ml-ai pandas" "exact elsewhere"

t_summary
