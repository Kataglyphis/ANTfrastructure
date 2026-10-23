#!/usr/bin/env bash
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
[ -n "${_RENOVATE_GIT_LOADED:-}" ] && return 0
_RENOVATE_GIT_LOADED=1

resolve_renovate_root() {
  local -n root_path="$1"
  root_path="${root_path:-$PWD}"
  [ -d "${root_path}" ] || err "not a directory: ${root_path}"
  root_path="$(cd "${root_path}" && pwd)"
  git -C "${root_path}" rev-parse --git-dir >/dev/null 2>&1 || err "not a git repo: ${root_path}"
}

for_each_renovate_submodule() {
  local directory="$1" callback="$2" entry key name path
  local -a names=()
  local -A paths=()
  shift 2
  [ -f "${directory}/.gitmodules" ] || return 0
  while IFS= read -r -d '' entry; do
    key="${entry%%$'\n'*}"
    name="${key#submodule.}"
    name="${name%.path}"
    path="${entry#*$'\n'}"
    names+=("${name}")
    paths["${name}"]="${path}"
  done < <(git -C "${directory}" config -z -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null)
  for name in "${names[@]}"; do
    path="${paths[${name}]}"
    [ -n "${path}" ] || continue
    "${callback}" "${directory}" "${name}" "${path}" "$@"
  done
}
