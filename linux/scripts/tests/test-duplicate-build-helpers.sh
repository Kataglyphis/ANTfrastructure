#!/usr/bin/env bash
# Build arguments and setup failures use stubbed tools; no apt transaction, GPU or container build runs here.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
ORT="${TESTS_DIR}/../03-media/build/onnxruntime/build"
for fn in install_onnx_native_dependencies _onnx_compiler_cache_launcher append_onnx_gpu_cache_args; do
  eval "$(t_fn_src "${ORT}/lib/common.sh" "${fn}")"
done
eval "$(t_fn_src "${TESTS_DIR}/../01-core/runtime-build-fns.sh" _runtime_package_artifact_context)"
command() {
  t_command_available_override sudo "${WITH_SUDO:-0}" "$@"
}
sudo() { printf 'sudo\n'; "$@"; }
apt-get() {
  printf 'apt-get'; printf ' <%s>' "$@"; printf '\n'
  case "$1" in update) return "${UPDATE_STATUS:-0}" ;; install) return "${INSTALL_STATUS:-0}" ;; esac
}
t_case "GPU setup keeps quiet updates and no-recommends installs"
t_assert_eq $'apt-get <update> <-qq>\napt-get <install> <-y> <--no-install-recommends> <libgcc-s1>' "$(install_onnx_native_dependencies gpu)"
t_case "CPU setup keeps its original apt flags"
t_assert_eq $'apt-get <update>\napt-get <install> <-y> <libgcc-s1>' "$(install_onnx_native_dependencies cpu)"
t_case "sudo prefixes both apt invocations only when available"
t_assert_eq $'sudo\napt-get <update> <-qq>\nsudo\napt-get <install> <-y> <--no-install-recommends> <libgcc-s1>' "$(WITH_SUDO=1 install_onnx_native_dependencies gpu)"
t_case "skip leaves apt untouched"
t_assert_eq '' "$(SKIP_DEP_INSTALL=true install_onnx_native_dependencies gpu)"
t_case "failed updates skip installation and preserve the original continuation"
t_assert_eq 'apt-get <update> <-qq>' "$(UPDATE_STATUS=7 install_onnx_native_dependencies gpu)"
t_assert_eq 0 "$(UPDATE_STATUS=7 t_rc install_onnx_native_dependencies gpu)"
t_case "install failures retain their status"
t_assert_eq 23 "$(INSTALL_STATUS=23 t_rc install_onnx_native_dependencies gpu)"
info() { printf 'INFO %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
compiler_cache_launcher_env() { :; }
compiler_cache_launcher() { printf '%s' "${LAUNCHER:-/cache/sccache}"; }
_cache_args() {
  local -a args=(existing)
  append_onnx_gpu_cache_args args "$1"
  printf 'ARGS'; printf ' <%s>' "${args[@]}"; printf '\n'
}
for language in CUDA HIP; do
  t_case "${language}: opt-out leaves arguments unchanged"
  t_assert_eq 'ARGS <existing>' "$(ENABLE_SCCACHE_CUDA=0 ENABLE_SCCACHE_HIP=0 _cache_args "${language}")"
  t_case "${language}: sccache appends only its own compiler launcher"
  t_assert_contains "$(ENABLE_SCCACHE_CUDA=1 ENABLE_SCCACHE_HIP=1 _cache_args "${language}")" "ARGS <existing> <--cmake_extra_defines> <CMAKE_${language}_COMPILER_LAUNCHER=/cache/sccache>"
  t_case "${language}: ccache remains excluded from GPU compiler wrapping"
  _out="$(ENABLE_SCCACHE_CUDA=1 ENABLE_SCCACHE_HIP=1 LAUNCHER=/cache/ccache _cache_args "${language}")"
  t_assert_contains "${_out}" "sccache unavailable for ${language} caching"
  t_assert_contains "${_out}" 'ARGS <existing>'
done
runtime_use_local_artifact_context() { [ "${LOCAL_CONTEXT:-0}" = 1 ] && return 0; return 1; }
runtime_artifact_context_ref() { printf 'context/%s/%s' "$1" "$2"; }
runtime_artifact_image_ref() { printf 'mutable/%s' "$1"; }
_artifact_args() {
  local image
  local -a args=(existing)
  _runtime_package_artifact_context arm64 "$1" image args
  printf 'IMAGE <%s> ARGS' "${image}"; printf ' <%s>' "${args[@]}"; printf '\n'
}
t_case "local package and smoke contexts outrank a registry pin"
t_assert_eq 'IMAGE <runtime_artifact> ARGS <existing> <--build-context> <runtime_artifact=context/arm64/oci>' "$(LOCAL_CONTEXT=1 _artifact_args repo@sha256:fixture)"
t_case "local context mode is forwarded unchanged"
t_assert_contains "$(LOCAL_CONTEXT=1 ARTIFACT_CONTEXT_MODE=dir _artifact_args '')" 'runtime_artifact=context/arm64/dir'
t_case "a pushed artifact uses its immutable pin"
t_assert_eq 'IMAGE <repo@sha256:fixture> ARGS <existing>' "$(_artifact_args repo@sha256:fixture)"
t_case "an unpinned artifact retains the original mutable reference"
t_assert_eq 'IMAGE <mutable/arm64> ARGS <existing>' "$(_artifact_args '')"
for _site in '30-build-native.sh cpu' '30-build-native-amd.sh gpu' '30-build-native-nvidia.sh gpu'; do
  read -r _file _mode <<< "${_site}"
  t_assert_contains "$(cat "${ORT}/${_file}")" "install_onnx_native_dependencies ${_mode}"
done
t_case "cache resolution keeps the CPU fallback and GPU empty fallback distinct"
compiler_cache_launcher() { return 1; }
_resolved_launcher() {
  local resolved
  _onnx_compiler_cache_launcher resolved "${1:-}"
  printf '%s' "${resolved}"
}
t_assert_eq ccache "$(_resolved_launcher ccache)"
t_assert_eq '' "$(_resolved_launcher)"
t_case "cache setup exports survive resolution and diagnostics never enter the launcher path"
_cache_environment() {
  (
    local resolved='' cache_environment=unset
    compiler_cache_launcher_env() { cache_environment=ready; printf 'setup diagnostic\n'; }
    compiler_cache_launcher() { printf /cache/sccache; }
    _onnx_compiler_cache_launcher resolved
    printf 'LAUNCHER <%s> SETUP <%s>\n' "${resolved}" "${cache_environment}"
  )
}
t_assert_eq $'setup diagnostic\nLAUNCHER </cache/sccache> SETUP <ready>' "$(_cache_environment)"
t_case "unknown host-tool options retain their error and usage before exiting"
for _script in stop-cross-chain.sh 06-packaging/verify-parity.sh; do
  _script="${TESTS_DIR}/../${_script}"
  t_assert_eq 1 "$(t_rc bash "${_script}" --unknown-fixture)"
  _out="$(t_out bash "${_script}" --unknown-fixture)"
  t_assert_contains "${_out}" 'Unknown option: --unknown-fixture'
  t_assert_contains "${_out}" 'Usage:'
done

t_summary
