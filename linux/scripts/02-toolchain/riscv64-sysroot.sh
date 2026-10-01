#!/usr/bin/env bash
# Builds the riscv64 cross sysroot from the family image's riscv64 child. See docs/riscv64-cross-test-lanes.md#the-building-blocks-measured-2026-10-01
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Merged-usr links, the loader, the toolchain runtime and the media prefixes; ld.so.cache resolves them under QEMU.
RISCV64_SYSROOT_PATHS=(
  bin lib sbin
  usr/lib/riscv64-linux-gnu usr/lib/ld-linux-riscv64-lp64d.so.1 usr/lib/gcc
  usr/include usr/share/pkgconfig usr/share/vulkan
  usr/local/lib usr/local/include
  opt/gcc-16.2.0 opt/gstreamer opt/opencv5 opt/vulkan opt/libcamera opt/ffmpeg
  etc/ld.so.cache etc/ld.so.conf etc/ld.so.conf.d etc/alternatives
)

usage() {
  cat <<'EOF'
Usage: riscv64-sysroot.sh --dest DIR [--image REF] [--engine docker|nerdctl] [--extra-path PATH]... [--remove-image]

Exports the riscv64 child of REF's image index into DIR as a cross sysroot:
an allowlist of paths, every absolute symlink made relative so the tree works
at any mount point. REF defaults to the family CI image (ci-image-ref.sh); when
REF is pulled locally its recorded index digest is used, so the sysroot matches
the amd64 image the lane runs in. --remove-image deletes the riscv64 image
afterwards (a CI runner's disk); without it a local store keeps its copy.
EOF
}

die() { printf 'riscv64-sysroot.sh: %s\n' "$*" >&2; exit 1; }

# An absolute link target would resolve against the build container's own root.
relativize_symlinks() {
  local root="$1" link target
  while IFS= read -r -d '' link; do
    target="$(readlink "${link}")"
    ln -sfn "$(realpath -s -m --relative-to="$(dirname "${link}")" "${root}${target}")" "${link}"
  done < <(find "${root}" -type l -lname '/*' -print0)
}

# Prefers the digest the local tag was pulled from: a later push to the tag must not skew the pair.
resolve_index_ref() {
  local engine="$1" ref="$2" repo digest
  repo="${ref%@*}"; repo="${repo%:*}"
  case "${ref}" in *@sha256:*) printf '%s' "${ref}"; return 0 ;; esac
  digest="$("${engine}" image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${ref}" 2>/dev/null \
    | sed -n "s|^${repo}@||p" | head -n 1 || true)"
  if [ -n "${digest}" ]; then printf '%s@%s' "${repo}" "${digest}"; else printf '%s' "${ref}"; fi
}

parse_args() {
  DEST="" IMAGE="" ENGINE="" EXTRA_PATHS=() REMOVE_IMAGE=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dest) DEST="${2:?--dest needs a value}"; shift 2 ;;
      --image) IMAGE="${2:?--image needs a value}"; shift 2 ;;
      --engine) ENGINE="${2:?--engine needs a value}"; shift 2 ;;
      --extra-path) EXTRA_PATHS+=("${2:?--extra-path needs a value}"); shift 2 ;;
      --remove-image) REMOVE_IMAGE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
  done
  [ -n "${DEST}" ] || { usage >&2; die "--dest is required"; }
}

# export_child <engine> <repo@digest> <dest>: the allowlist of one image's filesystem into dest.
export_child() {
  local engine="$1" ref="$2" dest="$3" container rc=0
  "${engine}" pull --platform linux/riscv64 "${ref}"
  container="$("${engine}" create --platform linux/riscv64 "${ref}" true)"
  rm -rf "${dest}"
  mkdir -p "${dest}"
  "${engine}" export "${container}" \
    | tar -x -C "${dest}" --no-same-owner "${RISCV64_SYSROOT_PATHS[@]}" "${EXTRA_PATHS[@]}" || rc=$?
  "${engine}" rm -f "${container}" >/dev/null || true
  if [ "${REMOVE_IMAGE}" -eq 1 ]; then "${engine}" rmi "${ref}" >/dev/null || true; fi
  [ "${rc}" -eq 0 ] || die "export of ${ref} failed (rc=${rc}); a missing path means the image contract moved"
}

main() {
  local index_ref repo child
  parse_args "$@"
  [ -n "${IMAGE}" ] || IMAGE="$(bash "${SCRIPT_DIR}/../ci-image-ref.sh" linux)"
  if [ -z "${ENGINE}" ]; then
    if command -v docker >/dev/null 2>&1; then ENGINE=docker; else ENGINE=nerdctl; fi
  fi
  command -v "${ENGINE}" >/dev/null 2>&1 || die "container engine not found: ${ENGINE}"

  index_ref="$(resolve_index_ref "${ENGINE}" "${IMAGE}")"
  repo="${index_ref%@*}"; repo="${repo%:*}"
  child="$(python3 "${SCRIPT_DIR}/registry-platform-digest.py" "${index_ref}" linux/riscv64)" \
    || die "no linux/riscv64 manifest in ${index_ref}"
  printf 'riscv64 sysroot: %s -> %s@%s\n' "${index_ref}" "${repo}" "${child}"

  export_child "${ENGINE}" "${repo}@${child}" "${DEST}"
  relativize_symlinks "${DEST}"
  [ -e "${DEST}/lib/ld-linux-riscv64-lp64d.so.1" ] || die "no riscv64 loader in ${DEST}"
  printf 'index=%s\nriscv64=%s@%s\n' "${index_ref}" "${repo}" "${child}" > "${DEST}/.riscv64-sysroot"
  du -sh "${DEST}"
}

# Sourcing exposes the helpers to the suite without running main.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
