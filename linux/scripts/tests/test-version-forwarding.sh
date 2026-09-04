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

# Per-arch truth: riscv64 has no upstream CMake/Node artifact, so the image must
# advertise the distro versions it really carries — the shipped-truth probe
# compares ADV against the binaries. docs/cross-build-verification.md#per-arch-version-truth
_fwd() {  # _fwd <arch> <KEY> -> the value that would be forwarded
  local _a=(); append_version_build_args _a "$1"
  printf '%s\n' "${_a[@]}" | sed -n "s/^$2=//p" | head -1
}

t_case "a <KEY>_<ARCH> override wins for that arch only"
CMAKE_VERSION=9.9.9 CMAKE_VERSION_RISCV64=1.1.1 \
  t_assert_eq "1.1.1" "$(CMAKE_VERSION=9.9.9 CMAKE_VERSION_RISCV64=1.1.1 _fwd riscv64 CMAKE_VERSION)"
t_assert_eq "9.9.9" "$(CMAKE_VERSION=9.9.9 CMAKE_VERSION_RISCV64=1.1.1 _fwd amd64 CMAKE_VERSION)" \
  "an override for another arch must not leak"
t_assert_eq "9.9.9" "$(CMAKE_VERSION=9.9.9 CMAKE_VERSION_RISCV64=1.1.1 _fwd '' CMAKE_VERSION)" \
  "no arch given: the base value stands"

# The values above are fixtures; these read the real versions.env through the
# chain's own loader, in a subshell so the fixtures stay isolated.
_fwd_live() {
  bash -c 'source "$0/01-core/artifact-common.sh" >/dev/null 2>&1
           source "$0/01-core/version-forwarding.sh"
           _a=(); append_version_build_args _a "$1"
           printf "%s\n" "${_a[@]}" | sed -n "s/^$2=//p" | head -1' "${TESTS_DIR}/.." "$1" "$2"
}

t_case "the live tree advertises what riscv64 actually contains"
t_assert_eq "4.4.2"   "$(_fwd_live riscv64 CMAKE_VERSION)" "Kitware publishes no riscv64 archive; cmake comes from apt"
t_assert_eq "22.22.1" "$(_fwd_live riscv64 NODE_VERSION)"  "Node.js publishes no riscv64 tarball; node comes from apt"
t_assert_eq "4.4.3"   "$(_fwd_live amd64 CMAKE_VERSION)"   "amd64 keeps the Kitware pin"

t_case "a forwarded key that merely ends in _<ARCH> is not an override"
# The override lookup is skipped for any name that is itself forwarded, so a
# real key is never mistaken for another key's per-arch value.
_tracked() { if _vf_is_tracked "$1"; then echo tracked; else echo unknown; fi; }
t_assert_eq "tracked" "$(_tracked GENAI_ALLOW_RISCV64)" "it is a versions.env key of its own"
t_assert_eq "unknown" "$(_tracked CMAKE_VERSION_RISCV64)" "the override is # noforward, so it is not a key"
t_assert_eq "unknown" "$(_tracked NOT_A_VERSIONS_ENV_KEY)" "and an unrelated name is neither"
t_assert_eq "true" "$(_fwd_live riscv64 GENAI_ALLOW_RISCV64)" \
  "GENAI_ALLOW_RISCV64 is a key in its own right and must still be forwarded"

# TS4 REGRESSION GUARD (2026-08-24): the llvm-project checkout lives on a
# shared cachemount. build-clang.sh used a version-LESS path behind a bare
# directory-exists guard, so an LLVM bump silently rebuilt LAST release's
# sources. Assert the path is keyed on the tag and the reuse test verifies
# CONTENT (rev-parse + populated worktree), in both toolchain entry points.
_bc="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}/linux/scripts/02-toolchain/build-clang.sh"
_lc="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}/linux/scripts/02-toolchain/llvm-cross.sh"
t_case "build-clang.sh keys its llvm checkout dir on the LLVM tag"
if grep -qE 'SRC_DIR="\$\{WD\}/llvm-project-\$\{LLVM_TAG\}"' "${_bc}"; then t_assert_eq ok ok; else
  t_assert_eq "version-keyed" "version-less" "SRC_DIR lost its \${LLVM_TAG} suffix — a bump would rebuild stale sources"; fi
t_case "build-clang.sh verifies checkout CONTENT before reuse (not just -d)"
if grep -q 'rev-parse -q --verify HEAD' "${_bc}" && grep -q 'llvm/CMakeLists.txt' "${_bc}"; then t_assert_eq ok ok; else
  t_assert_eq "content-verified" "bare -d test" "the reuse guard regressed to a directory-exists test"; fi
t_case "llvm-cross.sh verifies checkout CONTENT before reuse (not just .git)"
if grep -q 'rev-parse -q --verify HEAD' "${_lc}" && grep -q 'llvm/CMakeLists.txt' "${_lc}"; then t_assert_eq ok ok; else
  t_assert_eq "content-verified" "bare .git test" "the reuse guard regressed"; fi
t_case "both entry points evict superseded llvm generations"
if [ "$(grep -l 'Evicting stale llvm checkout' "${_bc}" "${_lc}" | wc -l)" -eq 2 ]; then t_assert_eq ok ok; else
  t_assert_eq "eviction in both" "missing" "unbounded ~2GB-per-release growth on the shared cachemount"; fi

# Quoting a `;`-bearing versions.env value must change the stderr noise and
# nothing else. docs/cross-build-verification.md#per-arch-version-truth
_VE="${TESTS_DIR}/../01-core/versions.env"
_LVE="${TESTS_DIR}/../01-core/load-versions-env.sh"

t_case "versions.env can be sourced with no stderr at all"
t_assert_eq "" "$(bash -c '. "$1"' _ "${_VE}" 2>&1 >/dev/null)" \
  "an unquoted value runs its own tail as commands on every hook run"

t_case "the loader exports the bare value, and forwarding does not re-quote it"
t_assert_eq "80;86;89;90" \
  "$(bash -c 'set -u; source "$2"; load_versions_env "$1"; printf "%s" "${CUDA_ARCHITECTURES}"' \
     _ "${_VE}" "${_LVE}")" "quotes in the file are syntax, never data"
t_assert_eq "CUDA_ARCHITECTURES=80;86;89;90" \
  "$(bash -c 'set -u; source "$2"; load_versions_env "$1"; source "$3"
              _a=(); append_version_build_args _a
              printf "%s\n" "${_a[@]}" | grep -e "^CUDA_ARCHITECTURES="' \
     _ "${_VE}" "${_LVE}" "${TESTS_DIR}/../01-core/version-forwarding.sh")" \
  "a quoted build-arg would reach CMake as data and defeat the 90 -> 90a transform"

t_summary
