#!/usr/bin/env bash
# Consumer-API contract suites run one library function in a fresh bash against stub tools that log their argv.
source "${BASH_SOURCE[0]%/*}/test-harness.sh"

# lc_init <dir>: stubs go to <dir>/bin, their argv to <dir>/argv.log, a call's mktemp output to <dir>/tmp.
lc_init() {
  _LC_ROOT="$1"
  mkdir -p "${_LC_ROOT}/bin" "${_LC_ROOT}/tmp" "${_LC_ROOT}/rc" "${_LC_ROOT}/bare" || return 1
  : > "${_LC_ROOT}/argv.log"
  local tool
  # A PATH without host tools, so a probe for a missing one sees it missing.
  for tool in bash cat dirname mkdir; do ln -sf "$(command -v "${tool}")" "${_LC_ROOT}/bare/${tool}" || return 1; done
}

# lc_status <name>: shell text that expands to the status lc_fail set for <name>, else 0.
lc_status() { printf '"$(cat %q 2>/dev/null || printf 0)"' "${_LC_ROOT}/rc/$1"; }
# lc_fail <name> <status> / lc_pass <name>: what the next stub or fixture named <name> exits with.
lc_fail() { printf '%s\n' "$2" > "${_LC_ROOT}/rc/$1"; }
lc_pass() { rm -f "${_LC_ROOT}/rc/$1"; }

# lc_stub <tool> [body]: a tool first on PATH that logs "<tool> <args>" and then runs body (default: exit with its lc_status).
lc_stub() {
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %q "$*" >> %q\n%s\n' \
    "$1" "${_LC_ROOT}/argv.log" "${2:-exit $(lc_status "$1")}" > "${_LC_ROOT}/bin/$1" || return 1
  chmod +x "${_LC_ROOT}/bin/$1"
}

# lc_call <out-var> <rc-var> <library> <body>: body runs after `source <library>`, stdout and stderr captured together.
lc_call() {
  local -n _lc_out="$1" _lc_rc="$2"
  _lc_rc=0
  _lc_out="$(cd "${_LC_ROOT}" && TMPDIR="${_LC_ROOT}/tmp" PATH="${_LC_ROOT}/bin:${LC_PATH:-${PATH}}" bash -c \
    "set -uo pipefail; source $(printf '%q' "$3"); $4" 2>&1 < /dev/null)" || _lc_rc=$?
  return 0
}

# lc_call_bare: lc_call with only the stubs and a shell on PATH.
lc_call_bare() { LC_PATH="${_LC_ROOT}/bare" lc_call "$@"; }

# lc_expect <status> <text> <library> <body>: the call ends with <status> and prints <text>.
lc_expect() {
  local _lce_out _lce_rc
  lc_call _lce_out _lce_rc "$3" "$4"
  t_assert_eq "$1" "${_lce_rc}" "status of: $4"
  t_assert_contains "${_lce_out}" "$2"
}

# lc_argv: every stub call since the last lc_reset, one per line.
lc_argv() { cat "${_LC_ROOT}/argv.log"; }
lc_reset() { : > "${_LC_ROOT}/argv.log"; }
