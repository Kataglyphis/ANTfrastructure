#!/usr/bin/env bash
# Local C/C++ and CMake fixtures cover selection and exclusions, not formatter output or installed toolchains.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# shellcheck source=../lib/code-quality.sh
source "${TESTS_DIR}/../lib/code-quality.sh"

w="$(mktemp -d)"
trap 'rm -rf "${w}"' EXIT
for f in src/app.cpp src/app.h src/CMakeLists.txt windows/flutter/generated_plugin_registrant.cc \
         .opencode/node_modules/msgpackr-extract/src/extract.cpp node_modules/addon/CMakeLists.txt \
         .pub-cache/hosted/fl_chart/example/linux/main.cc .dart_tool/gen.h android/app/.cxx/gen.cpp \
         android/.gradle/gen.c .cargo/registry/src/cc/x.c windows/flutter/ephemeral/cpp_client_wrapper/core.cc; do
  mkdir -p "${w}/$(dirname "${f}")"
  : > "${w}/${f}"
done
# walk <function>: what it lists from the tree root, sorted, one line.
walk() ( cd "${w}" && "$1" . | LC_ALL=C sort | tr '\n' ' ' )

t_case "the clang-format walk grades the repository's own files and no dependency tree"
t_assert_eq "./src/app.cpp ./src/app.h ./windows/flutter/generated_plugin_registrant.cc " "$(walk code_quality_find_cpp_files)"

t_case "the clang-tidy walk skips the same trees, and headers"
t_assert_eq "./src/app.cpp ./windows/flutter/generated_plugin_registrant.cc " "$(walk code_quality_find_clang_tidy_files)"

t_case "the CMake walk skips them by default, and a consumer's list adds to them"
t_assert_eq "./src/CMakeLists.txt " "$(cd "${w}" && CODE_QUALITY_CMAKE_SEARCH_ROOT=. code_quality_find_cmake_files | LC_ALL=C sort | tr '\n' ' ')"
# shellcheck disable=SC2034  # code_quality_find_cmake_files reads it
CODE_QUALITY_CMAKE_EXCLUDE_PATHS=('*/src/*')
t_assert_eq "" "$(cd "${w}" && CODE_QUALITY_CMAKE_SEARCH_ROOT=. code_quality_find_cmake_files)"

t_case "configured extension lists remain independent and keep literal spaces"
: > "${w}/src/own.special ext"
: > "${w}/src/own.custom"
CODE_QUALITY_CPP_FORMAT_EXTENSIONS=('special ext')
CODE_QUALITY_CLANG_TIDY_EXTENSIONS=(custom)
t_assert_eq "./src/own.special ext " "$(walk code_quality_find_cpp_files)"
t_assert_eq "./src/own.custom " "$(walk code_quality_find_clang_tidy_files)"

t_case "an empty first configured extension restores each distinct default list"
CODE_QUALITY_CPP_FORMAT_EXTENSIONS=('' custom)
CODE_QUALITY_CLANG_TIDY_EXTENSIONS=()
t_assert_eq "./src/app.cpp ./src/app.h ./windows/flutter/generated_plugin_registrant.cc " "$(walk code_quality_find_cpp_files)"
t_assert_eq "./src/app.cpp ./windows/flutter/generated_plugin_registrant.cc " "$(walk code_quality_find_clang_tidy_files)"

code_quality_find_cpp_files "${w}" >/dev/null
code_quality_find_clang_tidy_files "${w}" >/dev/null
t_assert_eq '' "${CODE_QUALITY_CPP_FORMAT_EXTENSIONS[0]}" "default selection must not overwrite the caller's array"
t_assert_eq custom "${CODE_QUALITY_CPP_FORMAT_EXTENSIONS[1]}"
t_assert_eq 0 "${#CODE_QUALITY_CLANG_TIDY_EXTENSIONS[@]}"

t_case "multiple roots and no roots keep their existing contracts"
mkdir -p "${w}/extra"
: > "${w}/extra/second.cpp"
t_assert_eq "${w}/src/app.cpp
${w}/extra/second.cpp" "$(code_quality_find_clang_tidy_files "${w}/src" "${w}/extra")"
_no_roots() (
  find() { printf 'unexpected walk'; return 93; }
  code_quality_find_cpp_files
  code_quality_find_clang_tidy_files
)
t_assert_eq "" "$(_no_roots)"

t_case "caller IFS does not change the default extensions"
t_assert_eq "./extra/second.cpp ./src/app.cpp ./windows/flutter/generated_plugin_registrant.cc " "$(IFS=:; walk code_quality_find_clang_tidy_files)"

t_summary
