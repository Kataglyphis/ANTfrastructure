#!/usr/bin/env bash
# _litert_qairt_include_dir must name the dir HOLDING Qnn*.h, not the include
# root. Upstream only probes <dir> vs <dir>/QNN when it downloads the SDK
# itself; a pre-set QAIRT_HEADERS_DIR is consumed verbatim, so the include root
# fails ~7 min into the build. docs/qnn-linux.md#qairt_headers_dir
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../03-media/build/litert/build-litert.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# build-litert.sh is a top-level script; extract just the helper.
_lib="${_work}/lib.sh"
awk '/^_litert_qairt_include_dir\(\) \{/ {p=1} p {print} p && /^\}/ {exit}' "${SUBJECT}" > "${_lib}"

t_case "the helper was found in the subject"
t_assert_contains "$(cat "${_lib}")" "_litert_qairt_include_dir()"

# Builds a QAIRT tree under $1 with the headers at the relative path $2.
_mk_sdk() {
  local home="${_work}/$1" rel="$2"
  mkdir -p "${home}/${rel}"
  : > "${home}/${rel}/QnnLog.h"
  : > "${home}/${rel}/QnnCommon.h"
  printf '%s' "${home}"
}

# Runs the helper with LITERT_QNN_HOME=$1; stdout is the result, stderr goes to
# ${_work}/err. err() is stubbed to the real contract: message to fd 2, exit 1.
_run_helper() {
  ( set +e
    err() { printf 'ERR: %s\n' "$*" >&2; exit 1; }
    # shellcheck disable=SC1090
    source "${_lib}"
    LITERT_QNN_HOME="$1" _litert_qairt_include_dir ) 2>"${_work}/err"
}

t_case "a real QAIRT layout resolves to include/QNN, the dir holding Qnn*.h"
_home="$(_mk_sdk sdk-ok include/QNN)"
_OUT="$(_run_helper "${_home}")"
t_assert_eq "${_home}/include/QNN" "${_OUT}"

t_case "it does NOT hand back the include root — the defect that failed the build"
t_assert_fails test "${_OUT}" = "${_home}/include"

t_case "QnnLog.h really exists at the returned path"
t_assert_ok test -f "${_OUT}/QnnLog.h"

t_case "a layout with headers only under include/ fails loudly, not silently"
_bad="$(_mk_sdk sdk-flat include)"
_run_helper "${_bad}" >/dev/null
t_assert_contains "$(cat "${_work}/err")" "QnnLog.h missing"

t_case "the failure states the contract, not just the path"
t_assert_contains "$(cat "${_work}/err")" "dir holding Qnn"

t_case "an empty SDK tree yields no path (no silent bare string)"
mkdir -p "${_work}/sdk-empty"
t_assert_eq "" "$(_run_helper "${_work}/sdk-empty")"

t_case "definition plus both call sites all go through the helper"
_src="$(cat "${SUBJECT}")"
t_assert_eq "3" "$(printf '%s\n' "${_src}" | grep -c -e '_litert_qairt_include_dir')"

t_case "no call site passes a bare include root any more"
t_assert_eq "0" "$(printf '%s\n' "${_src}" | grep -c -F -e 'QAIRT_HEADERS_DIR=${LITERT_QNN_HOME}/include')"

t_summary
