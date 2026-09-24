#!/usr/bin/env bash
# --no-push wrapper builds: Dockerfile.torch's wheels-source FROM names the
# android tag, which lives only in the containerd store that BuildKit's OCI
# worker cannot see. It must arrive as a DIRECTORY context: nerdctl maps every
# oci-layout:// context onto one fixed store id, so a second OCI context beside
# runtime_package made the android manifest unresolvable.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/runtime-wheels-fixtures.sh"
RBF="${TESTS_DIR}/../01-core/runtime-build-fns.sh"
CTX="${TESTS_DIR}/../01-core/context-management.sh"

_FNS="$(rw_fns "${RBF}" append_wrapper_build_args runtime_wheels_image_ref _append_wheels_image_args runtime_gpu_backend_pair)" || exit 1
_FNS+=$'\n'"$(rw_fns "${CTX}" runtime_use_local_artifact_context _with_throwaway_container _export_cid_wheels runtime_wheels_context_dir)" || exit 1
_STUBS='runtime_android_pin() { :; }
cross_build_host_infix() { printf hostarm64; }
cross_android_tag() { printf "repo:cross-android-hostarm64-%s" "$1"; }
runtime_stage_context_dir() { printf "%s/%s-%s" "${WORK}" "$1" "$2"; }'$'\n'"${RW_OPTIONAL_ARG_STUB}"

# A nerdctl that logs its calls; `export` streams a rootfs holding a wheelhouse
# AND an unrelated tree, or fails.
_BIN="$(rw_nerdctl_dir)"
_ROOTFS="$(rw_rootfs)"
export ROOTFS="${_ROOTFS}"

_args() {  # prints one arg per line; exit 7 = append_wrapper_build_args failed
  PATH="${_BIN}:${PATH}" bash -c "set -uo pipefail"$'\n'"${_STUBS}"$'\n'"${_FNS}"$'\n''a=(); append_wrapper_build_args a arm64 parent || exit 7; printf "%s\n" "${a[@]}"' 2>&1
}

export WORK NLOG
WORK="$(mktemp -d)"; NLOG="${WORK}/nerdctl.log"

t_case "a local artifact context hands the wheelhouse over as a directory"
_out="$(ARTIFACT_CONTEXT_ROOT=/any _args)"
t_assert_contains "${_out}" "WHEELS_IMAGE=repo:cross-android-hostarm64-arm64" "the wheels image is named"
t_assert_contains "${_out}" $'--build-context\nrepo:cross-android-hostarm64-arm64='"${WORK}/wheels-arm64" \
  "and resolved from a local directory"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -F 'oci-layout://')" \
  "never as a second oci-layout context (nerdctl gives them all one store id)"
t_assert_eq yes "$([ -f "${WORK}/wheels-arm64/opt/wheels/x.whl" ] && echo yes)" \
  "the directory holds /opt/wheels at the path the torch RUN bind-mounts"
t_assert_eq "" "$(compgen -G "${WORK}/wheels-arm64/usr")" "and nothing else of the 30 GB rootfs"
t_assert_contains "$(cat "${NLOG}")" "rm -f cid42" "the helper container is removed"

t_case "a registry run is unchanged, and a failed copy stops the wrapper"
_out="$(_args)"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -x -- '--build-context')" \
  "no local context → BuildKit resolves the tag as before"
: > "${NLOG}"
_out="$(EXPORT_FAIL=1 ARTIFACT_CONTEXT_ROOT=/any _args)"; _rc=$?
t_assert_eq 7 "${_rc}" "a wheelhouse that could not be copied must not build on"
t_assert_contains "$(cat "${NLOG}")" "rm -f cid42" "and the container is removed on that path too"

t_case "a GPU wrapper gets the GPU backend pair, an operator pin still wins"
_out="$(ENABLE_NVIDIA=true _args)"
t_assert_contains "${_out}" "ONNX_PACKAGE=onnxruntime-gpu" \
  "the CPU ORT default pruned the _gpu wheel and failed the CUDA-EP gate"
t_assert_contains "${_out}" "PYTORCH_EXTRA=pytorch-cu130" \
  "the CPU torch default failed the torch.version.cuda gate"
_out="$(ENABLE_AMD=true _args)"
t_assert_contains "${_out}" "ONNX_PACKAGE=onnxruntime-migraphx" "a rocm wrapper gets the MIGraphX ORT"
t_assert_contains "${_out}" "PYTORCH_EXTRA=pytorch-rocm71" "and the app's ROCm torch extra"
_out="$(ENABLE_NVIDIA=true PYTORCH_EXTRA=pytorch-custom ONNX_PACKAGE=onnxruntime _args)"
t_assert_contains "${_out}" "PYTORCH_EXTRA=pytorch-custom" "a pinned torch extra is kept"
t_assert_contains "${_out}" "ONNX_PACKAGE=onnxruntime" "a pinned ORT package is kept"
_out="$(_args)"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -E '^(ONNX_PACKAGE|PYTORCH_EXTRA)=')" \
  "a CPU wrapper passes neither, so the Dockerfile defaults stay authoritative"

t_case "the wrapper build acts on that failure"
t_assert_contains "$(t_fn_src "${RBF}" _runtime_build_wrapper)" \
  'append_wrapper_build_args _wrapper_build_args_out "${arch}" "${_wrapper_parent_image_out}" || return 1' \
  "an unchecked call would build on with the wrong wheels source"

t_case "the wheelhouse the venv RUN prunes is writable, and a failed prune is loud"
# Read-only, the ONNX-variant prune's rm died on EROFS behind `|| true`, and the
# GPU venv shipped onnxruntime-gpu AND onnxruntime-webgpu (measured 2026-09-21).
t_assert_contains "$(cat "${TESTS_DIR}/../../Dockerfile.torch")" \
  "--mount=type=bind,from=wheels-source,source=/opt/wheels,target=/opt/wheels,rw" \
  "the bind mount takes the writes (BuildKit discards them after the RUN)"
_PRUNE_SRC="$(t_fn_src "${TESTS_DIR}/../03-media/runtime/assemble-torch-app.sh" prune_conflicting_onnx_wheels)" || exit 1
t_assert_eq "" "$(printf '%s\n' "${_PRUNE_SRC}" | grep -F '|| true')" \
  "no rm in the prune may swallow its own failure"

t_case "a GPU venv keeps exactly ONE onnxruntime flavour"
_WH="$(mktemp -d)"
_prune() {
  rm -f "${_WH}"/*.whl
  for w in onnxruntime_dnnl-1.30.0-cp314-cp314-linux_x86_64.whl onnxruntime-1.30.0-cp314-cp314-linux_x86_64.whl \
           onnxruntime_gpu-1.30.0-cp314-cp314-linux_x86_64.whl onnxruntime_migraphx-1.30.0-cp314-cp314-linux_x86_64.whl \
           onnxruntime_webgpu-1.30.0-cp314-cp314-linux_x86_64.whl onnxruntime_genai-0.15.2-cp314-cp314-linux_x86_64.whl; do
    : > "${_WH}/${w}"; done
  ONNX_PACKAGE="$1" bash -c "${_PRUNE_SRC//\/opt\/wheels/${_WH}}"$'\nprune_conflicting_onnx_wheels'
  (cd "${_WH}" && ls | sed 's/-[0-9].*//' | sort | tr '\n' ' ')
}
t_assert_eq "onnxruntime_genai onnxruntime_gpu " "$(_prune onnxruntime-gpu)" \
  "the amd64 dnnl/CPU wheels went in beside the CUDA one (two dists, one onnxruntime/ dir)"
t_assert_eq "onnxruntime_genai onnxruntime_migraphx " "$(_prune onnxruntime-migraphx)"
rm -rf "${_WH}"

rm -rf "${WORK}" "${_BIN}" "${_ROOTFS}"
t_summary
