# shellcheck shell=bash
# guard-helpers.sh — named replacements for the four raw idioms that litter the
# build scripts. Naming the idiom captures the INTENT (which the raw form hides)
# and fixes the subtle bugs each raw form repeats (see per-function notes).
#
# Backlog "Named guard helpers" (Batch 2, Tier 0 — land FIRST). This file only
# DEFINES the helpers + is unit-tested standalone (test-guard-helpers.sh); wiring
# it into common.sh and migrating the ~426 call sites is the rebuild-gated step
# (a missed bind-mount of a newly-sourced file = a multi-hour build break — the
# source_module-mount-gap lesson), so that migration rides a real rebuild window.
#
# Idempotent: re-sourcing just re-defines the functions (harmless).

# first_match <path> [find-predicate...] — echo the FIRST filesystem entry under
# <path> matching the given find predicates, or "" if none / <path> is absent.
#
# Replaces the ~426 `find … | head -1 || echo ''` / `find … -print -quit` sites.
# Why a helper: `-print -quit` stops at the first hit (no `head` subshell, no
# SIGPIPE race), and the trailing `|| true` keeps a missing <path> (find rc≠0)
# from tripping the caller's `set -e`. The raw idiom got one of these wrong at
# nearly every site.
first_match() {
  local _path="$1"; shift
  find "${_path}" "$@" -print -quit 2>/dev/null || true
}

# probe <cmd...> — run <cmd> with stdout+stderr silenced and return its exit
# status. For use in a condition (`if probe command -v curl; then …`) or with
# `||`. Replaces the `cmd >/dev/null 2>&1` existence-probe idiom; naming it makes
# "this is a boolean check, output is deliberately discarded" explicit instead of
# a comment-free redirection a reader has to decode.
probe() {
  "$@" >/dev/null 2>&1
}

# source_vendor <file> [args...] — source a VENDORED / third-party file with
# `set -u` (nounset) suspended for exactly the duration of the source, then
# restore the caller's nounset state. Returns the sourced file's exit status.
#
# Vendored files routinely reference unset variables (`${OPTIONAL:-}` is not
# universal upstream), which aborts a `set -u` caller mid-source. The 3 call
# sites open this window by hand (`set +u; . x; set -u`) — which is wrong when
# the caller did NOT have `-u` set (it force-enables it) and leaks `+u` if the
# source `return`s early. This restores EXACTLY the prior state.
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

# csv_each <csv> <fn> — call <fn> once per non-empty comma-separated element of
# <csv>, IFS-safely (the split does NOT leak IFS to the caller — the classic
# `IFS=,; for x in $csv` bug that silently re-splits every later word-split in
# the same function). Empty elements are skipped.
csv_each() {
  local _csv="$1" _fn="$2" _item
  local -a _items=()
  IFS=',' read -ra _items <<< "${_csv}"
  for _item in "${_items[@]}"; do
    if [ -n "${_item}" ]; then "${_fn}" "${_item}"; fi
  done
}
