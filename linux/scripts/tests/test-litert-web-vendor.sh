#!/usr/bin/env bash
# Stubbed package fixtures cover vendoring order and failure policy, not registry downloads or tar extraction.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPT="${1:-${TESTS_DIR}/../03-media/build/litert/install-litert-web.sh}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
sed '/^main "\$@"$/d' "${SCRIPT}" > "${work}/vendor.sh"

_vendor_case() {
  local runtime="$1" mode="$2"
  rm -rf "${work}/js" "${work}/lm"
  mkdir -p "${work}/js" "${work}/lm"
  touch "${work}/js/stale" "${work}/lm/stale"
  : > "${work}/calls"
  bash -c '
    LITERTJS_VERSION=fixture-js MEDIAPIPE_GENAI_VERSION=fixture-genai
    LITERT_WEB_OUTPUT_DIR="$2/js" LITERT_LM_WEB_OUTPUT_DIR="$2/lm"
    source "$1/vendor.sh"
    mode="$4"; calls="$2/calls"
    _fetch_npm_package() {
      printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$calls"
      case "$mode:$1" in
        required-fail:@litertjs/core|required-fail:@mediapipe/tasks-genai) return 7 ;;
        optional-fail:@litertjs/tfjs-interop|optional-fail:@litertjs/wasm-utils) return 8 ;;
      esac
      mkdir -p "$3"
      if [ "$mode" != no-wasm ]; then
        case "$1" in
          @litertjs/core|@mediapipe/tasks-genai) mkdir -p "$3/wasm"; touch "$3/wasm/runtime.wasm" ;;
        esac
      fi
    }
    if [ "$3" = no-curl ]; then
      command() { if [ "${2:-}" = curl ]; then return 1; fi; builtin command "$@"; }
      main
    elif [ "$3" = main ]; then
      main
    else
      rc=0; "$3" || rc=$?
      printf "STATUS=%s\n" "$rc"
    fi' _ "${work}" "${work}" "${runtime}" "${mode}" 2>&1
}

t_case "LiteRT.js clears stale bytes and fetches core, interop and wasm utilities in order"
output="$(_vendor_case vendor_litertjs ok)"
t_assert_contains "${output}" 'Vendoring LiteRT.js web runtime (@litertjs/core fixture-js)'
t_assert_contains "${output}" STATUS=0
t_assert_eq "@litertjs/core|fixture-js|${work}/js/core
@litertjs/tfjs-interop|fixture-js|${work}/js/tfjs-interop
@litertjs/wasm-utils|fixture-js|${work}/js/wasm-utils" "$(cat "${work}/calls")"
t_assert_fails test -e "${work}/js/stale"
t_assert_eq core/wasm "$(readlink "${work}/js/wasm")"

t_case "LiteRT-LM uses its own version and output root without a core subdirectory"
output="$(_vendor_case vendor_litert_lm_web ok)"
t_assert_contains "${output}" 'Vendoring LiteRT-LM web runtime (@mediapipe/tasks-genai fixture-genai)'
t_assert_contains "${output}" STATUS=0
t_assert_eq "@mediapipe/tasks-genai|fixture-genai|${work}/lm" "$(cat "${work}/calls")"
t_assert_fails test -e "${work}/lm/stale"

t_case "a missing optional companion warns but leaves the usable core successful"
output="$(_vendor_case vendor_litertjs optional-fail)"
t_assert_contains "${output}" 'tfjs-interop fixture-js unavailable; continuing (core is sufficient to serve)'
t_assert_contains "${output}" 'wasm-utils fixture-js unavailable; continuing'
t_assert_contains "${output}" STATUS=0
t_assert_eq 3 "$(wc -l < "${work}/calls")"

for runtime in vendor_litertjs vendor_litert_lm_web; do
  t_case "${runtime}: a required package failure stops the caller before optional packages"
  output="$(_vendor_case "${runtime}" required-fail)"
  t_assert_contains "${output}" STATUS=1
  t_assert_eq 1 "$(wc -l < "${work}/calls")"
  t_case "${runtime}: a package without wasm fails with its own diagnostic"
  output="$(_vendor_case "${runtime}" no-wasm)"
  t_assert_contains "${output}" STATUS=1
  if [ "${runtime}" = vendor_litertjs ]; then
    t_assert_contains "${output}" "no .wasm found in ${work}/js"
  else
    t_assert_contains "${output}" "no .wasm found in ${work}/lm (genai wasm expected)"
  fi
done

t_case "main attempts both runtimes and keeps their failures advisory"
output="$(_vendor_case main required-fail)"; status=$?
t_assert_eq 0 "${status}"
t_assert_contains "${output}" 'LiteRT.js web vendoring failed (non-fatal)'
t_assert_contains "${output}" 'LiteRT-LM web (mediapipe-genai) vendoring failed (non-fatal)'
t_assert_eq 2 "$(wc -l < "${work}/calls")"
t_case "missing curl retains both COPY directories and skips all packages"
output="$(_vendor_case no-curl ok)"; status=$?
t_assert_eq 0 "${status}"
t_assert_contains "${output}" 'curl unavailable; cannot vendor LiteRT web assets'
t_assert_ok test -d "${work}/js"
t_assert_ok test -d "${work}/lm"
t_assert_eq '' "$(cat "${work}/calls")"

t_summary
