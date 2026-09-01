#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=linux/scripts/lib-orchestrator.sh
source "${REPO_ROOT}/linux/scripts/lib-orchestrator.sh"
runtime_flow_preamble

IMAGE_NAME="${IMAGE_NAME:-}"
PUSH_MANIFEST=0
BUILD_IMAGES=1
CREATE_MANIFEST=1
# --force overrides the per-arch wrapper generation-coherence gate below.
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

# Prove the per-arch wrapper tags are one generation before indexing them.
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
  [ "${missing}" -gt 0 ] && warn "[manifest] ${missing}/${#run_ids[@]} wrapper tag(s) carry no run-id provenance — generation unverifiable."

  # Advisory on a normal build; hard gate under --repair/--manifest-only.
  local android_stale=0
  if declare -F runtime_ancestry_assert_wrappers >/dev/null 2>&1; then
    runtime_ancestry_assert_wrappers "${TARGET_ARCHES}" || android_stale=1
  fi

  local refuse=0
  [ "${coherent}" -eq 0 ] && refuse=1
  [ "${android_stale}" -eq 1 ] && [ "${BUILD_IMAGES}" -eq 0 ] && refuse=1
  # ancestry_run_ids_coherent drops empty ids, so unverifiable provenance must REFUSE on the repair path.
  [ "${missing}" -gt 0 ] && [ "${BUILD_IMAGES}" -eq 0 ] && refuse=1

  if [ "${refuse}" -eq 0 ]; then
    log "[manifest] per-arch wrapper generation check: OK"
    return 0
  fi

  [ "${coherent}" -eq 0 ] && warn "[manifest] per-arch wrapper tags span multiple generations (run-ids: ${run_ids[*]}) — assembling ${IMAGE_NAME} would MIX releases."
  [ "${android_stale}" -eq 1 ] && [ "${BUILD_IMAGES}" -eq 0 ] && warn "[manifest] a wrapper tag predates the current android artifact (see the [ancestry] lines above)."
  [ "${missing}" -gt 0 ] && [ "${BUILD_IMAGES}" -eq 0 ] && warn "[manifest] ${missing}/${#run_ids[@]} wrapper tag(s) have no readable generation stamp, so a mixed release CANNOT be ruled out — refusing rather than assuming."

  if [ "${FORCE_MANIFEST}" -eq 1 ]; then
    warn "[manifest] --force set: assembling ${IMAGE_NAME} despite the generation mismatch above."
    return 0
  fi
  warn "[manifest] refusing to assemble ${IMAGE_NAME}. Re-run the runtime lane so every arch shares one generation, or pass --force (RUNTIME_MANIFEST_COHERENCE=0 disables this check)."
  return 1
}

# Refuse to SHRINK an already-published index. The coherence gate above asks
# whether the arches agree on a generation; it cannot ask whether they are ALL
# there. A single-arch run therefore assembles a single-arch index that is
# internally coherent, and the push replaces a 3-arch :latest-cross with a
# 1-arch one. Observed live 2026-08-31: the published index had shrunk to
# riscv64 alone. docs/refactoring-backlog.md
_manifest_completeness_gate() {
  local published published_err
  published_err="$(mktemp)" || return 1
  # A 404 means nothing is published yet — legitimately nothing to protect. ANY
  # other failure means we could not CHECK, which must not read as "safe to
  # shrink". docs/cross-build-verification.md
  if ! published="$("${NERDCTL_BIN:-nerdctl}" manifest inspect "${IMAGE_NAME}" 2>"${published_err}")"; then
    if grep -qE -e "not found|manifest unknown|MANIFEST_UNKNOWN|404" "${published_err}"; then
      rm -f "${published_err}"
      return 0
    fi
    warn "[manifest] could NOT read ${IMAGE_NAME} from the registry, so this gate cannot tell whether a push would drop an arch:"
    warn "[manifest] $(tail -1 "${published_err}" 2>/dev/null)"
    warn "[manifest] refusing rather than shrinking blind (RUNTIME_MANIFEST_COMPLETENESS=0 disables)."
    rm -f "${published_err}"
    return 1
  fi
  rm -f "${published_err}"
  # Compare SETS, not counts. Counting alone waves through a lateral swap:
  # replacing a published {riscv64} with {amd64} keeps the count at 1 and drops
  # an arch just as surely as shrinking would.
  local published_arches want_arches dropped
  published_arches="$(printf '%s\n' "${published}" \
    | sed -n 's/.*"architecture"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | LC_ALL=C sort -u)"
  want_arches="$(arch_list_to_words "${TARGET_ARCHES}" | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort -u)"
  dropped="$(LC_ALL=C comm -23 <(printf '%s\n' "${published_arches}") <(printf '%s\n' "${want_arches}") | tr '\n' ' ')"
  [ -n "${dropped// /}" ] || return 0

  warn "[manifest] ${IMAGE_NAME} is PUBLISHED with [$(printf '%s' "${published_arches}" | tr '\n' ' ')] but this run writes [${TARGET_ARCHES}]."
  warn "[manifest] pushing it would DROP: ${dropped}"
  if [ "${FORCE_MANIFEST}" -eq 1 ]; then
    warn "[manifest] --force set: shrinking ${IMAGE_NAME} anyway."
    return 0
  fi
  warn "[manifest] refusing. Re-run the runtime lane for every arch, or pass --force (RUNTIME_MANIFEST_COMPLETENESS=0 disables)."
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

  # Refuse a mixed/stale-generation index unless --force.
  if [ "${RUNTIME_MANIFEST_COHERENCE:-1}" = "1" ]; then
    _manifest_wrapper_gate || err "manifest coherence gate refused ${IMAGE_NAME} (see above; --force overrides, RUNTIME_MANIFEST_COHERENCE=0 disables)"
  fi
  if [ "${RUNTIME_MANIFEST_COMPLETENESS:-1}" = "1" ]; then
    _manifest_completeness_gate || err "manifest completeness gate refused ${IMAGE_NAME} (see above)"
  fi

  if "${NERDCTL_BIN:-nerdctl}" manifest inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
    "${NERDCTL_BIN:-nerdctl}" manifest rm "${IMAGE_NAME}" >/dev/null 2>&1 || true
  fi
  run "${NERDCTL_BIN:-nerdctl}" manifest create "${IMAGE_NAME}" "${refs[@]}"

  if [ "${PUSH_MANIFEST}" -eq 1 ]; then
    # Same transient registry/network class runtime_push_tag guards against.
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

# Register QEMU emulators for non-native target arches WITHOUT sudo: nested exec
# inside the image needs binfmt_misc F=fix-binary, which buildkit's top-level-only
# emulator does not provide. See docs/linux-cross-builds.md § Host prerequisite.
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
  verify_foreign_binfmt "${foreign}"
  _BINFMT_ENSURED=1
}

# Registration above is best-effort and its silent failure surfaces hours later
# as an output-less BuildKit step error, so prove the emulator is there and die here.
_binfmt_qemu_name() {
  case "$1" in
    arm64|aarch64) printf 'qemu-aarch64' ;;
    riscv64)       printf 'qemu-riscv64' ;;
    *)             printf 'qemu-%s' "$1" ;;
  esac
}

verify_foreign_binfmt() {
  local arches="$1" a handler missing="" tool
  tool="$(command -v containerd-rootless-setuptool.sh 2>/dev/null || true)"
  for a in $(arch_list_to_words "${arches}"); do
    handler="$(_binfmt_qemu_name "${a}")"
    # Rootful / CI hosts register in the HOST namespace (update-binfmts).
    grep -qs '^enabled' "/proc/sys/fs/binfmt_misc/${handler}" 2>/dev/null && continue
    # Rootless: the registration lives in the persistent rootlesskit namespace
    # containerd and buildkitd share, NOT in the host's own binfmt_misc.
    if [ -n "${tool}" ] && "${tool}" nsenter -- \
         grep -qs '^enabled' "/proc/sys/fs/binfmt_misc/${handler}" 2>/dev/null; then
      continue
    fi
    missing="${missing:+${missing}, }${a} (${handler})"
  done
  [ -z "${missing}" ] || err "no QEMU binfmt handler for: ${missing} -- foreign-arch wrappers are built ON the target platform, so this fails as an empty BuildKit step error hours from now. Fix first: bash linux/scripts/setup-rootless-binfmt.sh  (RUNTIME_REGISTER_BINFMT=0 skips registration entirely)"
  log "QEMU binfmt verified for: ${arches}"
}

main() {
  run_runtime_arg_loop usage _manifest_extra_arg "$@"

  if [ -z "${IMAGE_NAME}" ]; then
    err "--image is required"
  fi

  export DRY_RUN
  runtime_post_parse_setup TARGET_ARCHES "${IMAGE_NAME}"

  # One run-id for every wrapper so the coherence gate passes on a same-run push.
  : "${CROSS_RUN_ID:=runtime-$(date -u +%Y%m%d-%H%M%S)-$$}"
  export CROSS_RUN_ID

  # Resolve provenance ONCE (exported — each arch builds in a subshell).
  : "${CROSS_BUILD_DATE:=$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  : "${CROSS_VCS_REF:=$(git -C "${REPO_ROOT:-.}" rev-parse HEAD 2>/dev/null || true)}"
  export CROSS_BUILD_DATE CROSS_VCS_REF

  # CROSS_NO_PUSH=1: nothing is pushed, so a registry-based `manifest create` has
  # no descriptors and dies "no such manifest". Images are still built + smoked.
  if [ "${CROSS_NO_PUSH:-0}" = "1" ] && [ "${CREATE_MANIFEST}" -eq 1 ]; then
    log "CROSS_NO_PUSH=1 — skipping multi-arch manifest creation (no pushed per-arch refs to index)"
    CREATE_MANIFEST=0
  fi

  if [ "${BUILD_IMAGES}" -eq 1 ]; then
    log "Building ${ARTIFACT_BUILD_MODE} runtime package flow for architectures: ${TARGET_ARCHES}"
  else
    log "Creating manifest only for architectures: ${TARGET_ARCHES}"
  fi

  # Foreign-arch wrappers are built ON the target platform under QEMU, so the
  # emulators must exist BEFORE the build loop -- not merely before the smokes.
  if [ "${BUILD_IMAGES}" -eq 1 ]; then
    ensure_foreign_binfmt "${TARGET_ARCHES}"
  fi

  local arch
  if [ "${BUILD_IMAGES}" -eq 1 ]; then
    run_parallel_arch_loop runtime_build_chain "$(arch_loop_flag_prefix runtime-arch-loop-flags)" "${MAX_PARALLEL_ARCHS}" $(arch_list_to_words "${TARGET_ARCHES}")
  fi

  # GATE: boot-smoke every wrapper BEFORE the index goes live, so a broken image
  # can never ship as :latest-cross. RUNTIME_IMAGE_SMOKE=0 skips.
  if [ "${BUILD_IMAGES}" -eq 1 ] && [ "${RUNTIME_IMAGE_SMOKE:-1}" = "1" ]; then
    [ "${_BINFMT_ENSURED:-0}" = "1" ] || ensure_foreign_binfmt "${TARGET_ARCHES}"
    local smoke_script="${REPO_ROOT}/linux/scripts/06-packaging/smoke-runtime-image.sh"
    local wrapper_tag
    # Two-pass order is load-bearing: content gate for EVERY arch first, then the
    # boot smokes (docs/cross-build-verification.md § Verify the shipped BYTES).
    for arch in $(arch_list_to_words "${TARGET_ARCHES}"); do
      wrapper_tag="$(runtime_wrapper_tag "${arch}")"
      log "Wrapper content gate: ${wrapper_tag} (${arch})"
      # Pull only when MISSING: an unconditional pull re-points the tag at the
      # previously PUBLISHED image, so --no-push runs smoke the stale release.
      if ! image_exists "${NERDCTL_BIN:-nerdctl}" "${wrapper_tag}"; then
        run "${NERDCTL_BIN:-nerdctl}" pull -q "${wrapper_tag}" || true
      fi
      # Byte-gate: a stale wrapper boots green too, so assert shipped content. 0 → advisory.
      run bash "${REPO_ROOT}/linux/scripts/verify-shipped-wrapper.sh" "${wrapper_tag}" "${arch}"
    done
    for arch in $(arch_list_to_words "${TARGET_ARCHES}"); do
      wrapper_tag="$(runtime_wrapper_tag "${arch}")"
      log "Runtime-image smoke: ${wrapper_tag} (${arch})"
      if ! image_exists "${NERDCTL_BIN:-nerdctl}" "${wrapper_tag}"; then
        run "${NERDCTL_BIN:-nerdctl}" pull -q "${wrapper_tag}" || true
      fi
      run bash "${smoke_script}" "${wrapper_tag}" "${arch}"
    done
  fi

  # Publish the multi-arch manifest only after every per-arch image passed its smoke.
  if [ "${CREATE_MANIFEST}" -eq 1 ]; then
    create_manifest
    # Freshness gate: prove the index points at the per-arch tags just built.
    # Advisory by default (runs after push); MANIFEST_FRESHNESS_STRICT=1 makes it fatal.
    if [ "${MANIFEST_FRESHNESS_GATE:-1}" = "1" ] \
       && [ -x "${REPO_ROOT}/linux/scripts/verify-manifest-freshness.sh" ]; then
      if EXPECT_RUN_ID="${CROSS_RUN_ID:-}" \
         bash "${REPO_ROOT}/linux/scripts/verify-manifest-freshness.sh"; then
        log "[manifest] freshness verified: every child matches its per-arch tag and shares this run's id"
      elif [ "${MANIFEST_FRESHNESS_STRICT:-0}" = "1" ]; then
        err "[manifest] freshness check FAILED and MANIFEST_FRESHNESS_STRICT=1"
      else
        warn "[manifest] freshness check FAILED — the published index does not match this run (advisory; set MANIFEST_FRESHNESS_STRICT=1 to make this fatal)"
      fi
    fi
  fi
}

main "$@"
