#!/usr/bin/env bash
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
[ -n "${_RENOVATE_CLI_LOADED:-}" ] && return 0
_RENOVATE_CLI_LOADED=1

renovate_github_cli() {
  if command -v gh >/dev/null 2>&1; then printf 'gh\n'; return 0; fi
  if command -v gh.exe >/dev/null 2>&1; then printf 'gh.exe\n'; return 0; fi
  return 1
}

assign_renovate_options() {
  while [ "$#" -gt 0 ]; do
    printf -v "$1" '%s' "$2"
    shift 2
  done
}

renovate_driver_option() {
  case "$1:$2" in
    local:--refresh) assign_renovate_options REFRESH 1 ;;
    local:--print-bin) assign_renovate_options MODE print-bin ;;
    fleet:--here) assign_renovate_options HERE 1 ;;
    fleet:--github-owned) assign_renovate_options GITHUB_OWNED 1 ;;
    local:--dry-run) assign_renovate_options DRY_RUN 1 ;;
    fleet:--dry-run) assign_renovate_options DRY_RUN 1 MODE apply ;;
    fleet:--vendored|fleet:--in-place) assign_renovate_options VENDORED_MODE 1 ;;
    *) return 1 ;;
  esac
}

parse_renovate_submodule_path() {
  local value existing
  SELECTOR_SHIFTS=1
  if [[ "$1" == *=* ]]; then
    value="${1#*=}"
  else
    [ "$#" -gt 1 ] || err "--submodule-path needs a value"
    value="$2"
    SELECTOR_SHIFTS=2
  fi
  [ -n "${value}" ] || err "--submodule-path needs a nonempty value"
  for existing in ${SELECTED_SUBMODULES[@]+"${SELECTED_SUBMODULES[@]}"}; do
    [ "${existing}" != "${value}" ] || err "duplicate --submodule-path: ${value}"
  done
  SELECTED_SUBMODULES+=("${value}")
}

parse_renovate_options() {
  local flavor="$1" usage_function="$2" positional_label="$3"
  local -n destination="$4"
  shift 4
  local option variable
  local -A values=([--managers]=MANAGERS)
  if [ "${flavor}" = fleet ]; then
    values[--only]=ONLY
    values[--skip]=SKIP
    values[--timeout]=BUDGET
    values[--checkout-dir]=CHECKOUT_DIR
  fi
  while [ "$#" -gt 0 ]; do
    option="${1%%=*}"
    if [ "${flavor}" = local ] && [ "${option}" = --submodule-path ]; then
      parse_renovate_submodule_path "$@"
      shift "${SELECTOR_SHIFTS}"
      continue
    fi
    variable=""
    if [ -n "${option}" ]; then variable="${values[${option}]:-}"; fi
    if [ -n "${variable}" ]; then
      if [[ "$1" == *=* ]]; then
        printf -v "${variable}" '%s' "${1#*=}"
      else
        shift
        [ "$#" -gt 0 ] || err "${option} needs a value"
        printf -v "${variable}" '%s' "$1"
      fi
    else
      case "$1" in
        --apply) assign_renovate_options MODE apply ;;
        --report) assign_renovate_options MODE report ;;
        -h|--help) "${usage_function}"; exit 0 ;;
        *)
          if renovate_driver_option "${flavor}" "$1"; then
            :
          elif [[ "$1" == -* ]]; then
            err "unknown option: $1"
          else
            [ -z "${destination}" ] || err "more than one ${positional_label} given"
            destination="$1"
          fi
          ;;
      esac
    fi
    shift
  done
}
