#!/usr/bin/env bash
# YA: upstream file(DOWNLOAD)s ~1.5 GB of QAIRT, unhashed and unchecked, whenever
# QAIRT_HEADERS_DIR is empty. The guard patches that branch out. It has to be
# reachable from BOTH lanes -- the android lane clones its own tree, so the cross
# lane's patched copy cannot help it. docs/qnn-linux.md
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LITERT_DIR="${TESTS_DIR}/../03-media/build/litert"
GUARD="${LITERT_DIR}/android/litert-qairt-guard.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# A LiteRT tree whose vendors file carries upstream's anchor.
_mk_tree() {
  local root="${_work}/$1"
  mkdir -p "${root}/litert/vendors"
  cat > "${root}/litert/vendors/CMakeLists.txt" <<'CM'
set(QAIRT_HEADERS_DIR "" CACHE PATH "root containing Qnn*.h")
if(NOT QAIRT_HEADERS_DIR)
  file(DOWNLOAD "https://softwarecenter.qualcomm.com/.../v2.47.0.260601.zip" "${_qnn_archive}")
endif()
CM
  printf '%s' "${root}"
}

_vendors() { printf '%s' "$1/litert/vendors/CMakeLists.txt"; }

_run_guard() { ( source "${GUARD}"; _litert_disable_qairt_header_download "$1" ) 2>"${_work}/err"; }

t_case "the guard file exists where Dockerfile.android can COPY it"
t_assert_ok test -f "${GUARD}"

t_case "it lives under android/ — Dockerfile.android COPYs only that dir"
t_assert_eq "android" "$(basename "$(dirname "${GUARD}")")"

t_case "patching neutralises upstream's download branch"
_t1="$(_mk_tree ok)"
_run_guard "${_t1}"
t_assert_contains "$(cat "$(_vendors "${_t1}")")" "if(FALSE)"

t_case "the marker comment is written, so a second run can detect it"
t_assert_contains "$(cat "$(_vendors "${_t1}")")" "KATAGLYPHIS-NO-QAIRT-DOWNLOAD"

t_case "the live anchor is gone, so upstream cannot take the branch"
t_assert_fails grep -q -F -e 'if(NOT QAIRT_HEADERS_DIR)' "$(_vendors "${_t1}")"

t_case "idempotent: a second call does not patch twice"
_before="$(cat "$(_vendors "${_t1}")")"
_run_guard "${_t1}"
t_assert_eq "${_before}" "$(cat "$(_vendors "${_t1}")")"

t_case "a missing vendors file warns and returns 0, it does not kill the build"
mkdir -p "${_work}/empty"
_run_guard "${_work}/empty"
t_assert_eq "0" "$?"

t_case "and it says which path it looked for"
t_assert_contains "$(cat "${_work}/err")" "not found"

t_case "a MOVED anchor fails loudly instead of silently leaving the download live"
_t2="$(_mk_tree moved)"
printf 'if(NOT QAIRT_HEADERS_DIR_RENAMED)\n' > "$(_vendors "${_t2}")"
_run_guard "${_t2}"
t_assert_contains "$(cat "${_work}/err")" "upstream changed"

t_case "it logs without info()/warn() — the android stages never source logging.sh"
t_assert_fails grep -qE -e '^[[:space:]]*(info|warn|err)[[:space:]]' "${GUARD}"

t_case "the CROSS lane reaches the guard"
t_assert_contains "$(cat "${LITERT_DIR}/build-litert.sh")" "android/litert-qairt-guard.sh"

t_case "the ANDROID lane reaches it too — the defect this test exists for"
t_assert_contains "$(cat "${LITERT_DIR}/android/build-android.sh")" "litert-qairt-guard.sh"

t_case "and the android lane actually CALLS it, not just sources it"
t_assert_contains "$(cat "${LITERT_DIR}/android/build-android.sh")" "_litert_disable_qairt_header_download"

t_case "neither lane still defines its own copy of the function"
t_assert_eq "0" "$(grep -c -e '^_litert_disable_qairt_header_download()' "${LITERT_DIR}/build-litert.sh")"

t_summary
