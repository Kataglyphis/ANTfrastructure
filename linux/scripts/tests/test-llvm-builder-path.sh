#!/usr/bin/env bash
# Stubbed file checks cover ordered lookup, not invoking or building LLVM.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
builder_source="${1:-${TESTS_DIR}/../02-toolchain/llvm.sh}"
t_source_functions "$builder_source" llvm_build_script
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Lifted functions resolve their source directory to this fixture, keeping lookup independent of real installed tools.
local_builder="${TESTS_DIR}/build-clang.sh"
container_builder=/opt/scripts/toolchain/build-clang.sh
function [ {
  if builtin [ "$1" = -f ]; then
    printf '%s\n' "$2" >> "$work/probes"
    case "$available:$2" in
      both:*) return 0 ;;
      local:"$local_builder") return 0 ;;
      container:"$container_builder") return 0 ;;
    esac
    return 1
  fi
  builtin [ "$@"
}
for available in local container both neither; do
  t_case "builder availability: $available"
  : > "$work/probes"
  status=0
  actual="$(llvm_build_script)" || status=$?
  expected="$local_builder" expected_status=0
  case "$available" in
    container) expected="$container_builder" ;;
    neither) expected='' expected_status=1 ;;
  esac
  t_assert_eq "$expected" "$actual"
  t_assert_eq "$expected_status" "$status"
  expected_probes="$local_builder"
  case "$available" in container|neither) expected_probes+="|$container_builder" ;; esac
  t_assert_eq "$expected_probes" "$(paste -sd '|' "$work/probes")"
done
unset -f '['
t_summary
