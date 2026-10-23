#!/usr/bin/env bash
# Local files characterize digest boundaries, archive policies and counters; no ORT build, download or runtime loading occurs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PROVENANCE="${1:-${TESTS_DIR}/../03-media/ort-provenance.sh}"
GENAI="${2:-${TESTS_DIR}/../03-media/verify-genai-ort.sh}"
WORK="$(mktemp -d '/tmp/ant-ORT digest fixture.XXXXXXXX')"
trap 'rm -rf "${WORK}"' EXIT
cp "${PROVENANCE}" "${WORK}/ort-provenance.sh"
sed '/^main "\$@"$/d' "${GENAI}" > "${WORK}/genai.sh"
# shellcheck source=/dev/null
source "${WORK}/genai.sh"
set +e
mkdir -p "${WORK}/tree" "${WORK}/chain A/include" "${WORK}/chain A/lib" "${WORK}/chain B/include" "${WORK}/chain B/lib"
for tag in A B; do
  printf 'header %s' "${tag}" > "${WORK}/chain ${tag}/include/onnxruntime_c_api.h"
  printf 'library %s' "${tag}" > "${WORK}/chain ${tag}/lib/libonnxruntime.so"
done
hash_a="$(_ortg_sha "${WORK}/chain A/lib/libonnxruntime.so")"
hash_b="$(_ortg_sha "${WORK}/chain B/lib/libonnxruntime.so")"
t_case 'both indexes retain every same-basename hash from multiple roots'
_ortg_index "${WORK}/chain A" "${WORK}/chain B" > "${WORK}/output"
t_assert_eq '' "$(cat "${WORK}/output")"
t_assert_eq " ${hash_a}  ${hash_b} " "${_ORTG_SHA[libonnxruntime.so]}"
_genai_ort_index_chain "${WORK}/chain A" "${WORK}/chain B" > "${WORK}/output"
t_assert_eq '' "$(cat "${WORK}/output")"
t_assert_eq " ${hash_a} ${hash_b}" "${GENAI_ORT_CHAIN_SHA[libonnxruntime.so]}"
sha256sum() {
  if [ "${FAIL_HASH:-0}" = 1 ]; then return 19; fi
  command sha256sum "$@"
}
for consumer in g2 genai; do
  for scenario in first second foreign prefix suffix missing-end dangling unreadable; do
    t_case "${consumer}: ${scenario} digest with spaced paths"
    rm -f "${WORK}/tree/libonnxruntime.so"
    cp "${WORK}/chain A/lib/libonnxruntime.so" "${WORK}/tree/libonnxruntime.so"
    hashes=" ${hash_a} ${hash_b}"; matches=no; FAIL_HASH=0
    case "${scenario}" in
      first) matches=yes ;;
      second) cp "${WORK}/chain B/lib/libonnxruntime.so" "${WORK}/tree/libonnxruntime.so"; matches=yes ;;
      foreign) printf foreign > "${WORK}/tree/libonnxruntime.so" ;;
      prefix) hashes=" x${hash_a}" ;;
      suffix) hashes=" ${hash_a}x" ;;
      missing-end) hashes=" ${hash_a}"; if [ "${consumer}" = genai ]; then matches=yes; fi ;;
      dangling) rm "${WORK}/tree/libonnxruntime.so"; ln -s missing-library "${WORK}/tree/libonnxruntime.so" ;;
      unreadable) FAIL_HASH=1 ;;
    esac
    _ORTG_COMPARED=0; status=0
    if [ "${consumer}" = g2 ]; then
      if [ "${scenario}" != missing-end ]; then hashes+=' '; fi
      _ORTG_SHA[libonnxruntime.so]="${hashes}"
      _ortg_name_finding "${WORK}/tree/libonnxruntime.so" ' (through the link /fixture link)' > "${WORK}/output" || status=$?
      suffix=' (through the link /fixture link)'
      t_assert_eq 1 "${_ORTG_COMPARED}"
    else
      GENAI_ORT_CHAIN_SHA[libonnxruntime.so]="${hashes}"
      _genai_ort_tree_findings "${WORK}/tree" > "${WORK}/output" || status=$?
      suffix=''
      t_assert_eq 0 "${_ORTG_COMPARED}" 'GenAI findings never change the G2 comparison counter'
    fi
    expected=''
    if [ "${matches}" = no ]; then expected="${WORK}/tree/libonnxruntime.so is not the chain's libonnxruntime.so (foreign ONNX Runtime bytes)${suffix}"; fi
    t_assert_eq "${expected}" "$(cat "${WORK}/output")"
    t_assert_eq 0 "${status}" 'findings are data; the outer gate owns the failing verdict'
  done
  FAIL_HASH=0
  rm -f "${WORK}/tree/libonnxruntime.so"
  _ORTG_SHA=(); GENAI_ORT_CHAIN_SHA=()
  for name in onnxruntime.zip onnxruntime.7z ONNXRUNTIME.TGZ onnxruntime_genai.whl onnxruntime_extensions.tar; do
    t_case "${consumer}: archive classification ${name}"
    : > "${WORK}/tree/${name}"
    _ORTG_COMPARED=0; expected=''
    if [ "${consumer}" = g2 ]; then
      _ortg_name_finding "${WORK}/tree/${name}" ' suffix' > "${WORK}/output"
      case "${name}" in onnxruntime.zip|onnxruntime.7z|ONNXRUNTIME.TGZ) expected="an ONNX Runtime archive: ${WORK}/tree/${name} suffix" ;; esac
    else
      _genai_ort_tree_findings "${WORK}/tree" > "${WORK}/output"
      if [ "${name}" = onnxruntime.zip ]; then expected="an ONNX Runtime archive sits in the tree: ${WORK}/tree/${name}"; fi
    fi
    t_assert_eq "${expected}" "$(cat "${WORK}/output")"
    t_assert_eq 0 "${_ORTG_COMPARED}" 'archive and exempt names do not increment compared-file counts'
    rm "${WORK}/tree/${name}"
  done
done
unset -f sha256sum
t_summary
