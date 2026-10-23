#!/usr/bin/env bash
# Module fixtures retain setup-before-import ordering and strict child-shell status while capturing stdout.
t_fixture_fields() {
  local separator='' value
  for value in "$@"; do
    printf '%s%s' "$separator" "$value"
    separator='|'
  done
}

t_fixture_variables() {
  local name
  local -a values=()
  for name in "$@"; do values+=("${!name}"); done
  t_fixture_fields "${values[@]}"
}

t_run_sourced_module() {
  local module="$1" setup="$2" body="$3"
  bash -c "$(
    printf 'set -euo pipefail\n'
    declare -f t_fixture_fields t_fixture_variables
    printf '%s\n' "$setup"
    printf 'source %q\n' "$module"
    printf '%s\n' "$body"
  )"
}
