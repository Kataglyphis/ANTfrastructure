#!/usr/bin/env bash
sudo_policy_select() {
  if "$1" "${@:6}"; then
    "$2" "${@:6}" >/dev/null 2>&1 || "$3" "${@:6}"
    "$4" "${@:6}"
  else
    "$5" "${@:6}"
  fi
  return $?
}
