#!/usr/bin/env bash
# Local directory fixtures cover fetched-name policy and traversal boundaries, not builds, downloads or runtime loading.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PROVENANCE="${1:-${TESTS_DIR}/../03-media/ort-provenance.sh}"
GENAI="${2:-${TESTS_DIR}/../03-media/verify-genai-ort.sh}"
RECEIPT="${3:-}"
[ -z "$RECEIPT" ] || : > "$RECEIPT"
# shellcheck source=../03-media/ort-provenance.sh
source "$PROVENANCE"
t_source_functions "$GENAI" _genai_ort_tree_findings
declare -A _ORTG_SHA=() GENAI_ORT_CHAIN_SHA=()
GENAI_ORT_NAMED=( \( -name '*onnxruntime*' -o -name '*_provider_factory.h' \) )

_ort_directory_case() {
  local relative="$1" g2="$2" genai="$3" type="$4" fixture="$6" consumer root path expected rc out
  root="$fixture/source tree spaces"; path="$root/$relative"
  if [ "$type" = file ]; then mkdir -p "${path%/*}"; touch "$path"; else mkdir -p "$path"; fi
  for consumer in g2 genai; do
    t_case "$consumer $relative $type"
    expected=''; rc=0
    _ORTG_FILES=0; _ORTG_FOUND_LINKS=()
    if [ "$consumer" = g2 ]; then
      if [ "$g2" = yes ]; then expected="fetched ONNX Runtime content at $path (through the link fixture link)"; fi
      if [ "$type" = nested ]; then expected="fetched ONNX Runtime content at ${path%/*} (through the link fixture link)"$'\n'"$expected"; fi
      _ortg_scan_root "$root" 'fixture link' > "$fixture/out" 2> "$fixture/err" || rc=$?
    else
      if [ "$genai" = yes ]; then expected="FetchContent populated ONNX Runtime content at $path"; fi
      if [ "$type" = nested ]; then expected="FetchContent populated ONNX Runtime content at ${path%/*}"; fi
      _genai_ort_tree_findings "$root" > "$fixture/out" 2> "$fixture/err" || rc=$?
    fi
    out="$(cat "$fixture/out")"
    t_assert_eq 0 "$rc"
    t_assert_eq '' "$(cat "$fixture/err")"
    t_assert_eq "$expected" "$out"
    t_record_fixture_receipt "$RECEIPT" "$consumer/$relative/$type" "$rc" "${out//${root}/ROOT}" "$(cat "$fixture/err")" "$_ORTG_FILES" "${#_ORTG_FOUND_LINKS[@]}" "${#GENAI_ORT_CHAIN_SHA[@]}" "${GENAI_ORT_NAMED[*]}"
  done
}
while IFS='|' read -r relative g2 genai type; do
  _t_probe_file _ort_directory_case "$relative" "$g2" "$genai" "$type"
done <<'CASES'
_deps/ortlib-src|yes|yes|directory
_deps/ortlib-subbuild|yes|yes|directory
_deps/ortlib-build|yes|yes|directory
_deps/ortlib-extra|no|yes|directory
_deps/onnxruntime-src|yes|yes|directory
_deps/onnxruntime-subbuild|yes|yes|directory
_deps/onnxruntime-build|yes|yes|directory
outside/onnxruntime-src|yes|no|directory
_deps/ONNXRUNTIME-SRC|no|no|directory
_deps/onnxruntime-src-extra|no|no|directory
_deps/ort.pyke.io|yes|no|directory
_deps/ONNXRUNTIME-LINUX-aarch64|yes|no|directory
_deps/Microsoft.ML.OnnxRuntime.Gpu|yes|no|directory
_deps/Microsoft.ML.OnnxRuntimeGenAI|no|no|directory
_deps/onnxruntime-build|no|no|file
_deps/ortlib-src/onnxruntime-build|yes|yes|nested
CASES
t_summary
