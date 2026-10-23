#!/usr/bin/env bash
# Shared setup keeps module selection and cleanup consistent across path-probe fixtures.
_TOOLCHAIN_FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./test-harness.sh
source "${_TOOLCHAIN_FIXTURE_DIR}/test-harness.sh"

cross_toolchain_fixture_init() {
  local -n workspace_ref="$1"
  case "$2" in
    cross-python.sh)
      _CROSS_TOOLCHAIN_FIXTURE_MODULE="${3:-${_TOOLCHAIN_FIXTURE_DIR}/../01-core/cross-python.sh}"
      # shellcheck source=../01-core/cross-python.sh
      source "$_CROSS_TOOLCHAIN_FIXTURE_MODULE" || return $?
      ;;
    compiler-resolution.sh)
      _CROSS_TOOLCHAIN_FIXTURE_MODULE="${3:-${_TOOLCHAIN_FIXTURE_DIR}/../01-core/compiler-resolution.sh}"
      # shellcheck source=../01-core/compiler-resolution.sh
      source "$_CROSS_TOOLCHAIN_FIXTURE_MODULE" || return $?
      ;;
    *) return 2 ;;
  esac
  workspace_ref=$(mktemp -d) || return 1
  _CROSS_TOOLCHAIN_FIXTURE_WORK="$workspace_ref"
  trap 'rm -rf -- "$_CROSS_TOOLCHAIN_FIXTURE_WORK"' EXIT
}
