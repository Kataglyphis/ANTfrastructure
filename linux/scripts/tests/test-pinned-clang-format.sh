#!/usr/bin/env bash
# code_quality_require_pinned_clang_format over stand-in clang-formats: which release it takes, and that the check uses it.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB="$(cd "${TESTS_DIR}/../lib" && pwd)/code-quality.sh"

w="$(mktemp -d)"
trap 'rm -rf "${w}"' EXIT
# fake <dir> <version>: a clang-format reporting that release, which deviates on a file named bad.cpp.
fake() {
  mkdir -p "$1"
  printf '#!/bin/sh\n[ "$1" = --version ] && { echo "clang-format version %s (fake)"; exit 0; }\necho "$*" >> "%s/calls"\ncase "$*" in *bad.cpp*) exit 1 ;; esac\nexit 0\n' \
    "$2" "$1" > "$1/clang-format"
  chmod +x "$1/clang-format"
}
fake "${w}/near" 23.1.30
fake "${w}/pinned" 23.1.3
fake "${w}/path" 23.1.3
: > "${w}/good.cpp"
: > "${w}/bad.cpp"

# pick [VAR=value ...]: the binary the library settles on, with PATH=${w}/path:<system>; its output in ${w}/out.
pick() {
  env PATH="${w}/path:/usr/bin:/bin" "$@" bash -c 'source "$1" && code_quality_require_pinned_clang_format >/dev/null 2>&1 && printf "%s" "${CODE_QUALITY_CLANG_FORMAT}"' _ "${LIB}" \
    > "${w}/out" 2>&1
}

t_case "the first candidate of LLVM_RELEASE wins, and 23.1.30 is no 23.1.3"
t_assert_ok pick LLVM_RELEASE=23.1.3 CODE_QUALITY_CLANG_FORMAT_CANDIDATES="${w}/near/clang-format ${w}/pinned/clang-format"
t_assert_eq "${w}/pinned/clang-format" "$(cat "${w}/out")"

t_case "PATH's clang-format is the last candidate"
t_assert_ok pick LLVM_RELEASE=23.1.3 CODE_QUALITY_CLANG_FORMAT_CANDIDATES="${w}/near/clang-format"
t_assert_eq "${w}/path/clang-format" "$(cat "${w}/out")"

t_case "no clang-format of the pinned release fails, naming it"
t_assert_fails pick LLVM_RELEASE=23.1.9 CODE_QUALITY_CLANG_FORMAT_CANDIDATES="${w}/near/clang-format"
env PATH="${w}/path:/usr/bin:/bin" LLVM_RELEASE=23.1.9 CODE_QUALITY_CLANG_FORMAT_CANDIDATES="${w}/near/clang-format" \
  bash -c 'source "$1"; code_quality_require_pinned_clang_format' _ "${LIB}" > "${w}/out" 2>&1
t_assert_contains "$(cat "${w}/out")" "No clang-format 23.1.9 (the hub's LLVM_RELEASE)"

t_case "without LLVM_RELEASE the hub's versions.env decides"
want="$(sed -n 's/^LLVM_RELEASE=//p' "${TESTS_DIR}/../01-core/versions.env")"
fake "${w}/from-env" "${want}"
t_assert_ok pick LLVM_RELEASE= CODE_QUALITY_CLANG_FORMAT_CANDIDATES="${w}/near/clang-format ${w}/from-env/clang-format"
t_assert_eq "${w}/from-env/clang-format" "$(cat "${w}/out")"

t_case "the check and the rewrite run the binary it picked, not the one on PATH"
env PATH="${w}/path:/usr/bin:/bin" LLVM_RELEASE=23.1.3 CODE_QUALITY_CLANG_FORMAT_CANDIDATES="${w}/pinned/clang-format" bash -c '
  source "$1"
  code_quality_require_pinned_clang_format >/dev/null 2>&1
  code_quality_check_clang_format "$2/good.cpp" "$2/bad.cpp" >/dev/null 2>&1
  code_quality_run_clang_format "$2/good.cpp" >/dev/null 2>&1
  echo "deviations=${CODE_QUALITY_CLANG_FORMAT_DEVIATIONS}"' _ "${LIB}" "${w}" > "${w}/out" 2>&1
t_assert_eq "deviations=1" "$(cat "${w}/out")"
t_assert_eq 3 "$(wc -l < "${w}/pinned/calls" | tr -d ' ')"
t_assert_fails test -e "${w}/path/calls"

t_summary
