#!/usr/bin/env bash
set -u
operation="$1"
archive="${*: -2:1}"
member="${*: -1}"
if [ "$operation" = l ]; then
  archive="${*: -1}"
  printf '%s\n' '----------'
  if [[ "$archive" == *.msi ]]; then
    if [[ " $* " != *' -tCompound '* ]]; then printf '%s\n' 'Path = f9179'; exit 0; fi
    printf '%s\n\n' 'Path = cab1.cab'
    [ "${FAKE_MSI_SINGLE:-0}" = 1 ] || printf '%s\n\n' 'Path = cab2.cab'
  elif [ "$(cat "$archive")" = CAB2 ] || [ "${FAKE_MSI_SINGLE:-0}" = 1 ] || [ "${FAKE_BOTH_CONTAIN:-0}" = 1 ]; then
    printf 'Path = f9179\nSize = 40\n\nPath = f9180\nSize = 40\n\n'
    [ "${FAKE_DUPLICATE:-0}" = 0 ] || printf 'Path = f9179\nSize = 40\n\n'
    [ "${FAKE_ALIASED:-0}" = 0 ] || printf 'Path = ./f9179\nSize = 40\n\n'
  fi
elif [ "$operation" = e ]; then
  if [ "${FAKE_EXTRACT_FAIL:-0}" != 0 ] && [[ "$archive" == *.msi ]]; then printf CAB2; exit 9; fi
  if [[ "$archive" == *.msi ]]; then
    [ "${FAKE_CAB_FAIL:-0}" = 0 ] || exit 9
    case "$member" in cab1.cab) printf CAB1 ;; cab2.cab) printf CAB2 ;; external.cab) [ "${FAKE_ACCEPT_EXTERNAL:-0}" = 1 ] && printf CAB2 ;; *) exit 1 ;; esac
  else
    [ "$member" = f9179 ] || exit 1
    [ "${FAKE_MEMBER_FAIL:-0}" = 0 ] || exit 8
    cat "${FAKE_LICENSE:-$FAKE_BINARY}"
  fi
elif [ "$operation" = x ]; then
  output=''
  while [ "$#" -gt 0 ]; do
    case "$1" in -o*) output="${1#-o}" ;; --) shift; break ;; esac
    shift
  done
  shift
  [ -z "${FAKE_COUNT_FILE:-}" ] || printf 'x\n' >> "$FAKE_COUNT_FILE"
  for member in "$@"; do
    case "$member" in f9179|f9180) cp "$FAKE_LICENSE" "$output/$member" ;; *) exit 1 ;; esac
  done
else
  exit 1
fi
