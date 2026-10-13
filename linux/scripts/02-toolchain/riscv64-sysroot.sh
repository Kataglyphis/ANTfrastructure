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
Usage: riscv64-sysroot.sh --dest DIR [--image REF] [--engine docker|nerdctl] [--mode export|skopeo]
                          [--extra-path PATH]... [--remove-image]

Exports the riscv64 child of REF's image index into DIR as a cross sysroot:
an allowlist of paths, every absolute symlink made relative so the tree works
at any mount point. REF defaults to the family CI image (ci-image-ref.sh); when
REF is pulled locally its recorded index digest is used, so the sysroot matches
the amd64 image the lane runs in.

--mode export (the default) pulls the child into the engine and pipes its
`export` through tar; --remove-image then deletes it (a CI runner's disk).
--mode skopeo fetches only the child's layer blobs from the registry and
applies them with oci-layers-extract.py: no engine pull, no export.
RISCV64_SYSROOT_SKOPEO names another skopeo binary.
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
  DEST="" IMAGE="" ENGINE="" MODE=export EXTRA_PATHS=() REMOVE_IMAGE=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dest) DEST="${2:?--dest needs a value}"; shift 2 ;;
      --image) IMAGE="${2:?--image needs a value}"; shift 2 ;;
      --engine) ENGINE="${2:?--engine needs a value}"; shift 2 ;;
      --mode) MODE="${2:?--mode needs a value}"; shift 2 ;;
      --extra-path) EXTRA_PATHS+=("${2:?--extra-path needs a value}"); shift 2 ;;
      --remove-image) REMOVE_IMAGE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
  done
  [ -n "${DEST}" ] || { usage >&2; die "--dest is required"; }
  case "${MODE}" in
    export | skopeo) ;;
    *) usage >&2; die "--mode must be export or skopeo, got: ${MODE}" ;;
  esac
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

# skopeo_child <repo@digest> <dest>: the allowlist from the child's layer blobs, fetched without an engine pull.
skopeo_child() {
  local ref="$1" dest="$2" skopeo="${RISCV64_SYSROOT_SKOPEO:-skopeo}" layout="${2}.layout" rc=0 start="${SECONDS}" help
  local -a parallel=()
  command -v "${skopeo}" >/dev/null 2>&1 || die "skopeo not found (${skopeo}); use --mode export on a host without it"
  rm -rf "${layout}" "${dest}"
  # Six blobs at a time, the default, queued the 2.4 GB layer behind small ones: 99 s for 8.5 GB on a runner.
  help="$("${skopeo}" copy --help 2>/dev/null || true)"
  case "${help}" in *--image-parallel-copies*) parallel=(--image-parallel-copies 24) ;; esac
  # The digest pin, which skopeo verifies blob by blob, is the trust anchor; a host without containers-common has no policy.json.
  "${skopeo}" --insecure-policy copy --retry-times 3 "${parallel[@]}" "docker://${ref}" "dir:${layout}" || rc=$?
  printf 'riscv64 sysroot: skopeo copy rc=%s in %ss\n' "${rc}" "$((SECONDS - start))"
  if [ "${rc}" -eq 0 ]; then
    python3 -I "${SCRIPT_DIR}/oci-layers-extract.py" --layout "${layout}" --dest "${dest}" --delete-blobs \
      "${RISCV64_SYSROOT_PATHS[@]}" "${EXTRA_PATHS[@]}" || rc=$?
  fi
  rm -rf "${layout}"
  [ "${rc}" -eq 0 ] || die "skopeo fetch or extract of ${ref} failed (rc=${rc}); a missing path means the image contract moved"
}

main() {
  local index_ref repo child start="${SECONDS}"
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
  printf 'riscv64 sysroot: %s -> %s@%s (%s)\n' "${index_ref}" "${repo}" "${child}" "${MODE}"

  if [ "${MODE}" = skopeo ]; then
    skopeo_child "${repo}@${child}" "${DEST}"
  else
    export_child "${ENGINE}" "${repo}@${child}" "${DEST}"
  fi
  relativize_symlinks "${DEST}"
  [ -e "${DEST}/lib/ld-linux-riscv64-lp64d.so.1" ] || die "no riscv64 loader in ${DEST}"
  printf 'index=%s\nriscv64=%s@%s\nmode=%s\n' "${index_ref}" "${repo}" "${child}" "${MODE}" > "${DEST}/.riscv64-sysroot"
  du -sh "${DEST}"
  printf 'riscv64 sysroot: %s mode in %ss\n' "${MODE}" "$((SECONDS - start))"
}

# Sourcing exposes the helpers to the suite without running main.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
