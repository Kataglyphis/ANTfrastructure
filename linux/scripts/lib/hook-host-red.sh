#!/usr/bin/env bash
# Sourced by the pre-commit and pre-push hooks: a mutation test that is red on this host before any mutation proves nothing here.
# shellcheck source=log-bootstrap.sh
source "${BASH_SOURCE[0]%/*}/log-bootstrap.sh" || return

# <log> <hook>: the ids red before any mutation (bash 5.2 here, 5.3 in the image) when they alone failed, so the image decides.
host_red_ids() {
  local vac failed
  vac="$(sed -n 's/^\(\[[0-9]*\/[0-9]*\] \)\{0,1\}FAIL: \([^ ]*\) -- baseline test already fails unmutated.*/\2/p' "$1" | tr -d '\r' | sort -u | tr '\n' ' ')"
  failed="$(sed -n 's/^FAILED: [0-9]* of [0-9]* entr(ies), in manifest order: //p' "$1" | tr -d ',\r' | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"
  if [ -n "${vac}" ] && [ "${vac}" = "${failed}" ]; then
    echo "$2: ${vac}fail unmutated on this host; proven again in the image" >&2
    printf '%s' "${vac}"
  fi
}
