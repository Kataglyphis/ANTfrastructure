#!/usr/bin/env bash
# Shared checkout and empty-corpus fixtures keep scope verdicts independent of a linter's file types.
_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

_lint_consumer_plant() {
  if [ "$2" = empty ]; then
    printf 'no lint inputs here\n' > "$1/README.md"
  else
    _plant "$@"
  fi
}

_consumer() { t_consumer_fixture "${_work}" _lint_consumer_plant "$@"; }
