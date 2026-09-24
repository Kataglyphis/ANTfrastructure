# shellcheck shell=bash
# Fixtures the two wheelhouse suites share (test-runtime-wheels-context.sh and
# test-runtime-wheels-source.sh). Sourced after test-harness.sh; defines functions only.

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
# ./ prefix like the real one); `image inspect` prints $LOCAL_DIGEST.
rw_nerdctl_dir() {
  local dir
  dir="$(mktemp -d)"
  cat > "${dir}/nerdctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${NLOG}"
case "$1" in
  create) echo cid42 ;;
  export) [ -n "${EXPORT_FAIL:-}" ] && exit 1; tar -cf - -C "${ROOTFS}" opt usr ;;
  image) printf '%s\n' "${LOCAL_DIGEST:-}" ;;
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
