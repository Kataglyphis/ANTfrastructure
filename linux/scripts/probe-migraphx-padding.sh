#!/usr/bin/env bash
# This compiles the real pass and upstream tests against an explicit SDK; it proves no GPU or finished-package acceptance.
set -euo pipefail
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${scripts}/lib/native-cxx-probe.sh"
cli_require_positionals 'NEW_OUTPUT UPSTREAM_SOURCE MIGRAPHX_SDK [CORE_SCRIPTS]' 3 4 "$@"
output="$1" upstream="$2" sdk="$3" core="${4:-${scripts}/01-core}"
declare launcher gcc_root
declare -a toolchain
native_cxx_probe_setup "${core}" launcher gcc_root toolchain
mkdir "${output}"
output="$(cd "${output}" && pwd)"
tree="${output}/source"
mkdir -p "${tree}/src" "${tree}/test/include"
cp "${upstream}/src/eliminate_pad.cpp" "${output}/original.cpp"
cp "${upstream}/src/eliminate_pad.cpp" "${tree}/src/eliminate_pad.cpp"
cp "${upstream}/test/eliminate_pad_test.cpp" "${tree}/test/eliminate_pad_test.cpp"
cp "${upstream}/test/include/"{test,basic_ops}.hpp "${tree}/test/include/"
git -C "${tree}" init --quiet
bash "${core}/apply-patch.sh" "${scripts}/patches/migraphx/001-preserve-zero-pad-maxpool.patch" "${tree}"
native_cxx_probe_record "${output}" "${gcc_root}"
includes=("-I${sdk}/include" "-I${sdk}/../../include" "-I${tree}/test/include")
names=(test original patched)
sources=("${tree}/test/eliminate_pad_test.cpp" "${output}/original.cpp" "${tree}/src/eliminate_pad.cpp")
for index in "${!names[@]}"; do
  name="${names[index]}"
  for phase in cold warm; do
    bash "${scripts}/capture-sccache-command.sh" "${output}/${name}-${phase}" -- \
      "${launcher}" clang++ "${toolchain[@]}" -std=c++17 -O0 -g -fPIC "${includes[@]}" \
      -c "${sources[index]}" -o "${output}/${name}.o"
    sha256sum "${output}/${name}.o" > "${output}/${name}-${phase}.sha256"
  done
  cmp "${output}/${name}-cold.sha256" "${output}/${name}-warm.sha256"
done
for variant in original patched; do
  clang++ "${toolchain[@]}" "${output}/test.o" "${output}/${variant}.o" \
    -L"${sdk}/lib" -Wl,-rpath,"${sdk}/lib" -lmigraphx -pthread -ldl -o "${output}/${variant}-test"
  nm --defined-only -C "${output}/${variant}-test" > "${output}/${variant}-symbols.txt"
  grep -E ' T migraphx::.*::eliminate_pad::apply' "${output}/${variant}-symbols.txt" > /dev/null
done
clang++ "${toolchain[@]}" -shared "${output}/patched.o" -L"${sdk}/lib" \
  -Wl,-rpath,"${sdk}/lib" -lmigraphx -o "${output}/libmigraphx-padding-probe.so"
control_status=0
"${output}/original-test" eliminate_pad_zero_max_negative > "${output}/original-negative.log" 2>&1 || control_status=$?
printf '%s\n' "${control_status}" > "${output}/original-negative.status"
[[ "${control_status}" == 1 ]]
grep -F 'eliminate_pad_zero_max_negative' "${output}/original-negative.log"
grep -F 'results == std::vector<float>' "${output}/original-negative.log"
"${output}/patched-test" > "${output}/patched-tests.log" 2>&1
cat "${output}/patched-tests.log"
sha256sum "${output}/original.cpp" "${tree}/src/eliminate_pad.cpp" "${tree}/test/eliminate_pad_test.cpp" \
  "${output}/"{original,patched}-test "${sdk}/lib/libmigraphx.so" > "${output}/inputs.sha256"
printf 'MIGRAPHX-PADDING PASS: original numerical regression failed; patched upstream suite passed\n'
