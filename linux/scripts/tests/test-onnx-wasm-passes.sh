#!/usr/bin/env bash
# Stubbed builders and local artifacts cover WASM pass/copy policy, not compilation, npm or registry access.
set -u
# shellcheck source=linux/scripts/tests/script-stage-fixture.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/script-stage-fixture.sh"
declare work STEP
script_stage_fixture_init work STEP 40-build-wasm.sh "${1:-}" lib bin 'source tree' || exit 1
cp "${STEP}" "${work}/step.sh"
cp "${TESTS_DIR}/../01-core/logging.sh" "${work}/lib/logging.sh"
cat > "${work}/lib/common.sh" <<'STUB'
parse_common_args() { :; }
detect_jobs() { JOBS=3; }
compiler_cache_launcher() { printf /launchers/sccache-launcher.sh; }
source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
err() { _log_emit ERROR 2 "$@"; exit 87; }
STUB
cat > "${work}/source tree/build.sh" <<'STUB'
#!/usr/bin/env bash
pass=simd
for arg in "$@"; do
  case "$arg" in --use_jsep) pass=jsep ;; --use_webgpu) pass=asyncify ;; --enable_wasm_jspi) pass=jspi ;; esac
done
printf 'build:%s\n' "$pass" >> "$FIXTURE_ROOT/events"
printf 'wrapper:%s\n' "${EM_COMPILER_WRAPPER:-unset}" >> "$FIXTURE_ROOT/events"
printf '<%s>' "$@" > "$FIXTURE_ROOT/args.$pass"
[ "$FIXTURE_FAIL_PASS" != "$pass" ] || exit 9
mkdir -p "$BUILD_DIR/$WASM_CONFIG/nested space"
[ "$FIXTURE_ARTIFACTS" != none ] || exit 0
stem=ort-wasm-simd-threaded
case "$pass" in
  simd) touch "$BUILD_DIR/$WASM_CONFIG/$stem.wasm" ;;
  jsep) touch "$BUILD_DIR/$WASM_CONFIG/$stem.jsep.wasm" "$BUILD_DIR/$WASM_CONFIG/$stem.webnn.mjs" "$BUILD_DIR/$WASM_CONFIG/nested space/$stem.jsep.extra file" ;;
  *) touch "$BUILD_DIR/$WASM_CONFIG/$stem.$pass.wasm" "$BUILD_DIR/$WASM_CONFIG/$stem.$pass.mjs" ;;
esac
touch "$BUILD_DIR/$WASM_CONFIG/unrelated.wasm"
mkdir -p "$BUILD_DIR/$WASM_CONFIG/$stem.directory.wasm"
STUB
cat > "${work}/bin/cp" <<'STUB'
#!/usr/bin/env bash
printf 'copy\n' >> "$FIXTURE_ROOT/events"
[ "$FIXTURE_COPY_FAIL" != 1 ] || exit 7
exec "$FIXTURE_REAL_CP" "$@"
STUB
chmod +x "${work}/source tree/build.sh" "${work}/bin/cp"
_wasm_case() {
  local failure="$1" flavors="$2" required="$3" copy_failure="$4" artifacts="${5:-present}"
  rm -rf "${work}/build tree" "${work}/output"
  : > "${work}/events"
  status=0
  output="$(env PATH="${work}/bin:${PATH}" FIXTURE_ROOT="${work}" FIXTURE_REAL_CP="$(command -v cp)" \
    FIXTURE_FAIL_PASS="$failure" FIXTURE_COPY_FAIL="$copy_failure" FIXTURE_ARTIFACTS="$artifacts" \
    ORT_SRC_DIR="${work}/source tree" BUILD_DIR="${work}/build tree" WASM_CONFIG=Release WASM_OUTPUT_DIR="${work}/output" \
    CMAKE_POLICY_VERSION_MINIMUM=3.5 ORT_WASM_WEBGPU_FLAVORS="$flavors" ORT_WEB_REQUIRED="$required" \
    bash "${work}/step.sh" 2>&1)" || status=$?
}
t_case "all passes retain ordered flags, flavor distinctions and artifact patterns"
_wasm_case '' true 0 0
t_assert_eq 0 "${status}" "${output}"
t_assert_eq $'build:simd\nbuild:jsep\nbuild:asyncify\nbuild:jspi' "$(grep '^build:' "${work}/events")"
t_assert_eq "wrapper:/launchers/sccache-launcher.sh" "$(grep '^wrapper:' "${work}/events" | sort -u)" \
  "every pass runs emcc with EM_COMPILER_WRAPPER = the compiler cache launcher (the wasm RUN compiled 3857 objects uncached before 2026-10-29, CON173)"
common="<--build_dir><${work}/build tree><--config><Release><--build_wasm><--parallel><3><--cmake_extra_defines><CMAKE_POLICY_VERSION_MINIMUM=3.5><--skip_tests><--disable_wasm_exception_catching><--disable_rtti><--allow_running_as_root>"
simd='<--enable_wasm_simd><--enable_wasm_threads>'
reduced="<--disable_ml_ops><--disable_generation_ops><--disable_types><string><float4><float8><optional><sparsetensor><--include_ops_by_config><${work}/source tree/onnxruntime/wasm/reduced_types.config><--enable_reduced_operator_type_support>"
t_assert_eq "${common}${simd}" "$(cat "${work}/args.simd")"
t_assert_eq "${common}${simd}<--use_jsep><--use_webnn>" "$(cat "${work}/args.jsep")"
t_assert_eq "${common}${simd}<--use_webgpu><--use_webnn><--target><onnxruntime_webassembly>${reduced}" "$(cat "${work}/args.asyncify")"
t_assert_eq "${common/<--disable_wasm_exception_catching>/}${simd}<--use_webgpu><--use_webnn><--enable_wasm_jspi><--target><onnxruntime_webassembly>${reduced}" "$(cat "${work}/args.jspi")"
t_assert_eq $'ort-wasm-simd-threaded.asyncify.mjs\nort-wasm-simd-threaded.asyncify.wasm\nort-wasm-simd-threaded.jsep.extra file\nort-wasm-simd-threaded.jsep.wasm\nort-wasm-simd-threaded.jspi.mjs\nort-wasm-simd-threaded.jspi.wasm\nort-wasm-simd-threaded.wasm\nort-wasm-simd-threaded.webnn.mjs' "$(find "${work}/output" -type f -printf '%f\n' | LC_ALL=C sort)"
for pass in simd jsep; do
  t_case "${pass} mandatory build failure stops later passes"
  _wasm_case "$pass" true 0 0
  t_assert_eq 9 "${status}"
  expected=build:simd
  [ "$pass" != jsep ] || expected+=$'\nbuild:jsep'
  t_assert_eq "$expected" "$(grep '^build:' "${work}/events")"
done
t_case "an optional flavor failure retains mandatory artifacts and attempts later flavors"
_wasm_case asyncify true 0 0
t_assert_eq 0 "${status}"
t_assert_contains "${output}" 'WITHOUT this flavor'
t_assert_ok test -f "${work}/output/ort-wasm-simd-threaded.wasm"
t_assert_ok test -f "${work}/output/ort-wasm-simd-threaded.jspi.wasm"
t_assert_fails test -f "${work}/output/ort-wasm-simd-threaded.asyncify.wasm"
t_case "ORT_WEB_REQUIRED turns the same flavor failure fatal"
_wasm_case asyncify true 1 0
t_assert_eq 87 "${status}"
t_assert_contains "${output}" 'failed and ORT_WEB_REQUIRED=1'
t_assert_rc 1 grep -q '^build:jspi$' "${work}/events"
t_case "disabled WebGPU flavors run only mandatory passes"
_wasm_case '' false 0 0
t_assert_eq 0 "${status}"
t_assert_eq $'build:simd\nbuild:jsep' "$(grep '^build:' "${work}/events")"
for policy in copy-fails no-artifacts; do
  t_case "${policy}: collection remains best-effort for every pass"
  copy_failure=0; artifacts=present
  [ "$policy" != copy-fails ] || copy_failure=1
  [ "$policy" != no-artifacts ] || artifacts=none
  _wasm_case '' true 0 "$copy_failure" "$artifacts"
  t_assert_eq 0 "${status}"
  t_assert_eq 4 "$(grep -c '^build:' "${work}/events")"
  t_assert_eq '' "$(find "${work}/output" -type f -print)"
done
t_summary
