#!/usr/bin/env bash
# Tests for check_cmake_format, the inline preflight gate: the repo's own CMake
# files must satisfy cmake-format --check under the root .cmake-format.yaml.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
REPO_ROOT="$(cd "${TESTS_DIR}/../../.." && pwd)"

FN_SRC="$(t_fn_src "${REPO_ROOT}/linux/scripts/preflight.sh" check_cmake_format)" || exit 1
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
printf '%s\n' "${FN_SRC}" > "${WORK}/guard.sh"

# One fixture tree, one venv: the gate's own uv path provisions cmake-format on
# the first run and reuses the fixture-local .venv-cmake-format afterwards.
TREE="${WORK}/tree"
mkdir -p "${TREE}/cmake"
# 01-core/tool-checks.sh: code-quality.sh sources it for has_tool/require_tools
# (it used to carry an inline copy). A fixture tree missing a real dependency
# fails as a bash "No such file" and every assertion below reads that instead.
for _m in lib/code-quality.sh lib/log-bootstrap.sh 01-core/python_uv.sh \
          01-core/logging.sh 01-core/tool-checks.sh cmake-format.requirements.txt; do
  install -D -m 0644 "${REPO_ROOT}/linux/scripts/${_m}" "${TREE}/linux/scripts/${_m}"
done
cp "${REPO_ROOT}/.cmake-format.yaml" "${TREE}/.cmake-format.yaml"

_clean_corpus() {
  printf 'function(fixture_fn)\n  message(STATUS "ok")\nendfunction()\n' \
    > "${TREE}/cmake/Fixture.cmake"
}
_clean_corpus

OUT=""; rc=0
_guard() {
  OUT="$(cd "${TREE}" && bash -c 'set -u
source "$1"
check_cmake_format' _ "${WORK}/guard.sh" 2>&1)"
  rc=$?
}

t_case "a well-formatted corpus passes (cmake-format bootstrapped via uv)"
_guard
t_assert_eq "0" "${rc}" "clean fixture corpus must pass; output was: ${OUT}"
t_assert_contains "${OUT}" "checking 1 CMake file(s)" "the walk must report what it checked"

t_case "a mis-formatted file is a red verdict naming the offender"
printf 'set(_drift    "badly"     "spaced")\n' >> "${TREE}/cmake/Fixture.cmake"
_guard
t_assert_eq "1" "${rc}" "printing is not enough; formatting drift must fail"
t_assert_contains "${OUT}" "Fixture.cmake" "the offender must be named"

t_case "CRLF line endings alone are drift (line_ending: unix is enforced)"
printf 'function(fixture_fn)\r\n  message(STATUS "ok")\r\nendfunction()\r\n' \
  > "${TREE}/cmake/Fixture.cmake"
_guard
t_assert_eq "1" "${rc}" "a CRLF-only deviation must fail --check, not slide through"

t_case "restoring the corpus goes green again"
_clean_corpus
_guard
t_assert_eq "0" "${rc}" "restored corpus must pass again; output was: ${OUT}"

t_case "an empty walk is a refusal, not a green"
rm "${TREE}/cmake/Fixture.cmake"
_guard
t_assert_eq "1" "${rc}" "zero files found must fail loud, not report green over nothing"
t_assert_contains "${OUT}" "returned nothing" "the refusal must say the walk came back empty"

# --- the walk's default exclusions -------------------------------------------
# flutter_lane_prepare_env defaults PUB_CACHE to <repo>/.pub-cache on purpose,
# so a consumer that runs the prologue and then this walk graded its
# DEPENDENCIES' CMake files -- 28 of them in OmniAccelerANT, fl_chart's
# example/linux/CMakeLists.txt among them. The hub made the directory, so the
# hub excludes it, and a consumer's own list has to survive that.
source "${REPO_ROOT}/linux/scripts/lib/code-quality.sh"
_WALK="${WORK}/walk"
mkdir -p "${_WALK}/src" "${_WALK}/.pub-cache/hosted/fl_chart/example/linux" "${_WALK}/vendor"
: > "${_WALK}/src/CMakeLists.txt"
: > "${_WALK}/.pub-cache/hosted/fl_chart/example/linux/CMakeLists.txt"
: > "${_WALK}/vendor/Vendored.cmake"
_walk() (
  cd "${_WALK}" && CODE_QUALITY_CMAKE_SEARCH_ROOT=. code_quality_find_cmake_files | sort
)

t_case "the pub cache the hub's own prologue creates is excluded by default"
CODE_QUALITY_CMAKE_EXCLUDE_PATHS=()
_wout="$(_walk)"
t_assert_contains "${_wout}" "./src/CMakeLists.txt" "the repo's own file must still be walked"
t_assert_eq "" "$(printf '%s' "${_wout}" | grep -F '.pub-cache' || true)" \
  "a dependency's example/ CMake is not the consumer's code to format"

t_case "a consumer's own list is ADDED to the defaults, never replaces them"
CODE_QUALITY_CMAKE_EXCLUDE_PATHS=('*/vendor/*')
_wout="$(_walk)"
t_assert_contains "${_wout}" "./src/CMakeLists.txt" "the repo's own file survives both lists"
t_assert_eq "" "$(printf '%s' "${_wout}" | grep -F 'vendor' || true)" \
  "the consumer's own glob must still apply"
t_assert_eq "" "$(printf '%s' "${_wout}" | grep -F '.pub-cache' || true)" \
  "setting a list must not silently drop the directories the hub itself created"
CODE_QUALITY_CMAKE_EXCLUDE_PATHS=()

t_summary
