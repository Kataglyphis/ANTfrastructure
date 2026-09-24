# shellcheck shell=bash
# Fixtures the two wheelhouse suites share (test-runtime-wheels-context.sh and
# test-runtime-wheels-source.sh). Sourced after test-harness.sh; defines functions only.

# Hermetic: what the wrapper path and these fixtures read but no case means to pass. The CI
# image exports ONNX_PACKAGE and PYTORCH_EXTRA, which the wrapper forwards as operator pins.
rw_hermetic_env() {
  unset ONNX_PACKAGE PYTORCH_EXTRA ENABLE_NVIDIA ENABLE_AMD TORCH_APP_MODE BUILD_TYPE \
    RUNTIME_WHEELS_SOURCE RUNTIME_WHEELS_EXPORT_ROOT RUNTIME_NO_CACHE WRAPPER_DOCKERFILE_PATH \
    PUSH_IMAGES PUSH_INTERMEDIATE_IMAGES ARTIFACT_CONTEXT_ROOT ARTIFACT_CONTEXT_MODE NERDCTL_BIN \
    DRY_RUN PIN INFIX LOCAL_DIGEST PINNED_PULLED EXPORT_FAIL EXPORT_RC EXPORT_WHEELS PACKAGE_HOOK
}

# <file> <function>... -> their sources, one after another. Returns 1 when one is gone.
rw_fns() {
  local file="$1" fn
  shift
  for fn in "$@"; do
    t_fn_src "${file}" "${fn}" || return 1
  done
}

# A directory holding a nerdctl that appends its argv to $NLOG. `create` and `export`
# fake a container of $ROOTFS (EXPORT_FAIL=1 fails the export, which streams without a
# ./ prefix like the real one); `image inspect` prints $LOCAL_DIGEST for a tag, and for
# a <repo>@<digest> ref that digest only when PINNED_PULLED=1 (the registry copy is local).
rw_nerdctl_dir() {
  local dir
  dir="$(mktemp -d)"
  cat > "${dir}/nerdctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${NLOG}"
case "$1" in
  create) echo cid42 ;;
  export) [ -n "${EXPORT_FAIL:-}" ] && exit 1; tar -cf - -C "${ROOTFS}" opt usr ;;
  image)
    ref="${*: -1}"
    case "${ref}" in
      *@sha256:*) [ -z "${PINNED_PULLED:-}" ] || printf '%s\n' "${ref##*@}" ;;
      *) printf '%s\n' "${LOCAL_DIGEST:-}" ;;
    esac ;;
esac
STUB
  chmod +x "${dir}/nerdctl"
  printf '%s' "${dir}"
}

# A rootfs holding a wheelhouse AND an unrelated tree, for that nerdctl to export.
rw_rootfs() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "${dir}/opt/wheels" "${dir}/usr/lib"
  touch "${dir}/opt/wheels/x.whl" "${dir}/usr/lib/big.so"
  printf '%s' "${dir}"
}

# The optional-arg helper append_wrapper_build_args calls, as a stub definition.
# shellcheck disable=SC2034  # read by the suites that source this file
RW_OPTIONAL_ARG_STUB='append_optional_build_arg() { local -n _o=$1; [ -n "$3" ] && _o+=(--build-arg "$2=$3"); return 0; }'
