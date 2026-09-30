# shellcheck shell=bash
# Named helpers for shell idioms whose hand-written forms keep getting subtly wrong.

# first_match <path> [find-predicate...]: first hit or ""; -print -quit avoids SIGPIPE, || true a set -e abort.
first_match() {
  local _path="$1"; shift
  find "${_path}" "$@" -print -quit 2>/dev/null || true
}

# probe <cmd...>: a boolean check whose output is deliberately discarded.
probe() {
  "$@" >/dev/null 2>&1
}

# source_vendor <file> [args...]: sources with nounset off, then restores exactly the caller's prior -u state.
source_vendor() {
  local _f="$1"; shift
  local _restore_u=0
  case "$-" in *u*) _restore_u=1 ;; esac
  set +u
  # shellcheck disable=SC1090
  . "${_f}" "$@"
  local _rc=$?
  [ "${_restore_u}" -eq 1 ] && set -u
  return "${_rc}"
}

# csv_each <csv> <fn>: calls <fn> per non-empty element without leaking IFS=, into the caller.
csv_each() {
  local _csv="$1" _fn="$2" _item
  local -a _items=()
  IFS=',' read -ra _items <<< "${_csv}"
  for _item in "${_items[@]}"; do
    if [ -n "${_item}" ]; then "${_fn}" "${_item}"; fi
  done
}
