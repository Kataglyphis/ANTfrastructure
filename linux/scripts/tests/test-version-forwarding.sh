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

t_case "an UNSET forwarded var is omitted (the 'only' half)"
build_cmd=()
# CMAKE_VERSION deliberately unset in this subshell-free context:
_saved="${CMAKE_VERSION:-}"; unset CMAKE_VERSION
append_version_build_args build_cmd
joined="${build_cmd[*]}"
case "${joined}" in
  *"CMAKE_VERSION="*) t_assert_eq "omitted" "emitted" "unset var became --build-arg CMAKE_VERSION= and would OVERRIDE the Dockerfile ARG default with empty" ;;
  *) t_assert_eq "ok" "ok" ;;
esac
[ -n "${_saved}" ] && export CMAKE_VERSION="${_saved}"

t_case "a # noforward var is never emitted even when set"
build_cmd=()
VENV_PATH="/opt/venv" append_version_build_args build_cmd
joined="${build_cmd[*]}"
case "${joined}" in
  *"VENV_PATH="*) t_assert_eq "omitted" "emitted" "noforward marker must keep VENV_PATH out of build args" ;;
  *) t_assert_eq "ok" "ok" ;;
esac

# C3 REGRESSION GUARD (2026-08-24): a build-arg that the orchestrator PASSES but
# the Dockerfile never DECLARES is silently dropped by BuildKit, and the build
# script then falls back to an inline literal. That was live, not theoretical:
# android shipped onnxruntime v1.28.0 against a v1.29.0 pin and litert v2.1.6
# against a v2.2.0 pin. Two halves must both hold, so assert both.
_dfa="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}/linux/Dockerfile.android"
for _v in ONNXRUNTIME_VERSION LITERT_VERSION IREE_VERSION; do
  t_case "Dockerfile.android DECLARES ARG ${_v} (else BuildKit drops the forward)"
  if grep -qE "^ARG ${_v}\b" "${_dfa}"; then t_assert_eq "ok" "ok"; else
    t_assert_eq "declared" "missing" "ARG ${_v} absent — the passed build-arg would be dropped"; fi
  t_case "Dockerfile.android promotes ${_v} to ENV (so all android-<lib> stages inherit it)"
  if grep -qE "^[[:space:]]*${_v}=\\\$\{${_v}\}" "${_dfa}"; then t_assert_eq "ok" "ok"; else
    t_assert_eq "in ENV" "missing" "${_v} not promoted to ENV — the library stages will not see it"; fi
done

# The other half: no android build script may carry a silent version literal.
for _lib in onnxruntime litert iree; do
  _f="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}/linux/scripts/03-media/build/${_lib}/android/build-android.sh"
  t_case "${_lib} android build has no silent version fallback"
  if [ -f "${_f}" ] && grep -qE ':-[[:space:]]*v?[0-9]+\.[0-9]+(\.[0-9]+)?[[:space:]]*\}' "${_f}"; then
    t_assert_eq "no literal fallback" "literal fallback present" "${_lib}: a :-<version> literal masks a broken forward"
  else
    t_assert_eq "ok" "ok"
  fi
done

t_summary
