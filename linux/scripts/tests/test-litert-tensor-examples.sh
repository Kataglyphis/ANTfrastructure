#!/usr/bin/env bash
# LiteRT v2.3.0's tensor examples break the Linux and Android CMake builds (sentencepiece v0.2.0 lacks <cstdint>); both lanes prune them.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LITERT_DIR="${TESTS_DIR}/../03-media/build/litert"
HELPER="${LITERT_DIR}/android/litert-tensor-examples.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# shellcheck source=../03-media/build/litert/android/litert-tensor-examples.sh
_prune() { ( source "${HELPER}"; litert_prune_tensor_examples "$1" ) >"${_work}/out" 2>&1; }

t_case "the helper lives where Dockerfile.android can COPY it"
t_assert_ok test -f "${HELPER}"

t_case "it removes tensor/examples and leaves the rest of the tree"
mkdir -p "${_work}/a/tensor/examples/gemma3" "${_work}/a/tensor/src" "${_work}/a/litert"
: > "${_work}/a/tensor/examples/gemma3/CMakeLists.txt"
: > "${_work}/a/tensor/CMakeLists.txt"
t_assert_ok _prune "${_work}/a"
t_assert_fails test -e "${_work}/a/tensor/examples"
t_assert_ok test -f "${_work}/a/tensor/CMakeLists.txt"
t_assert_ok test -d "${_work}/a/tensor/src"
t_assert_contains "$(cat "${_work}/out")" "pruned"

t_case "a tree without examples is a no-op, not an error"
mkdir -p "${_work}/b/tensor"
t_assert_ok _prune "${_work}/b"
t_assert_ok test -d "${_work}/b/tensor"

t_case "a missing root argument fails instead of pruning a relative path"
t_assert_fails _prune ""

t_case "the Linux lane sources and calls it before configuring"
t_assert_contains "$(cat "${LITERT_DIR}/build-litert.sh")" "android/litert-tensor-examples.sh"
t_assert_contains "$(cat "${LITERT_DIR}/build-litert.sh")" 'litert_prune_tensor_examples "${LITERT_SRC}"'

t_case "the Android lane sources and calls it too"
t_assert_contains "$(cat "${LITERT_DIR}/android/build-android.sh")" "litert-tensor-examples.sh"
t_assert_contains "$(cat "${LITERT_DIR}/android/build-android.sh")" 'litert_prune_tensor_examples "${PWD}"'

t_summary
