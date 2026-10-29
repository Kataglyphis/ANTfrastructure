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
sccache_s3_fetch() { printf 'fetch:%s\n' "$1" >> "$FIXTURE_ROOT/events"; [ "${FIXTURE_S3_ARCHIVE:-}" != "" ] || return 2; cp "$FIXTURE_S3_ARCHIVE" "$2"; }
sccache_s3_store() { printf 'store:%s\n' "$1" >> "$FIXTURE_ROOT/events"; cp "$2" "$FIXTURE_ROOT/stored.tgz"; }
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
printf 'ccache_dir:%s\n' "${CCACHE_DIR:-unset}" >> "$FIXTURE_ROOT/events"
[ "$FIXTURE_CCACHE_WRITES" != 1 ] || { mkdir -p "$CCACHE_DIR/a"; printf 'o' > "$CCACHE_DIR/a/$pass.o"; }
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
printf '#!/usr/bin/env bash\nexit 0\n' > "${work}/bin/ccache"
chmod +x "${work}/source tree/build.sh" "${work}/bin/cp" "${work}/bin/ccache"
_wasm_case() {
  local failure="$1" flavors="$2" required="$3" copy_failure="$4" artifacts="${5:-present}"
  rm -rf "${work}/build tree" "${work}/output" "${work}/ccache"
  mkdir -p "${work}/ccache"
  : > "${work}/events"
  status=0
  output="$(env PATH="${work}/bin:${PATH}" FIXTURE_ROOT="${work}" FIXTURE_REAL_CP="$(command -v cp)" \
    FIXTURE_FAIL_PASS="$failure" FIXTURE_COPY_FAIL="$copy_failure" FIXTURE_ARTIFACTS="$artifacts" \
    CCACHE_DIR="${work}/ccache" ORT_VERSION=v1.31.0 FIXTURE_S3_ARCHIVE="${FIXTURE_S3_ARCHIVE:-}" FIXTURE_CCACHE_WRITES="${FIXTURE_CCACHE_WRITES:-0}" \
    ORT_SRC_DIR="${work}/source tree" BUILD_DIR="${work}/build tree" WASM_CONFIG=Release WASM_OUTPUT_DIR="${work}/output" \
    CMAKE_POLICY_VERSION_MINIMUM=3.5 ORT_WASM_WEBGPU_FLAVORS="$flavors" ORT_WEB_REQUIRED="$required" \
    bash "${work}/step.sh" 2>&1)" || status=$?
}
t_case "all passes retain ordered flags, flavor distinctions and artifact patterns"
_wasm_case '' true 0 0
t_assert_eq 0 "${status}" "${output}"
t_assert_eq $'build:simd\nbuild:jsep\nbuild:asyncify\nbuild:jspi' "$(grep '^build:' "${work}/events")"
t_assert_eq "wrapper:ccache" "$(grep '^wrapper:' "${work}/events" | sort -u)" \
  "every pass runs emcc with EM_COMPILER_WRAPPER=ccache (the wasm RUN compiled 3857 objects uncached before 2026-10-29; sccache cannot parse emcc's -Xclang -iwithsysroot, CON173)"
t_assert_eq "ccache_dir:${work}/ccache/onnxruntime-web" "$(grep '^ccache_dir:' "${work}/events" | sort -u)" "in its own ccache dir under the mount"
t_assert_contains "${output}" "no ccache/onnxruntime-web-v1.31.0.tar.gz in the S3 level yet; this build fills it" "an empty dir asks the S3 level for the archive"
t_assert_eq "0" "$(grep -c '^store:' "${work}/events")" "and with nothing compiled, nothing goes up"
common="<--build_dir><${work}/build tree><--config><Release><--build_wasm><--parallel><3><--cmake_extra_defines><CMAKE_POLICY_VERSION_MINIMUM=3.5><--skip_tests><--disable_wasm_exception_catching><--disable_rtti><--allow_running_as_root>"
simd='<--enable_wasm_simd><--enable_wasm_threads>'
reduced="<--disable_ml_ops><--disable_generation_ops><--disable_types><string><float4><float8><optional><sparsetensor><--include_ops_by_config><${work}/source tree/onnxruntime/wasm/reduced_types.config><--enable_reduced_operator_type_support>"
t_assert_eq "${common}${simd}" "$(cat "${work}/args.simd")"
t_assert_eq "${common}${simd}<--use_jsep><--use_webnn>" "$(cat "${work}/args.jsep")"
t_assert_eq "${common}${simd}<--use_webgpu><--use_webnn><--target><onnxruntime_webassembly>${reduced}" "$(cat "${work}/args.asyncify")"
t_assert_eq "${common/<--disable_wasm_exception_catching>/}${simd}<--use_webgpu><--use_webnn><--enable_wasm_jspi><--target><onnxruntime_webassembly>${reduced}" "$(cat "${work}/args.jspi")"
t_assert_eq $'ort-wasm-simd-threaded.asyncify.mjs\nort-wasm-simd-threaded.asyncify.wasm\nort-wasm-simd-threaded.jsep.extra file\nort-wasm-simd-threaded.jsep.wasm\nort-wasm-simd-threaded.jspi.mjs\nort-wasm-simd-threaded.jspi.wasm\nort-wasm-simd-threaded.wasm\nort-wasm-simd-threaded.webnn.mjs' "$(find "${work}/output" -type f -printf '%f\n' | LC_ALL=C sort)"
t_case "the wasm ccache dir rides S3 as one archive per ORT version: restored when empty, stored when it grew"
_wasm_case '' false 0 0; FIXTURE_CCACHE_WRITES=1 _wasm_case '' false 0 0
t_assert_eq 0 "${status}" "${output}"
t_assert_eq "store:ccache/onnxruntime-web-v1.31.0.tar.gz" "$(grep '^store:' "${work}/events")" "new objects: the whole dir goes up as one archive"
t_assert_contains "${output}" "ccache-s3| stored ccache/onnxruntime-web-v1.31.0.tar.gz" "and the log says so"
t_assert_eq "./a/simd.o" "$(tar -tzf "${work}/stored.tgz" | grep simd)" "with the objects inside"
cp "${work}/stored.tgz" "${work}/warm.tgz"
FIXTURE_S3_ARCHIVE="${work}/warm.tgz" _wasm_case '' false 0 0
t_assert_eq 0 "${status}" "${output}"
t_assert_contains "${output}" "ccache-s3| restored ccache/onnxruntime-web-v1.31.0.tar.gz" "an empty dir is filled from the archive"
t_assert_eq o "$(cat "${work}/ccache/onnxruntime-web/a/simd.o" 2>/dev/null)" "with the archive's objects"
t_assert_contains "${output}" "nothing new in ${work}/ccache/onnxruntime-web" "and an unchanged dir is not sent again"
unset FIXTURE_CCACHE_WRITES FIXTURE_S3_ARCHIVE

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
