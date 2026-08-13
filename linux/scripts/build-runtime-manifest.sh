#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=linux/scripts/lib-orchestrator.sh
source "${REPO_ROOT}/linux/scripts/lib-orchestrator.sh"
runtime_flow_preamble

# Script-specific defaults (override shared where needed)
IMAGE_NAME="${IMAGE_NAME:-}"
PUSH_MANIFEST=0
BUILD_IMAGES=1
CREATE_MANIFEST=1
# XC3: --force overrides the per-arch wrapper generation-coherence gate below.
FORCE_MANIFEST=0

usage() {
  cat <<'EOF'
Usage: build-runtime-manifest.sh --image IMAGE [options]

Builds the documented cross publish flow end-to-end:
1. clean per-architecture base images
2. package images that layer target-built payload from cross-android-${arch}
3. final wrapper images (includes torch venv + app + runtime scripts)
4. one multi-architecture manifest

Options:
  --image IMAGE                Final manifest image ref to build (required)
  --push-images                Push per-architecture wrapper images only
  --push-all                   Push ALL images (wrapper + base/package intermediates)
  --push-manifest              Push the final manifest after creating it
  --skip-manifest              Build images only; do not create a manifest locally
  --manifest-only              Create/push the manifest only; skip all image builds
  --repair                     Alias for --manifest-only (repair manifest from existing per-arch images)
  --force                      Assemble the manifest even if the per-arch wrapper tags
                                span multiple generations (skip the XC3 coherence gate)
  --push                       Short for --push-images --push-manifest (intermediates stay local)
  --dry-run                    Print build commands without executing them
  --parallel-archs              Build per-architecture images in parallel
  --max-parallel-archs N        Max concurrent arch builds (default: 4)
  -h, --help                   Show this help text
  --target-arches LIST          Comma-separated target list (default: amd64,arm64,riscv64)
  --architectures LIST          Alias for --target-arches
  --image-prefix TAG            Prefix for built wrapper image tags
  --artifact-image-prefix TAG   Cross tag prefix, or exact artifact image ref in native mode
  --artifact-build-mode MODE    Artifact source mode: cross or native (default: cross)
  --base-dockerfile PATH        Base Dockerfile (default: linux/Dockerfile.base)
  --package-dockerfile PATH     Package Dockerfile (default: linux/Dockerfile.package)
  --torch-dockerfile PATH       Alias for --wrapper-dockerfile (deprecated)
  --wrapper-dockerfile PATH     Final wrapper Dockerfile (default: linux/Dockerfile.torch)
  --torch-app-mode MODE         TORCH_APP_MODE for linux/Dockerfile.torch
  --fast-ubuntu-mirror          Replace Ubuntu archive/security/ports mirrors during Docker builds
  --fast-ubuntu-mirror-url URL  Archive mirror URL to use with --fast-ubuntu-mirror
  --fast-ubuntu-ports-mirror-url URL
                                 Optional mirror URL for ubuntu-ports entries

Environment overrides:
  IMAGE_NAME                   Final manifest image ref, equivalent to --image
EOF
  runtime_shared_usage_env_overrides
}

# ==============================================================================
# _manifest_wrapper_gate  (XC3 coherence + XC2 android-freshness)
#
# Before assembling the multi-arch index out of the mutable per-arch wrapper
# tags, prove they are ONE generation. The run-id annotation (stamped on each
# wrapper push, see runtime-build-fns.sh) is the coherence key: three tags from
# one run share it, so a normal same-run push passes silently. A --repair run
# over tags left mixed by a 2-of-3 build has disagreeing run-ids and is refused
# (unless --force). Tags predating the annotation only WARN (unknown provenance,
# non-breaking rollout). android-freshness (each wrapper still descends from the
# current android) is advisory on a normal build but a gate under --repair.
#
# Returns 0 to proceed, 1 to refuse. Never bites the happy path.
# ==============================================================================
_manifest_wrapper_gate() {
  local -a run_ids=()
  local arch tag rid coherent=1 missing=0 r

  for arch in $(arch_list_to_words "${TARGET_ARCHES}"); do
    tag="$(runtime_wrapper_tag "${arch}")" || return 0
    rid="$(ancestry_recorded_run_id "${tag}" 2>/dev/null || true)"
    run_ids+=("${rid}")
    [ -z "${rid}" ] && missing=$((missing + 1))
  done

  if declare -F ancestry_run_ids_coherent >/dev/null 2>&1; then
    ancestry_run_ids_coherent "${run_ids[@]}" || coherent=0
  fi
  [ "${missing}" -gt 0 ] && warn "[manifest] ${missing}/${#run_ids[@]} wrapper tag(s) carry no run-id annotation — generation provenance unverifiable (rebuild to enable the XC3 coherence gate)."

  # XC2: verify each wrapper still descends from the CURRENT android. Advisory on
  # a normal build (BUILD_IMAGES=1, wrappers were just built this run); a hard
  # gate under --repair/--manifest-only, where the mutable tags are all we have.
  local android_stale=0
  if declare -F runtime_ancestry_assert_wrappers >/dev/null 2>&1; then
    runtime_ancestry_assert_wrappers "${TARGET_ARCHES}" || android_stale=1
  fi

  local refuse=0
  [ "${coherent}" -eq 0 ] && refuse=1
  [ "${android_stale}" -eq 1 ] && [ "${BUILD_IMAGES}" -eq 0 ] && refuse=1

  if [ "${refuse}" -eq 0 ]; then
    log "[manifest] per-arch wrapper generation check: OK"
    return 0
  fi

  [ "${coherent}" -eq 0 ] && warn "[manifest] per-arch wrapper tags span multiple generations (run-ids: ${run_ids[*]}) — assembling ${IMAGE_NAME} would MIX releases."
  [ "${android_stale}" -eq 1 ] && [ "${BUILD_IMAGES}" -eq 0 ] && warn "[manifest] a wrapper tag predates the current android artifact (see the [ancestry] lines above)."

  if [ "${FORCE_MANIFEST}" -eq 1 ]; then
    warn "[manifest] --force set: assembling ${IMAGE_NAME} despite the generation mismatch above."
    return 0
  fi
  warn "[manifest] refusing to assemble ${IMAGE_NAME}. Re-run the runtime lane so every arch shares one generation, or pass --force (RUNTIME_MANIFEST_COHERENCE=0 disables this check)."
  return 1
}

create_manifest() {
  local refs=()
  local arch

  for arch in $(arch_list_to_words "${TARGET_ARCHES}"); do
    refs+=("$(runtime_wrapper_tag "${arch}")")
  done

  if is_dry_run; then
    log "[DRY RUN] would create manifest ${IMAGE_NAME} from refs: ${refs[*]}"
    return 0
  fi

  # XC2/XC3 gate: refuse a mixed/stale-generation index unless --force.
  if [ "${RUNTIME_MANIFEST_COHERENCE:-1}" = "1" ]; then
    _manifest_wrapper_gate || err "manifest coherence gate refused ${IMAGE_NAME} (see above; --force overrides, RUNTIME_MANIFEST_COHERENCE=0 disables)"
  fi

  if "${NERDCTL_BIN:-nerdctl}" manifest inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
    "${NERDCTL_BIN:-nerdctl}" manifest rm "${IMAGE_NAME}" >/dev/null 2>&1 || true
  fi
  run "${NERDCTL_BIN:-nerdctl}" manifest create "${IMAGE_NAME}" "${refs[@]}"

  if [ "${PUSH_MANIFEST}" -eq 1 ]; then
    # Retry the manifest push on the same transient registry/network class the
    # per-arch image pushes guard against (runtime_push_tag). The index blob is
    # tiny, but a dropped connection here still fails the whole stage.
    retry "${PUSH_MAX_ATTEMPTS:-4}" "${PUSH_RETRY_BASE_SECS:-15}" "manifest push ${IMAGE_NAME}" \
      run "${NERDCTL_BIN:-nerdctl}" manifest push --purge "${IMAGE_NAME}"
  fi
}

_manifest_extra_arg() {
  case "$1" in
    --image) IMAGE_NAME="$2"; _OARG_SHIFT=2 ;;
    --push-images) PUSH_IMAGES=1; _OARG_SHIFT=1 ;;
    --push-manifest) PUSH_MANIFEST=1; _OARG_SHIFT=1 ;;
    --skip-manifest) CREATE_MANIFEST=0; _OARG_SHIFT=1 ;;
    --manifest-only|--repair) BUILD_IMAGES=0; _OARG_SHIFT=1 ;;
    --force) FORCE_MANIFEST=1; _OARG_SHIFT=1 ;;
    --push) PUSH_IMAGES=1; PUSH_MANIFEST=1; _OARG_SHIFT=1 ;;
    --push-all) PUSH_IMAGES=1; PUSH_MANIFEST=1; PUSH_INTERMEDIATE_IMAGES=1; _OARG_SHIFT=1 ;;
    *) return 1 ;;
  esac
}

# Register QEMU emulators for any non-native target arch, WITHOUT sudo, so the
# foreign-arch runtime smokes can actually execute inside the image (nested exec
# of the compiler/python/ffmpeg needs binfmt_misc with the F=fix-binary flag,
# which buildkit's top-level-only emulator does NOT provide). Delegates to
# setup-rootless-binfmt.sh (rootless containerd/BuildKit nsenter path). Best-
# effort: a failure here is a warning, not a hard error — the smokes still run
# and report their own "exec format error" if emulation is genuinely missing.
ensure_foreign_binfmt() {
  local arches="$1"
  [ "${RUNTIME_REGISTER_BINFMT:-1}" = "1" ] || { log "RUNTIME_REGISTER_BINFMT=0 — skipping QEMU binfmt registration"; return 0; }
  local native foreign="" a
  native="$(arch_normalize "$(uname -m)")"
  for a in $(arch_list_to_words "${arches}"); do
    [ "$(arch_normalize "${a}")" = "${native}" ] && continue
    foreign="${foreign:+${foreign},}$(arch_normalize "${a}")"
  done
  [ -n "${foreign}" ] || return 0   # all targets are native; nothing to emulate
  local reg="${REPO_ROOT}/linux/scripts/setup-rootless-binfmt.sh"
  if [ ! -x "${reg}" ] && [ ! -f "${reg}" ]; then
    warn "setup-rootless-binfmt.sh not found — foreign-arch (${foreign}) smokes may fail with 'exec format error'"
    return 0
  fi
  log "Registering QEMU binfmt (no sudo) for foreign arches: ${foreign}"
  if ! run bash "${reg}" --arches "${foreign}"; then
    warn "no-sudo QEMU binfmt registration failed for [${foreign}] — foreign-arch smokes may report 'exec format error'."
    warn "  On a rootless host: ensure containerd-rootless-setuptool.sh is on PATH. On a rootful/CI host qemu is usually pre-registered."
  fi
}

main() {
  run_runtime_arg_loop usage _manifest_extra_arg "$@"

  if [ -z "${IMAGE_NAME}" ]; then
    err "--image is required"
  fi

  # Post-parse setup (replaces runtime_flow_export_setup)
  export DRY_RUN
  runtime_post_parse_setup TARGET_ARCHES "${IMAGE_NAME}"

  # XC3: every wrapper built in THIS process must share one run-id so the
  # coherence gate passes silently on a same-run push. The orchestrator exports a
  # canonical CROSS_RUN_ID (chain-lifecycle.sh); a standalone invocation defaults
  # its own here. Either way all three per-arch wrappers read the same value.
  : "${CROSS_RUN_ID:=runtime-$(date -u +%Y%m%d-%H%M%S)-$$}"
  export CROSS_RUN_ID

  # Belt-and-suspenders for --no-push orchestrator runs (CROSS_NO_PUSH=1): the
  # per-arch wrapper tags are never pushed, so a registry-based `nerdctl manifest
  # create` has no descriptors to reference and fails "no such manifest" at the
  # very end of an otherwise-green validation run. The orchestrator now also
  # passes --skip-manifest, but honor the exported env var directly so the guard
  # holds regardless of caller. Per-arch images are still built + boot-smoked.
  if [ "${CROSS_NO_PUSH:-0}" = "1" ] && [ "${CREATE_MANIFEST}" -eq 1 ]; then
    log "CROSS_NO_PUSH=1 — skipping multi-arch manifest creation (no pushed per-arch refs to index)"
    CREATE_MANIFEST=0
  fi

  if [ "${BUILD_IMAGES}" -eq 1 ]; then
    log "Building ${ARTIFACT_BUILD_MODE} runtime package flow for architectures: ${TARGET_ARCHES}"
  else
    log "Creating manifest only for architectures: ${TARGET_ARCHES}"
  fi

  local arch
  if [ "${BUILD_IMAGES}" -eq 1 ]; then
    run_parallel_arch_loop runtime_build_chain "$(arch_loop_flag_prefix runtime-arch-loop-flags)" "${MAX_PARALLEL_ARCHS}" $(arch_list_to_words "${TARGET_ARCHES}")
  fi

  # Host-side runtime-image boot smoke: run each freshly built wrapper via
  # nerdctl and verify it starts and its entrypoint/HEALTHCHECK/user/paths are
  # sane. Validates the ACTUAL published image, complementing the in-image
  # wrapper-smoke stage. This was COPY'd into the package image but never run
  # anywhere. Cross arches boot under binfmt/qemu; set RUNTIME_IMAGE_SMOKE=0 to
  # skip (e.g. a host without qemu for a foreign arch).
  #
  # GATE: run the smoke BEFORE creating/pushing the multi-arch manifest. The
  # per-arch wrapper tags are already pushed by the build, so the smoke can pull
  # and boot them here; a failure aborts (set -e via `run`) BEFORE the manifest
  # index goes live, so a broken image (e.g. clang != LLVM_RELEASE) can never be
  # published as :latest-cross. Previously the smoke ran after the push, which
  # reported the failure but left the bad manifest live on the registry.
  if [ "${BUILD_IMAGES}" -eq 1 ] && [ "${RUNTIME_IMAGE_SMOKE:-1}" = "1" ]; then
    # Foreign-arch runtime smokes execute inside the image under QEMU/binfmt.
    # Register the emulators up-front WITHOUT sudo (rootless containerd/BuildKit
    # share one persistent namespace; see setup-rootless-binfmt.sh). Best-effort:
    # if registration is unavailable (non-rootless host, no nsenter tool) we warn
    # and let the per-arch smokes surface "exec format error" themselves. Opt out
    # with RUNTIME_REGISTER_BINFMT=0 (e.g. host already has qemu via update-binfmts).
    ensure_foreign_binfmt "${TARGET_ARCHES}"
    local smoke_script="${REPO_ROOT}/linux/scripts/06-packaging/smoke-runtime-image.sh"
    local wrapper_tag
    for arch in $(arch_list_to_words "${TARGET_ARCHES}"); do
      wrapper_tag="$(runtime_wrapper_tag "${arch}")"
      log "Runtime-image smoke: ${wrapper_tag} (${arch})"
      # Ensure the image is present locally (the build may not have loaded it) —
      # but only pull when it is actually MISSING. The old unconditional pull
      # re-pointed the tag to the previously PUBLISHED image whenever that tag
      # exists in the registry, so a --no-push validation run smoked the stale
      # release instead of the wrapper it had just built (false green, plus a
      # multi-GB download that --no-push exists to avoid).
      if ! image_exists "${NERDCTL_BIN:-nerdctl}" "${wrapper_tag}"; then
        run "${NERDCTL_BIN:-nerdctl}" pull -q "${wrapper_tag}" || true
      fi
      run bash "${smoke_script}" "${wrapper_tag}" "${arch}"
    done
  fi

  # Only now that every per-arch image passed its boot/clang smoke do we publish
  # the multi-arch manifest.
  if [ "${CREATE_MANIFEST}" -eq 1 ]; then
    create_manifest
  fi
}

main "$@"
