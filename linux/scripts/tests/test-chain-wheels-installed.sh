#!/usr/bin/env bash
# assert_chain_wheels_installed on a real venv with fixture dist-infos, plus the install wiring (CON52); no real wheel.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../03-media/runtime/assemble-torch-app.sh"
_PY="${PREFLIGHT_PYTHON:-python3}"

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
"${_PY}" -m venv --without-pip "${_work}/venv" || { echo "FAIL: no venv module"; exit 1; }
_site="$("${_work}/venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
_store="${_work}/wheels"; mkdir -p "${_store}"

_lib="${_work}/lib.sh"
for _fn in wheel_family assert_chain_wheels_installed; do
  t_fn_src "${SUBJECT}" "${_fn}" >> "${_lib}" || exit 1
done

# _dist NAME VERSION [URL]: a dist-info the venv's importlib.metadata finds; no URL = an index install.
_dist() {
  local d="${_site}/${1//-/_}-$2.dist-info"
  rm -rf "${_site}/${1//-/_}"-*.dist-info; mkdir -p "${d}"
  printf 'Metadata-Version: 2.1\nName: %s\nVersion: %s\n' "$1" "$2" > "${d}/METADATA"
  [ -z "${3:-}" ] || printf '{"url": "%s", "archive_info": {}}' "$3" > "${d}/direct_url.json"
}
_stage() { rm -f "${_store}"/*.whl; local w; for w in "$@"; do : > "${_store}/${w}"; done; }
_run() {  # $1 = uname -m; prints the gate's output and rc
  VENV="${_work}/venv" LOCAL_WHEELS_DIR="${_store}" _T_ARCH="$1" bash -c '
    uname() { printf "%s\n" "${_T_ARCH}"; }
    staged_opencv_python_available() { return 0; }
    source "'"${_lib}"'"
    assert_chain_wheels_installed; echo "rc=$?"' 2>&1
}

LITERT=ai_edge_litert-2.2.0-cp314-cp314-linux_x86_64.whl
GENAI=onnxruntime_genai-0.15.2-cp314-cp314-linux_x86_64.whl

t_case "every staged wheel installed from the store passes"
_stage "${LITERT}" "${GENAI}"
_dist ai-edge-litert 2.2.0 "file://${_store}/${LITERT}"
_dist onnxruntime-genai 0.15.2 "file://${_store}/${GENAI}"
_out="$(_run x86_64)"
t_assert_contains "${_out}" "CHAIN-WHEEL OK ai-edge-litert 2.2.0" "litert"
t_assert_contains "${_out}" "CHAIN-WHEEL PASS" "pass line"
t_assert_contains "${_out}" "rc=0" "rc"

t_case "the lock's PyPI build in place of a staged wheel fails, and names both"
_dist onnxruntime-genai 0.15.2
_out="$(_run x86_64)"
t_assert_contains "${_out}" "CHAIN-WHEEL FAIL onnxruntime-genai: the venv has 0.15.2 from an index; the chain staged ${GENAI}" "same version, wrong source"
t_assert_contains "${_out}" "rc=1" "fatal"

t_case "a staged wheel the venv lacks fails"
rm -rf "${_site}"/onnxruntime_genai-*.dist-info
t_assert_contains "$(_run x86_64)" "onnxruntime-genai: not in the venv" "absent"

t_case "a stale wheel from an older chain fails: the URL must name this store's file"
_dist onnxruntime-genai 0.15.1 "file://${_store}/onnxruntime_genai-0.15.1-cp314-cp314-linux_x86_64.whl"
t_assert_contains "$(_run x86_64)" "rc=1" "another file in the same store"

t_case "TVM, source-bound OpenCV and riscv64 IREE are exempt; IREE elsewhere is not"
_stage "${LITERT}" apache_tvm-0.26.dev1-py3-none-linux_x86_64.whl opencv_python-5.0.0-cp314-cp314-linux_x86_64.whl \
  iree_base_runtime-3.11.0-cp314-cp314-linux_riscv64.whl
t_assert_contains "$(_run riscv64)" "rc=0" "all three exempt on riscv64"
t_assert_contains "$(_run x86_64)" "CHAIN-WHEEL FAIL iree-base-runtime" "IREE is required off riscv64"

t_case "an empty store checks nothing"
_stage
t_assert_eq "rc=0" "$(_run x86_64)" "no wheel, no python run"

t_case "the install order: sync, then reconcile installs the store, then the pins, then this gate (CON52)"
_body="$(t_fn_src "${SUBJECT}" install_project_environment)"
_seq="$(printf '%s\n' "${_body}" | grep -oE '^  (build_uv_sync_args|run_uv_sync_with_fallback|reconcile_local_wheels|enforce_torch_version_pins|assert_chain_wheels_installed)' | tr -d ' ' | tr '\n' ' ')"
t_assert_eq "build_uv_sync_args run_uv_sync_with_fallback reconcile_local_wheels enforce_torch_version_pins assert_chain_wheels_installed " "${_seq}"
t_assert_eq "" "$(t_fn_src "${SUBJECT}" run_uv_sync_with_fallback | grep -e 'uv pip install' || true)" \
  "the sync fallback installs no wheel: reconcile_local_wheels is the one install point"

t_summary
