#!/usr/bin/env bash
# report_onnx_build_output — the one owner of the closing "what did this stage
# produce" summary the four onnxruntime build scripts print. Run off-target from
# its own source with info() stubbed, plus the pin that no caller keeps a copy.
# docs/code-quality-tooling.md#the-allowlist-contract
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
ORT="${TESTS_DIR}/../03-media/build/onnxruntime/build"
COMMON="${ORT}/lib/common.sh"

_fn="$(t_fn_src "${COMMON}" report_onnx_build_output)" || exit 1

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
{
  printf 'set -euo pipefail\n'
  printf 'info() { printf "[INFO] %%s\\n" "$*"; }\n'
  printf '%s\n' "${_fn}"
  printf 'report_onnx_build_output "$1" "$2"\n'
} > "${_work}/run.sh"
_run() { bash "${_work}/run.sh" "$1" "$2" 2>&1; }

_out="${_work}/out"
mkdir -p "${_out}/wheels" "${_out}/lib"
: > "${_out}/wheels/onnxruntime-1.29.0-cp312-linux_x86_64.whl"
for _i in $(seq -w 1 25); do : > "${_out}/lib/libort_${_i}.so"; done

t_case "the headline, the wheel directory and the wheels themselves are reported"
_res="$(_run "GPU build complete" "${_out}")"
t_assert_contains "${_res}" "[INFO] GPU build complete. Artifacts in ${_out}"
t_assert_contains "${_res}" "[INFO] Wheels in ${_out}/wheels"
t_assert_contains "${_res}" "onnxruntime-1.29.0-cp312-linux_x86_64.whl"

t_case "the caller owns its own headline wording"
t_assert_contains "$(_run "GenAI build complete" "${_out}")" "GenAI build complete. Artifacts in"

t_case "the library listing is capped at 20 names"
t_assert_eq "20" "$(_run "Build complete" "${_out}" | grep -c '^libort_')" \
  "an unbounded listing buries the summary in a stage log"

t_case "an output tree with no wheels and no lib dir is NOT a stage failure"
mkdir -p "${_work}/bare"
t_assert_eq "0" "$(t_rc bash "${_work}/run.sh" "Build complete" "${_work}/bare")" \
  "every line here is advisory; under set -euo pipefail an unguarded ls would kill the stage"
t_assert_contains "$(_run "Build complete" "${_work}/bare")" "[INFO] Wheels in"

t_case "no build script keeps a second copy of the summary"
# The four copies had drifted before this owner existed (one used sed -n '1,20p'
# where the others used head -20), which is exactly what one owner prevents.
_copies="$(grep -l -e '-lh .*wheels.*\*\.whl' \
  "${ORT}/30-build-native.sh" "${ORT}/30-build-native-amd.sh" \
  "${ORT}/30-build-native-nvidia.sh" "${ORT}/60-build-genai.sh" 2>/dev/null || true)"
t_assert_eq "" "${_copies}" "these must call report_onnx_build_output, not re-list the wheels"

t_case "all four build scripts call the owner"
for _s in 30-build-native.sh 30-build-native-amd.sh 30-build-native-nvidia.sh 60-build-genai.sh; do
  t_assert_ok grep -q "report_onnx_build_output " "${ORT}/${_s}"
done

t_summary
