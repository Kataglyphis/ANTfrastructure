#!/usr/bin/env bash
# The explicit SDK and canonical cache launcher keep the diagnostic independent of distro ORT.
set -euo pipefail
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${scripts}/lib/native-cxx-probe.sh"
cli_require_positionals 'NEW_OUTPUT ORT_SDK_PREFIX [CORE_SCRIPTS]' 2 3 "$@"
output="$1" sdk="$2" core="${3:-${scripts}/01-core}"
hub="$(cd "${scripts}/../.." && pwd)"
source "${core}/python-probe.sh"
ci_image_python_require native-tensor-replay docs/gpu-artifact-receipts.md#tensor-diagnosis /usr/local/bin/python3
declare launcher gcc_root
declare -a toolchain
native_cxx_probe_setup "${core}" launcher gcc_root toolchain
mkdir "${output}"
native_cxx_probe_record "${output}" "${gcc_root}"
cp "${sdk}/include/onnxruntime_c_api.h" "${output}/onnxruntime_c_api.h"
_tensor_compile() {
  local name="$1" source_file="$2"
  local object="${output}/$1.o"
  bash "${scripts}/capture-sccache-command.sh" "${output}/${name}-cold" -- \
    "${launcher}" clang++ "${toolchain[@]}" -std=c++17 -O2 -Wall -Wextra -Werror -I"${sdk}/include" -I"${hub}/shared/native" -c "${source_file}" -o "${object}"
  sha256sum "${object}" > "${output}/${name}-cold.sha256"
  bash "${scripts}/capture-sccache-command.sh" "${output}/${name}-warm" -- \
    "${launcher}" clang++ "${toolchain[@]}" -std=c++17 -O2 -Wall -Wextra -Werror -I"${sdk}/include" -I"${hub}/shared/native" -c "${source_file}" -o "${object}"
  sha256sum "${object}" > "${output}/${name}-warm.sha256"
  cmp "${output}/${name}-cold.sha256" "${output}/${name}-warm.sha256"
}
_tensor_compile replay "${hub}/shared/native/tests/ort_tensor_replay.cpp"
_tensor_compile io-test "${hub}/shared/native/tests/ort_tensor_io_test.cpp"
_tensor_compile legacy "${hub}/shared/native/tests/ort_plugin_runtime_probe.cpp"
clang++ "${toolchain[@]}" "${output}/replay.o" -ldl -pthread -o "${output}/ort-tensor-replay"
clang++ "${toolchain[@]}" "${output}/io-test.o" -o "${output}/tensor-io-test"
clang++ "${toolchain[@]}" "${output}/legacy.o" -L"${sdk}/lib" -Wl,-rpath,"${sdk}/lib" -lonnxruntime -ldl -pthread -o "${output}/ort-plugin-runtime-probe"
"${output}/tensor-io-test" "${output}/io-fixture" | tee "${output}/io-test.log"
grep -Eq '^TENSOR-IO PASS: [1-9][0-9]* checks$' "${output}/io-test.log"
"${PREFLIGHT_PYTHON}" -I "${hub}/shared/python/summarize_detector_tensors.py" "${output}/io-fixture/cpu" "${output}/io-fixture/gpu" --output "${output}/io-summary.json"
