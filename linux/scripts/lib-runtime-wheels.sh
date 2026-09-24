# shellcheck shell=bash
# lib-runtime-wheels.sh — RUNTIME_WHEELS_SOURCE: where the wrapper's torch RUN gets /opt/wheels.
#   auto, image  the android image itself, as every chain did before 2026-09-24 (default)
#   export       /opt/wheels copied out of that SAME image before each arch's package build,
#                sealed with a sha256 manifest, and handed to the wrapper as a directory
# Host-side only and outside every image closure, so editing it re-keys no stage.
# Loaded at top level by lib-orchestrator.sh. docs/linux-cross-builds.md#the-wrappers-wheelhouse-two-deliveries
# RUNTIME_WHEELS_MODE and RUNTIME_WHEELS_EXPORT_ROOT are this file's own state, set
# by runtime_wheels_setup in the main shell; append_wrapper_build_args reads the root.
[ -n "${_LIB_RUNTIME_WHEELS_SH_LOADED:-}" ] && return 0
_LIB_RUNTIME_WHEELS_SH_LOADED=1

# Prints image or export. An unknown value is rc 2, so a typo stops a lane at its start.
runtime_wheels_source_mode() {
  case "${RUNTIME_WHEELS_SOURCE:-auto}" in
    auto|image) printf '%s' image ;;
    export) printf '%s' export ;;
    *)
      printf '[ERROR] RUNTIME_WHEELS_SOURCE=%s: expected auto, image or export\n' "${RUNTIME_WHEELS_SOURCE}" >&2
      return 2
      ;;
  esac
}

# Main shell, after runtime_post_parse_setup. The export root is minted HERE: a
# $(...) or a parallel-loop worker would lose the assignment.
runtime_wheels_setup() {
  RUNTIME_WHEELS_SOURCE="${RUNTIME_WHEELS_SOURCE:-auto}"
  RUNTIME_WHEELS_EXPORT_ROOT=""
  RUNTIME_WHEELS_MODE="$(runtime_wheels_source_mode)" || return 2
  if [ "${RUNTIME_WHEELS_MODE}" = image ]; then
    log "[wheels] RUNTIME_WHEELS_SOURCE=${RUNTIME_WHEELS_SOURCE}: the torch RUN mounts /opt/wheels from the android image"
    return 0
  fi
  log "[wheels] RUNTIME_WHEELS_SOURCE=export: /opt/wheels is exported before each package build (RUNTIME_WHEELS_SOURCE=image restores the android-image mount)"
  is_dry_run && return 0
  mkdir -p "${RUNTIME_CONTEXT_ROOT}" || return 1
  # The runtime-flow.* name lets _runtime_sweep_orphaned_contexts reclaim a killed run's root.
  RUNTIME_WHEELS_EXPORT_ROOT="$(mktemp -d "${RUNTIME_CONTEXT_ROOT}/runtime-flow.wheels.XXXXXX")" || return 1
  trap_push 'runtime_wheels_cleanup'
}

runtime_wheels_cleanup() {
  if [ -n "${RUNTIME_WHEELS_EXPORT_ROOT:-}" ]; then
    rm -rf "${RUNTIME_WHEELS_EXPORT_ROOT}"
  fi
  RUNTIME_WHEELS_EXPORT_ROOT=""
}

# One arch of the runtime lane. Image mode is runtime_build_chain alone; export mode
# stages the wheelhouse first and removes it after the wrapper, on both paths.
runtime_wheels_arch_chain() {
  local arch="$1" rc=0
  if [ "${RUNTIME_WHEELS_MODE:-image}" = export ]; then
    _runtime_timed wheels-export "${arch}" runtime_wheels_export "${arch}" || rc=$?
  fi
  if [ "${rc}" -eq 0 ]; then
    runtime_build_chain "$@" || rc=$?
  fi
  runtime_wheels_discard "${arch}"
  return "${rc}"
}

runtime_wheels_discard() {
  if [ -n "${RUNTIME_WHEELS_EXPORT_ROOT:-}" ]; then
    rm -rf "${RUNTIME_WHEELS_EXPORT_ROOT:?}/$1" "${RUNTIME_WHEELS_EXPORT_ROOT:?}/$1.sha256"
  fi
  return 0
}

# Copies /opt/wheels out of the image image-mode would mount (Dockerfile.torch's
# wheels-export stage) into <root>/<arch>, then seals it. No -t, no image output.
runtime_wheels_export() {
  local arch="$1" ref dir pull="--pull=true"
  local -a args=()
  ref="$(runtime_wheels_image_ref "${arch}")"
  if is_dry_run; then
    log "[DRY RUN] would export /opt/wheels of ${ref:-the Dockerfile.torch default} for ${arch}"
    return 0
  fi
  if [ -z "${RUNTIME_WHEELS_EXPORT_ROOT:-}" ]; then
    printf '[ERROR] RUNTIME_WHEELS_SOURCE=export but runtime_wheels_setup made no export root\n' >&2
    return 1
  fi
  dir="${RUNTIME_WHEELS_EXPORT_ROOT}/${arch}"
  _runtime_wheels_source_args args "${arch}" "${ref}" || return 1
  runtime_pushes_intermediate_images || pull="--pull=false"
  rm -rf "${dir}" "${dir}.sha256"
  mkdir -p "${dir}" || return 1
  # BASE_IMAGE=scratch: the package this arch has not built yet can never be resolved here.
  # shellcheck disable=SC2086  # intentional: empty RUNTIME_NO_CACHE must vanish
  run_nerdctl_build "${NERDCTL_BIN:-nerdctl}" \
    "${pull}" \
    ${RUNTIME_NO_CACHE:+--no-cache} \
    --platform "linux/${arch}" \
    --target wheels-export \
    --output "type=local,dest=${dir}" \
    -f "${WRAPPER_DOCKERFILE_PATH:-linux/Dockerfile.torch}" \
    --build-arg BASE_IMAGE=scratch \
    "${args[@]}" \
    . || return 1
  _runtime_wheels_seal "${arch}" "${ref}"
}

# <nameref> <arch> <ref>: the export build reads exactly what image mode mounts. Under
# ARTIFACT_CONTEXT_ROOT a containerd-only ref arrives as the android layout, proved by digest.
_runtime_wheels_source_args() {
  local -n _rwsa_out=$1
  local arch="$2" ref="$3" ctx have want
  [ -n "${ref}" ] || return 0
  if ! runtime_use_local_artifact_context; then
    _rwsa_out+=(--build-arg "WHEELS_IMAGE=${ref}")
    return 0
  fi
  if [ "${ARTIFACT_CONTEXT_MODE:-oci}" != oci ]; then
    printf '[ERROR] RUNTIME_WHEELS_SOURCE=export needs ARTIFACT_CONTEXT_MODE=oci to prove the layout is %s; use RUNTIME_WHEELS_SOURCE=image\n' "${ref}" >&2
    return 1
  fi
  ctx="$(runtime_artifact_context_ref "${arch}" oci)" || return 1
  have="$(_runtime_wheels_layout_digest "${ctx#oci-layout://}")"
  want="$(_runtime_wheels_local_digest "${ref}")"
  if [ -z "${have}" ] || [ "${have}" != "${want}" ]; then
    printf '[ERROR] RUNTIME_WHEELS_SOURCE=export: the android layout %s holds %s, but %s is %s in containerd; exporting it would change where the wheels come from. Use RUNTIME_WHEELS_SOURCE=image.\n' \
      "${ctx#oci-layout://}" "${have:-no single manifest}" "${ref}" "${want:-not present}" >&2
    return 1
  fi
  _rwsa_out+=(--build-arg "WHEELS_IMAGE=runtime_artifact" --build-context "runtime_artifact=${ctx}")
}

# The one manifest digest an OCI layout's index.json names; empty for none or several.
_runtime_wheels_layout_digest() {
  local d
  d="$(grep -Eo '"digest": *"sha256:[0-9a-f]{64}"' "$1/index.json" 2>/dev/null | grep -Eo 'sha256:[0-9a-f]{64}' || true)"
  [ "$(printf '%s\n' "${d}" | grep -c 'sha256:' || true)" = 1 ] || return 0
  printf '%s' "${d}"
}

_runtime_wheels_local_digest() {
  "${NERDCTL_BIN:-nerdctl}" image inspect --mode=native --format '{{.Image.Target.Digest}}' "$1" 2>/dev/null \
    | sort -u || true
}

# <arch> <ref>: an export without a wheel is an error; otherwise record the manifest
# the wrapper build re-checks, beside the context rather than inside it.
_runtime_wheels_seal() {
  local arch="$1" ref="$2" dir="${RUNTIME_WHEELS_EXPORT_ROOT}/$1"
  if ! compgen -G "${dir}/opt/wheels/*.whl" >/dev/null; then
    printf '[ERROR] RUNTIME_WHEELS_SOURCE=export: no wheel in %s/opt/wheels, exported from %s\n' \
      "${dir}" "${ref:-the Dockerfile.torch default}" >&2
    return 1
  fi
  _runtime_wheels_manifest "${dir}/opt/wheels" > "${dir}.sha256" || return 1
  log "[wheels] ${arch}: $(runtime_wheels_digest_line "${dir}/opt/wheels") (exported from ${ref:-the Dockerfile.torch default})"
}

# append_wrapper_build_args' export arm: the staged directory, re-verified byte for byte,
# and nothing else. A missing or changed wheelhouse fails; there is no fallback to image.
runtime_wheels_wrapper_args() {
  local -n _rwwa_out=$1
  local arch="$2" dir="${RUNTIME_WHEELS_EXPORT_ROOT}/$2"
  if [ ! -s "${dir}.sha256" ] || ! _runtime_wheels_manifest "${dir}/opt/wheels" 2>/dev/null | cmp -s - "${dir}.sha256"; then
    printf '[ERROR] RUNTIME_WHEELS_SOURCE=export: the wheelhouse staged for %s at %s is missing or changed since its export; rerun, or use RUNTIME_WHEELS_SOURCE=image\n' \
      "${arch}" "${dir}" >&2
    return 1
  fi
  _rwwa_out+=(--build-arg "WHEELS_IMAGE=runtime_wheels" --build-context "runtime_wheels=${dir}")
}

# "<sha256>  ./<path>" for every file, sorted: the seal, and what the digest hashes. The awk
# fixes the separator, which is " *" on a binary-mode sha256sum.
_runtime_wheels_manifest() {
  (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum | awk '{print substr($0, 1, 64) "  " substr($0, 67)}')
}

# files=N bytes=B sha256=D. setup-torch-venv.sh prints the same line inside the torch
# RUN, so the two modes' wheelhouses compare by eye. docs/cross-build-verification.md#measuring-the-torch-runs-wait-before-uv-venv
runtime_wheels_digest_line() {
  local counts digest
  counts="$(find "$1" -type f -printf '%s\n' | awk '{n++; s+=$1} END {printf "files=%d bytes=%d", n, s}')" || return 1
  digest="$(_runtime_wheels_manifest "$1" | sha256sum)" || return 1
  printf '%s sha256=%s' "${counts}" "${digest%% *}"
}
