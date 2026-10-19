#!/usr/bin/env bash
# code-quality.sh's C/C++ and CMake walks skip the dependency and output trees git never lists.
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

t_summary
