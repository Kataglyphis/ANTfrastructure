#!/usr/bin/env bash
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# How every renovate script reports; one owner, so a refusal reads the same in every tool.
[ -n "${_RENOVATE_SAY_SH_LOADED:-}" ] && return 0
_RENOVATE_SAY_SH_LOADED=1

# The sender comes from the source command's argument; a pre-set global would read as dead (SC2034) in the caller.
SAY_NAME="${1:-renovate}"

err() { printf '%s: %s\n' "${SAY_NAME}" "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

# <explanation...> -- <items...>; returns 1 silently with no items, so callers write `if note_listing`.
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

# <summary> <advice|""> <explanation...> -- <items...>: ends the run unless nothing is listed.
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
