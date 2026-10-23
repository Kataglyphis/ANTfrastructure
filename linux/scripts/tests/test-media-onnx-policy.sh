#!/usr/bin/env bash
# Stubbed imports and filesystem probes check media-stage policy, not real ONNX inference or packaged runtime contents.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
MEDIA="${1:-${TESTS_DIR}/../06-packaging/smoke-media.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
sed -n '/^# ONNX Runtime: import/,/^# LiteRT: C API/p' "${MEDIA}" > "${WORK}/onnx.sh"
run_onnx() {
  local cross="$1" library="$2" import_rc="$3" cpu_rc="$4"
  (
    set -euo pipefail
    export ONNXRUNTIME_OUTPUT_DIR='/fixture/ort with spaces'
    export ONNXRUNTIME_GENAI_OUTPUT_DIR=/fixture/genai
    pass() { printf 'PASS:%s\n' "$*"; }
    fail() { printf 'FAIL:%s\n' "$*"; ERRORS=$((ERRORS + 1)); }
    cross_build_is_active() { [ "${cross}" = cross ]; }
    smoke_cross_presence_gate() { printf 'PRESENCE:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4"; return "${PRESENCE_RC:-0}"; }
    find() {
      printf '%s\n' "$*" >> "${WORK}/find-args"
      if [ "${library}" = present ]; then printf '/fixture/library.so\n'; fi
    }
    command() {
      if [ "$*" = '-v python3' ] && [ "${NO_PYTHON:-0}" = 1 ]; then return 1; fi
      builtin command "$@"
    }
    python3() {
      printf '%s\n' "$*" >> "${WORK}/python-args"
      case "$*" in
        *CPUExecutionProvider*) return "${cpu_rc}" ;;
        *__version__*) printf 'fixture-version\n' ;;
        *) return "${import_rc}" ;;
      esac
    }
    ERRORS=0
    : > "${WORK}/find-args"; : > "${WORK}/python-args"
    source "${WORK}/onnx.sh"
    printf 'ERRORS=%s\n' "${ERRORS}"
  )
}
t_case 'native imports exercise CPU EP without requiring library fallback'
out="$(run_onnx native absent 0 0)"
t_assert_contains "${out}" 'PASS:onnxruntime Python module imports (vfixture-version)'
t_assert_contains "${out}" 'PASS:onnxruntime CPUExecutionProvider available'
t_assert_contains "${out}" 'PASS:onnxruntime_genai Python module imports'
t_assert_eq '' "$(cat "${WORK}/find-args")"
t_case 'an imported ORT without CPU EP fails, while GenAI retains its import check'
out="$(run_onnx native present 0 7)"
t_assert_contains "${out}" 'FAIL:onnxruntime CPUExecutionProvider not available'
t_assert_contains "${out}" ERRORS=1
t_case 'native failed imports defer only when actual libraries exist'
out="$(run_onnx native present 1 0)"
t_assert_contains "${out}" 'onnxruntime present but import fails in build sandbox'
t_assert_contains "${out}" 'onnxruntime_genai lib present but import fails in build sandbox'
t_assert_contains "${out}" ERRORS=0
t_assert_contains "$(cat "${WORK}/find-args")" '/fixture/ort with spaces -name libonnxruntime.so* -type f'
t_assert_contains "$(cat "${WORK}/find-args")" '/fixture/genai /usr/local/lib -name libonnxruntime*genai* -type f'
t_case 'missing native libraries fail required ORT but leave GenAI optional'
out="$(run_onnx native absent 1 0)"
t_assert_contains "${out}" 'FAIL:onnxruntime import fails AND no libonnxruntime.so under /fixture/ort with spaces'
t_assert_contains "${out}" 'onnxruntime_genai not installed (optional)'
t_assert_contains "${out}" ERRORS=1
for library in present absent; do
  t_case "cross ${library} libraries never execute Python"
  out="$(run_onnx cross "${library}" 0 0)"
  t_assert_eq '' "$(cat "${WORK}/python-args")"
  if [ "${library}" = present ]; then
    t_assert_contains "${out}" 'PRESENCE:onnxruntime:/fixture/ort with spaces:library:import'
    t_assert_contains "${out}" 'PASS:onnxruntime_genai library present (cross build — import skipped)'
    t_assert_contains "${out}" ERRORS=0
  else
    t_assert_contains "${out}" 'FAIL:onnxruntime library not found at /fixture/ort with spaces'
    t_assert_contains "${out}" 'onnxruntime_genai not built for this target (optional)'
    t_assert_contains "${out}" ERRORS=1
  fi
done
t_case 'a cross presence gate declining cannot produce green required ORT'
out="$(PRESENCE_RC=1 run_onnx cross present 0 0)"
t_assert_contains "${out}" 'FAIL:onnxruntime presence gate declined inside the cross branch'
t_assert_contains "${out}" ERRORS=1
t_case 'without native Python neither module is probed or mislabeled missing'
out="$(NO_PYTHON=1 run_onnx native absent 1 0)"
t_assert_contains "${out}" ERRORS=0
t_assert_eq '' "$(cat "${WORK}/find-args")"
t_assert_eq '' "$(cat "${WORK}/python-args")"
t_summary
