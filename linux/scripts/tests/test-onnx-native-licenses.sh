#!/usr/bin/env bash
# ORT native outputs retain the checked-out project texts; this does not audit other bundled components or run an ORT build.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
ORT="${TESTS_DIR}/../03-media/build/onnxruntime/build"
COMMON="${1:-${ORT}/lib/common.sh}"
for fn in stage_onnx_native_licenses finalize_onnx_native_output; do
  eval "$(t_fn_src "$COMMON" "$fn")"
done
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
source_dir="${work}/checked out source"
mkdir -p "$source_dir"
printf 'project license: exact checked-out bytes\n' > "${source_dir}/LICENSE"
printf 'upstream third-party notices: exact checked-out bytes\n' > "${source_dir}/ThirdPartyNotices.txt"
calls="${work}/calls"
verify_onnxruntime_core_header() { printf 'header <%s> <%s> <%s>\n' "$@" >> "$calls"; }
copy_onnx_libraries_to_output() { printf 'library <%s> <%s> <%s>\n' "$@" >> "$calls"; }
ensure_onnxruntime_symlink() { printf 'symlink <%s>\n' "$1" >> "$calls"; }
symlink_output_libraries_into_usr_local() { printf 'publish <%s>\n' "$1" >> "$calls"; }

for variant in cpu amd nvidia; do
  t_case "$variant preserves both source files byte-for-byte"
  output="${work}/${variant} output"
  : > "$calls"
  t_assert_eq 0 "$(t_rc finalize_onnx_native_output "${work}/build" Release "$output" "$source_dir")"
  t_assert_ok cmp "${source_dir}/LICENSE" "${output}/licenses/LICENSE"
  t_assert_ok cmp "${source_dir}/ThirdPartyNotices.txt" "${output}/licenses/ThirdPartyNotices.txt"
  t_assert_contains "$(cat "$calls")" "symlink <${output}>"
  t_assert_contains "$(cat "$calls")" "publish <${output}>"
done

t_case 'rebuilding replaces stale notices with the current checkout text'
printf stale > "${work}/cpu output/licenses/LICENSE"
printf stale > "${work}/cpu output/licenses/ThirdPartyNotices.txt"
t_assert_eq 0 "$(t_rc stage_onnx_native_licenses "$source_dir" "${work}/cpu output")"
t_assert_ok cmp "${source_dir}/LICENSE" "${work}/cpu output/licenses/LICENSE"
t_assert_ok cmp "${source_dir}/ThirdPartyNotices.txt" "${work}/cpu output/licenses/ThirdPartyNotices.txt"

t_case 'the actual CPU and both GPU entries send their own output and checked-out source to the shared finalizer'
t_assert_contains "$(cat "${ORT}/30-build-native.sh")" 'finalize_onnx_native_output "${NATIVE_CPU_BUILD_DIR}" "${NATIVE_CPU_CONFIG}" "${NATIVE_CPU_OUTPUT_DIR}" "${ORT_SRC_DIR}"'
for script in 30-build-native-amd.sh 30-build-native-nvidia.sh; do
  t_assert_contains "$(cat "${ORT}/${script}")" 'finalize_onnx_native_output "${NATIVE_GPU_BUILD_DIR}" "${NATIVE_CPU_CONFIG}" "${NATIVE_GPU_OUTPUT_DIR}" "${ORT_SRC_DIR}"'
done

for file in LICENSE ThirdPartyNotices.txt; do
  t_case "a missing or empty ${file} fails before publishing symlinks"
  mv "${source_dir}/${file}" "${work}/saved"
  : > "$calls"
  t_assert_eq 1 "$(t_rc finalize_onnx_native_output "${work}/build" Release "${work}/bad" "$source_dir")"
  t_assert_rc 1 grep -q '^publish ' "$calls"
  : > "${source_dir}/${file}"
  : > "$calls"
  t_assert_eq 1 "$(t_rc finalize_onnx_native_output "${work}/build" Release "${work}/bad" "$source_dir")"
  t_assert_rc 1 grep -q '^publish ' "$calls"
  rm "${source_dir}/${file}"
  mv "${work}/saved" "${source_dir}/${file}"
done

t_case 'symlinked source and destination text cannot be substituted'
t_needs 'real symlinks' t_posix_symlinks
mv "${source_dir}/LICENSE" "${work}/saved"
ln -s "${work}/saved" "${source_dir}/LICENSE"
t_assert_eq 1 "$(t_rc stage_onnx_native_licenses "$source_dir" "${work}/bad")"
rm "${source_dir}/LICENSE"
mv "${work}/saved" "${source_dir}/LICENSE"
mkdir -p "${work}/linked-output/licenses"
ln -s "${work}/saved" "${work}/linked-output/licenses/ThirdPartyNotices.txt"
t_assert_eq 1 "$(t_rc stage_onnx_native_licenses "$source_dir" "${work}/linked-output")"
t_assert_fails test -e "${work}/linked-output/licenses/LICENSE"
mkdir -p "${work}/linked-directory" "${work}/actual-directory"
ln -s "${work}/actual-directory" "${work}/linked-directory/licenses"
t_assert_eq 1 "$(t_rc stage_onnx_native_licenses "$source_dir" "${work}/linked-directory")"
t_assert_fails test -e "${work}/actual-directory/LICENSE"

t_case 'a copy failure keeps its status and prevents library publication'
: > "$calls"
install() { return 47; }
t_assert_eq 47 "$(t_rc finalize_onnx_native_output "${work}/build" Release "${work}/copy-failure" "$source_dir")"
t_assert_rc 1 grep -q '^publish ' "$calls"
unset -f install

t_summary
