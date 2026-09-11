#!/usr/bin/env bash
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# How every renovate script says things: a fatal, a line, and the "blank line,
# explanation, indented list" shape every refusal in this family prints. ONE
# owner because renovate-fleet.sh grew a verbatim copy of note_listing and the
# duplication gate caught it -- and because a refusal that reads differently in
# two tools is two contracts, not one.
[ -n "${_RENOVATE_SAY_SH_LOADED:-}" ] && return 0
_RENOVATE_SAY_SH_LOADED=1

# Who a fatal message is FROM, taken as the SOURCE COMMAND'S ARGUMENT rather
# than from a global the caller sets first: `. renovate-say.sh renovate-local.sh`
# sets $1 for the duration of this file. A pre-set global reads as dead in the
# caller (SC2034 there), and silencing that warning would be silencing the one
# thing it was right about -- a name nothing visibly consumes. The wrong name in
# an error line is a wrong pointer to the file to go and look at.
SAY_NAME="${1:-renovate}"

err() { printf '%s: %s\n' "${SAY_NAME}" "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

# Args: the explanation lines, then --, then the items. Returns 1 WITHOUT
# printing when there are no items, so callers write `if note_listing ...`
# instead of repeating an emptiness guard around every call.
note_listing() {
  local -a text=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do text+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  [ $# -gt 0 ] || return 1
  note ""
  if [ "${#text[@]}" -gt 0 ]; then printf '%s\n' "${text[@]}"; fi
  printf '  %s\n' "$@"
  return 0
}

# A refusal that ENDS the run: the listing, then the advice, then the one-line
# summary err() exits on -- and nothing at all when there is nothing to refuse.
# The advice is ONE argument (empty for none), so this owns no second copy of
# note_listing's `--` split.
#   refuse_listing <summary> <advice> <explanation...> -- <items...>
refuse_listing() {
  local summary="$1" advice="$2"
  shift 2
  note_listing "$@" || return 0
  if [ -n "${advice}" ]; then
    note ""
    note "${advice}"
  fi
  err "${summary}"
}
