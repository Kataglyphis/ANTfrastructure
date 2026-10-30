#!/usr/bin/env bash
# The GenAI artifact gate and the header copy of the producer on fixture trees; no build, container or network runs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
VERIFIER="${1:-${TESTS_DIR}/../03-media/runtime/verify-media-artifacts.sh}"
PRODUCER="${2:-${TESTS_DIR}/../03-media/build/onnxruntime/build/60-build-genai.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

GENAI_ITEMS=(lib/libonnxruntime-genai.so include/ort_genai.h include/ort_genai_c.h
  wheels/onnxruntime_genai-0.17.0-cp315-cp315-linux_x86_64.whl)

# <dir> "<omitted item | item=empty>..." <item>...: writes each item unless the specs omit or empty it
_fill() {
  local dir="$1" specs=" $2 " item; shift 2
  for item in "$@"; do
    case "${specs}" in
      *" ${item} "*) ;;
      *" ${item}=empty "*) : > "${dir}/${item}" ;;
      *) printf '/* %s */\n' "${item}" > "${dir}/${item}" ;;
    esac
  done
}

# [item to omit | item=empty]...: prints a fresh install tree
_genai_tree() {
  local prefix
  prefix="$(mktemp -d -p "${WORK}")" || return 1
  mkdir -p "${prefix}/lib" "${prefix}/include" "${prefix}/wheels" || return 1
  _fill "${prefix}" "$*" "${GENAI_ITEMS[@]}"
  printf '%s\n' "${prefix}"
}

# <tree> <status> [expected text]...: runs the verifier on a tree and checks its verdict
_expect_verify() {
  local tree="$1" expected="$2" status=0 text; shift 2
  env -u TARGET_ARCH -u TARGETARCH BUILD_MODE=native BUILD_GENAI=true GENAI_ALLOW_RISCV64=true \
    bash "${VERIFIER}" onnxruntime-genai "${tree}" > "${WORK}/output" 2>&1 || status=$?
  t_assert_eq "${expected}" "${status}"
  for text in "$@"; do t_assert_contains "$(cat "${WORK}/output")" "${text}"; done
}

t_case "verifier: a complete tree passes"
tree="$(_genai_tree)" || exit 1
_expect_verify "${tree}" 0 'All artifact checks passed'

t_case "verifier: the legacy library name passes"
tree="$(_genai_tree lib/libonnxruntime-genai.so)" || exit 1
printf 'bytes' > "${tree}/lib/libonnxruntime_genai.so"
_expect_verify "${tree}" 0

t_case "verifier: a wheel without the library fails"
tree="$(_genai_tree lib/libonnxruntime-genai.so)" || exit 1
_expect_verify "${tree}" 1 'FAIL [onnxruntime-genai]: ONNX Runtime GenAI library: none of the expected libraries found'

for header in ort_genai.h ort_genai_c.h; do
  label='GenAI C++ header'; [ "${header}" = ort_genai.h ] || label='GenAI C header'
  t_case "verifier: a missing ${header} fails"
  tree="$(_genai_tree "include/${header}")" || exit 1
  _expect_verify "${tree}" 1 "FAIL [onnxruntime-genai]: ${label} not found: ${tree}/include/${header}" \
    '=== 1 artifact verification failure(s)'
  t_case "verifier: an empty ${header} fails"
  tree="$(_genai_tree "include/${header}=empty")" || exit 1
  _expect_verify "${tree}" 1 "FAIL [onnxruntime-genai]: ${label} is empty: ${tree}/include/${header}"
done

t_case "verifier: every missing piece is counted once"
tree="$(_genai_tree lib/libonnxruntime-genai.so include/ort_genai.h include/ort_genai_c.h)" || exit 1
_expect_verify "${tree}" 1 '=== 3 artifact verification failure(s)'

copy_src="$(t_fn_src "${PRODUCER}" genai_copy_headers)" || exit 1
eval "${copy_src}"
err() { printf 'ERR:%s\n' "$*"; exit 1; }
info() { printf 'INFO:%s\n' "$*"; }

# [header to omit | header=empty]...: sets SRC to a fresh GenAI checkout and OUT to an install tree
_genai_src() {
  SRC="$(mktemp -d -p "${WORK}")" && OUT="$(mktemp -d -p "${WORK}")" || return 1
  mkdir -p "${SRC}/src" "${OUT}/include" || return 1
  _fill "${SRC}/src" "$*" ort_genai.h ort_genai_c.h
}

# <status> [expected text]: copies SRC into OUT in a subshell, since err exits
_expect_copy() {
  local status=0
  ( genai_copy_headers "${SRC}" "${OUT}" ) > "${WORK}/output" 2>&1 || status=$?
  t_assert_eq "$1" "${status}"
  [ -z "${2:-}" ] || t_assert_contains "$(cat "${WORK}/output")" "$2"
}

t_case "producer: both headers are copied byte for byte"
_genai_src || exit 1
_expect_copy 0
for hdr in ort_genai.h ort_genai_c.h; do
  t_assert_eq "$(cat "${SRC}/src/${hdr}")" "$(cat "${OUT}/include/${hdr}" 2>/dev/null)" "${hdr} copied"
done

for hdr in ort_genai.h ort_genai_c.h; do
  for shape in missing empty; do
    t_case "producer: a ${shape} ${hdr} stops the build"
    if [ "${shape}" = missing ]; then _genai_src "${hdr}" || exit 1; else _genai_src "${hdr}=empty" || exit 1; fi
    _expect_copy 1 "ERR:GenAI header ${hdr} not found in ${SRC}/src"
  done
done

t_case "producer: a failed copy stops the build"
_genai_src || exit 1
OUT="$(mktemp -d -p "${WORK}")" || exit 1
_expect_copy 1 "ERR:cannot copy GenAI header ort_genai.h to ${OUT}/include"

t_summary
