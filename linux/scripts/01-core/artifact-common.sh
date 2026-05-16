#!/usr/bin/env bash

canonical_target_arch() {
  case "$1" in
    amd64|x86_64) printf '%s' "amd64" ;;
    arm64|aarch64) printf '%s' "arm64" ;;
    riscv64|riscv|rv64*) printf '%s' "riscv64" ;;
    *) return 1 ;;
  esac
}

normalize_target_arches() {
  local raw_arches="$1"
  local raw_arch normalized_arch
  local -a normalized_arches=()

  for raw_arch in ${raw_arches//,/ }; do
    normalized_arch="$(canonical_target_arch "${raw_arch}")" || {
      printf '[ERROR] Unsupported target architecture: %s\n' "${raw_arch}" >&2
      return 1
    }
    normalized_arches+=("${normalized_arch}")
  done

  if [ "${#normalized_arches[@]}" -eq 0 ]; then
    printf '[ERROR] At least one target architecture is required\n' >&2
    return 1
  fi

  printf '%s' "${normalized_arches[*]}" | tr ' ' ','
}

log() {
  printf '[INFO] %s\n' "$*"
}

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  "$@"
}

export_rootfs_from_image() {
  local nerdctl_bin="$1"
  local tag="$2"
  local artifact_dir="$3"
  shift 3

  local rootfs_dir="${artifact_dir}/rootfs"
  local cid=""

  rm -rf "${artifact_dir}"
  mkdir -p "${rootfs_dir}"

  cid="$("${nerdctl_bin}" create "${tag}" /bin/true)"
  cleanup_container() {
    if [ -n "${cid}" ]; then
      "${nerdctl_bin}" rm -f "${cid}" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup_container RETURN

  "${nerdctl_bin}" export "${cid}" | tar -xpf - -C "${rootfs_dir}"

  if [ "$#" -gt 0 ]; then
    : > "${artifact_dir}/artifact.env"
    while [ "$#" -gt 0 ]; do
      printf '%s\n' "$1" >> "${artifact_dir}/artifact.env"
      shift
    done
  fi

  cleanup_container
  trap - RETURN
}
