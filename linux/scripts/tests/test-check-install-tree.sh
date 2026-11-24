#!/usr/bin/env bash
# check-install-tree.sh over fixture trees: which files are build-time, and --allow.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CHECK="${TESTS_DIR}/../06-packaging/check-install-tree.sh"
w="$(t_mktemp -d)"
for f in usr/bin/app usr/lib/libapp.so.1 usr/share/doc/app/copyright usr/include/gtest/gtest.h \
         usr/lib/x86_64-linux-gnu/cmake/GTest/GTestConfig.cmake usr/lib/pkgconfig/gtest.pc usr/lib/libgtest.a; do
  mkdir -p "${w}/tree/$(dirname "${f}")"
  : > "${w}/tree/${f}"
done

t_case "headers, CMake and pkg-config packages and static libraries are refused, with their count"
out="$(bash "${CHECK}" "${w}/tree" 2>&1)"
t_assert_eq 1 "$?" "a tree with build-time files must fail"
t_assert_contains "${out}" "ships 4 build-time file(s)"

t_case "--allow excepts what the product ships on purpose"
t_assert_contains "$(bash "${CHECK}" "${w}/tree" --allow usr/include 2>&1)" "ships 3 build-time file(s)"
t_assert_contains "$(bash "${CHECK}" "${w}/tree" --allow usr/include --allow usr/lib 2>&1)" "ships no build-time file"

t_case "a runtime-only tree passes"
mkdir -p "${w}/clean/usr/bin"
: > "${w}/clean/usr/bin/app"
bash "${CHECK}" "${w}/clean" >/dev/null
t_assert_eq 0 "$?" "binaries, shared libraries and docs are what a package is for"

t_summary
