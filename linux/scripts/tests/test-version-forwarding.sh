#!/usr/bin/env bash
# Tests for 01-core/version-forwarding.sh — the awk discovery that decides
# which versions.env keys become --build-arg on every build, including the
# `# noforward` opt-out parsing.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/version-forwarding.sh"

_has_var() {  # _has_var NAME -> 0 if discovered as forwarded
  local v
  for v in "${_VERSION_BUILD_ARG_VARS[@]}"; do [ "${v}" = "$1" ] && return 0; done
  return 1
}

t_case "forwarded keys are discovered"
t_assert_ok _has_var CMAKE_VERSION
t_assert_ok _has_var VULKAN_VERSION
t_assert_ok _has_var GCC_VERSION

t_case "# noforward keys are excluded"
t_assert_fails _has_var IMAGE_REGISTRY_PREFIX
t_assert_fails _has_var CROSS_DEFAULT_ARCHES
t_assert_fails _has_var HADOLINT_VERSION
t_assert_fails _has_var SCOOP_INSTALLER_SHA256

t_case "append_version_build_args emits --build-arg for set vars only"
build_cmd=()
CMAKE_VERSION="9.9.9" append_version_build_args build_cmd
joined="${build_cmd[*]}"
t_assert_contains "${joined}" "CMAKE_VERSION=9.9.9" "a set forwarded var must be emitted"

t_summary
