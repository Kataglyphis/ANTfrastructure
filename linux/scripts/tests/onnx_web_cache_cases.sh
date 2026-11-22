# shellcheck shell=bash
# The pass and cache suites share allocation and companion staging in their entry driver.
: "${work:?missing shared WASM fixture workspace}"
scripts="${STEP%/*}"
cp "${STEP}" "${work}/web-wasm-cache.sh"
cp "${scripts}/40-build-wasm.sh" "${work}/"
cp "${TESTS_DIR}/../01-core/logging.sh" "${work}/lib/"
cat > "${work}/lib/common.sh" <<'SH'
parse_common_args() { :; }
git() { printf '%040d\n' 1; }
source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
SH
mv "${work}/bin/node" "${work}/bin/cache-fixture-node"
cat > "${work}/bin/node" <<'SH'
#!/usr/bin/env bash
if [ "${!#}" = jspi ]; then
  case "${FIXTURE_MODE}" in
    replay-fail) exit 29 ;;
    replay-rewrite) printf changed >> "${WASM_OUTPUT_DIR}/ort-wasm-simd-threaded.asyncify.wasm" ;;
  esac
fi
exec "$(dirname "$0")/cache-fixture-node" "$@"
SH
chmod +x "${work}/bin/node"
cat > "${work}/build-onnxruntime.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'build\n' >> "$FIXTURE_EVENTS"
case "$FIXTURE_MODE" in fail) exit 17 ;; empty) exit 0 ;; esac
if [ "$ORT_WASM_WEBGPU_FLAVORS" = false ]; then
  printf '\0asm\1\0\0\0' > "$WASM_OUTPUT_DIR/ort-wasm-simd-threaded.wasm"
else
  for flavor in asyncify jspi; do
    if [ "$FIXTURE_MODE:$flavor" = missing:jspi ]; then continue; fi
    cmake="$FIXTURE_ROOT/$flavor"
    python3 "$FIXTURE_EMITTER" --cmake-dir "$cmake" --prefix "$WASM_OUTPUT_DIR" --flavor "$flavor" --config "$WASM_CONFIG"
    python3 "$FIXTURE_PROOF" record --prefix "$WASM_OUTPUT_DIR" --cmake-dir "$cmake" --flavor "$flavor" \
      --source-ref "$ORT_VERSION" --source-revision 0000000000000000000000000000000000000001 --config "$WASM_CONFIG"
  done
fi
SH
_case() {
  case_root="$(t_mktemp -d)"
  mkdir -p "${case_root}/shared" "${case_root}/output"
  : > "${case_root}/events"
}
_run() {
  local required="$1" mode="${2:-good}" flavors="${3:-true}" version="${4:-v1.31.1}" config="${5:-Release}"
  local -a extra=()
  [ "$#" -lt 6 ] || extra+=("$6")
  status=0
  output="$(env LC_ALL=C PATH="${work}/bin:${PATH}" FIXTURE_ROOT="${case_root}" FIXTURE_MODE="${mode}" FIXTURE_EVENTS="${case_root}/events" \
    FIXTURE_EMITTER="${TESTS_DIR}/wasm_proof_fixture.py" FIXTURE_PROOF="${work}/lib/ort-webgpu-wasm-proof.py" \
    ORT_VERSION="${version}" ORT_SRC_DIR="${work}/source" WASM_CONFIG="${config}" \
    WASM_OUTPUT_DIR="${case_root}/output" ORT_WEB_SHARED_CACHE="${case_root}/shared" \
    ORT_WASM_WEBGPU_FLAVORS="${flavors}" ORT_WEB_REQUIRED="${required}" bash "${work}/step.sh" "${extra[@]}" 2>&1)" || status=$?
}
t_case "only a complete checked pool is sealed and reused without a compiler call"
_case; _run 1
t_assert_eq 0 "${status}" "${output}"
t_assert_ok test -s "${case_root}/shared/.complete"
_run 1
t_assert_eq 0 "${status}" "${output}"
t_assert_eq 1 "$(grep -c '^build$' "${case_root}/events")"
t_assert_fails test -e "${case_root}/output/.complete"
t_assert_fails test -e "${case_root}/output/ort-wasm-cache.json"

for required in 0 1; do
  for mode in fail empty missing; do
    t_case "required=${required}, ${mode}: a failure or partial pool cannot leave a complete marker"
    _case; _run "${required}" "${mode}"
    expected=0
    if [ "${required}" = 1 ]; then expected=1; [ "${mode}" != fail ] || expected=17; fi
    t_assert_eq "${expected}" "${status}" "${output}"
    t_assert_fails test -e "${case_root}/shared/.complete"
  done
done

for mismatch in marker bytes version config flavors recipe; do
  t_case "${mismatch}: reject and rebuild the old cache before reusing it"
  _case; _run 1
  t_assert_eq 0 "${status}" "${output}"
  flavors=true version=v1.31.1 config=Release
  case "${mismatch}" in
    marker) : > "${case_root}/shared/.complete" ;;
    bytes) printf changed >> "${case_root}/shared/ort-wasm-simd-threaded.asyncify.wasm" ;;
    version) version=v1.31.2 ;;
    config) config=Debug ;;
    flavors) flavors=false ;;
    recipe) printf '\n# changed build recipe fixture\n' >> "${work}/40-build-wasm.sh" ;;
  esac
  _run 1 good "${flavors}" "${version}" "${config}"
  t_assert_eq 0 "${status}" "${output}"
  t_assert_eq 2 "$(grep -c '^build$' "${case_root}/events")"
  t_assert_ok test -s "${case_root}/shared/.complete"
done

t_case "post-JS verify-only checks artifacts without a cache or a compiler call"
_case; _run 1
t_assert_eq 0 "${status}" "${output}"
mv "${case_root}/shared" "${case_root}/previous shared"
_run 1 good true v1.31.1 Release --verify-only
t_assert_eq 0 "${status}" "${output}"
t_assert_eq 0 "$(grep -c '^WASM-FACTORY-REPLAY:' <<<"${output}")"
t_assert_fails test -e "${case_root}/shared"
t_assert_eq 1 "$(grep -c '^build$' "${case_root}/events")"

t_case "required delivery replays both compiled flavors without a cache or a compiler call"
_run 1 good true v1.31.1 Release --verify-delivery
t_assert_eq 0 "${status}" "${output}"
t_assert_eq $'asyncify\njspi' "$(sed -nE 's/^WASM-FACTORY-REPLAY: .*"flavor": "(asyncify|jspi)".*$/\1/p' <<<"${output}")"
_run 1 replay-fail true v1.31.1 Release --verify-delivery
t_assert_eq 1 "${status}" "${output}"
t_assert_contains "${output}" '"returncode": 29'
_run 1 replay-rewrite true v1.31.1 Release --verify-delivery
t_assert_eq 1 "${status}" "${output}"
t_assert_contains "${output}" 'WASM-PROOF FAIL:'
t_assert_fails test -e "${case_root}/shared"
t_assert_eq 1 "$(grep -c '^build$' "${case_root}/events")"

t_case "required delivery with flavors disabled still verifies the core WASM artifacts"
_case; _run 1 good false
t_assert_eq 0 "${status}" "${output}"
_run 1 good false v1.31.1 Release --verify-delivery
t_assert_eq 0 "${status}" "${output}"
t_assert_eq 0 "$(grep -c '^WASM-FACTORY-REPLAY:' <<<"${output}")"
t_assert_eq 1 "$(grep -c '^build$' "${case_root}/events")"

t_case "an invalid strict-mode value cannot silently select optional policy"
_case; _run 2
t_assert_eq 2 "${status}" "${output}"
t_assert_eq 0 "$(grep -c '^build$' "${case_root}/events" || true)"

t_case "a legacy marker alone never bypasses a failed strict rebuild"
_case
: > "${case_root}/shared/.complete"
printf stale > "${case_root}/shared/ort-wasm-old.wasm"
_run 1 fail
t_assert_eq 17 "${status}" "${output}"
t_assert_fails test -e "${case_root}/shared/.complete"
t_assert_eq 1 "$(grep -c '^build$' "${case_root}/events")"

t_case "a nonregular cache is refused without deleting existing payload"
_case
printf keep > "${case_root}/shared/keep"
mkdir "${case_root}/shared/unexpected directory"
_run 1
t_assert_eq 1 "${status}" "${output}"
t_assert_eq keep "$(cat "${case_root}/shared/keep")"
t_assert_eq 0 "$(grep -c '^build$' "${case_root}/events" || true)"

t_case "the real inner orchestrator's required failure reaches the outer cache driver"
cp "${scripts}/build-onnxruntime.sh" "${work}/build-onnxruntime.sh"
printf '#!/usr/bin/env bash\nexit 19\n' > "${work}/40-build-wasm.sh"
cat >> "${work}/lib/common.sh" <<'SH'
ensure_onnx_gpu_placeholder_output_dir() { :; }
is_amd64_arch() { return 0; }
err() { _log_emit ERROR 2 "$@"; exit 87; }
SH
_case; _run 1
t_assert_eq 87 "${status}" "${output}"
t_assert_contains "${output}" 'failed and ORT_WEB_REQUIRED=1'
t_assert_fails test -e "${case_root}/shared/.complete"
t_case "the Dockerfile executes the strict wrapper and checks delivery after JS staging"
dockerfile="$(cat "${TESTS_DIR}/../../Dockerfile.media")"
t_assert_contains "${dockerfile}" 'ORT_WEB_REQUIRED="${ORT_WEB_REQUIRED}" ORT_WASM_WEBGPU_FLAVORS="${ORT_WASM_WEBGPU_FLAVORS}"'
t_assert_contains "${dockerfile}" 'bash /opt/scripts/03-media/build/onnxruntime/build/web-wasm-cache.sh;'
t_assert_contains "${dockerfile}" 'ORT_WEB_REQUIRED="${ORT_WEB_REQUIRED}" bash /opt/scripts/03-media/build/onnxruntime/build/build-onnxruntime.sh --step js;'
delivery_run="$(sed -n '/^LABEL kataglyphis.step=onnxruntime-pkgconfig$/,/^LABEL kataglyphis.step=onnxruntime-pkgconfig-verify$/p' <<<"${dockerfile}")"
t_assert_contains "${delivery_run}" 'if [ "${ORT_WEB_REQUIRED}" = 1 ]; then'
t_assert_contains "${delivery_run#*--step js;}" 'bash /opt/scripts/03-media/build/onnxruntime/build/web-wasm-cache.sh --verify-delivery;'

t_summary
