# shellcheck shell=bash
# runtime-build-fns.sh
# Per-architecture image build functions for the runtime packaging chain.
# Sourced by artifact-common.sh — do not source this directly.
#
# Provides:
#   runtime_build_base_image
#   runtime_build_package_image
#   runtime_build_wrapper_image
#   runtime_build_wrapper_rootfs
#   runtime_build_chain
#   runtime_write_artifact_metadata
#
# Depends on functions defined in artifact-common.sh:
#   append_common_build_args, run_nerdctl_build, run, image_exists,
#   export_image_to_oci_layout, export_image_rootfs_dir,
#   remove_local_image_if_exists, runtime_*_tag(), runtime_artifact_*,
#   runtime_stage_context_*, runtime_use_local_*, etc.

# Post-build: export to OCI layout locally, or push remotely, then clean up.
# Push a built runtime image tag, retrying on transient registry/network
# failures. A ~8GiB wrapper push over a throttled link can reset mid-transfer
# ("use of closed network connection: Put .../blobs/upload/..."); without a
# retry that discards the whole runtime stage -- and pre-fix, exited the entire
# chain run after hours of work. Bounded by PUSH_MAX_ATTEMPTS (default 4) with
# PUSH_RETRY_BASE_SECS (default 15s) between attempts. Pure network op, so any
# failure is retried up to the cap (a genuine auth/config error just exhausts it
# in <1min); the image layers are already built, only the upload repeats.
runtime_push_tag() {
  local tag="$1"
  retry "${PUSH_MAX_ATTEMPTS:-4}" "${PUSH_RETRY_BASE_SECS:-15}" "push ${tag}" \
    run "${NERDCTL_BIN:-nerdctl}" push "${tag}"
}

# XC2: the immutable android artifact digest for <arch>, threaded from the cross
# orchestrator as RUNTIME_ANDROID_PIN_<arch> (see runtime_android_pin_varname).
# Empty for a standalone/--repair helper run, which then falls back to the
# mutable cross-android tag. Used both as the ARTIFACT_IMAGE the package copies
# from AND as the parent-digest annotation recorded on the package/wrapper push.
runtime_android_pin() {
  local arch="$1" var
  var="$(runtime_android_pin_varname "${arch}")"
  printf '%s' "${!var:-}"
}

# XC2/XC3: compose the buildkit image-exporter spec for a runtime build, folding
# in the ancestry annotations (parent-digest/parent-stage + run-id) so the pushed
# wrapper/package manifest carries its provenance. Reduces to a plain
# `type=image,name=<tag>` (equivalent to `-t <tag>`) when ancestry.sh is absent
# or nothing is recordable, so it is always safe to use in place of -t. The
# annotations ride the manifest that runtime_push_tag later pushes; on a locally
# exported (unpushed) image they simply travel with — and are discarded with — it.
runtime_image_output_arg() {
  local tag="$1" parent_pin="${2:-}" parent_stage="${3:-}" run_id="${4:-}"
  local ann=""
  if declare -F ancestry_output_annotations >/dev/null 2>&1; then
    ann+="$(ancestry_output_annotations "${parent_pin}" "${parent_stage}")"
  fi
  if declare -F ancestry_run_id_annotation >/dev/null 2>&1; then
    ann+="$(ancestry_run_id_annotation "${run_id}")"
  fi
  printf 'type=image,name=%s%s' "${tag}" "${ann}"
}

# Append the image target for a runtime build to the nameref array.
#
# RTCACHE3 (root cause of the 2026-08-14 stale-ship saga): this used to emit the
# annotated `--output type=image,name=<tag>,annotation.*` exporter on the push
# path, on the assumption (see the now-corrected runtime_image_output_arg note)
# that it was "equivalent to -t <tag>". It is NOT. Verified with a minimal
# busybox repro on this rootless nerdctl+containerd host:
#     nerdctl build --output type=image,name=X   → X is NOT in the local image store
#     nerdctl build -t X                          → X IS in the local image store
# The exporter builds the image into buildkit's content store but never lands a
# local containerd tag. So the freshly built wrapper was invisible: the
# subsequent `nerdctl push <tag>` (runtime_push_tag) and `nerdctl manifest
# create <tag>` both resolved the STALE pre-existing local tag from an earlier
# run, and :latest-cross shipped byte-identical every time (amd64 stuck at
# 35c1f1df across five rebuilds). The annotations never reached the registry
# either — every run logged "wrapper tag(s) carry no run-id annotation …
# provenance unverifiable" — so nothing of value is lost by dropping the
# exporter. Use plain `-t` on BOTH paths: it reliably creates AND overwrites the
# local tag, which is what runtime_push_tag + the manifest step consume.
# (Re-embedding ancestry provenance via a locally-tagging method is tracked
# separately; correctness of the shipped bytes comes first.)
append_runtime_image_output() {
  local -n _ario_out=$1
  local tag="$2"
  # Arg 3 (will_push) is accepted for call-site compatibility and deliberately
  # unused: labels are free on the -t path, so provenance is stamped whether or
  # not this image gets pushed.
  local parent_pin="${4:-}" parent_stage="${5:-}"

  _ario_out+=(-t "${tag}")

  # XC3-INERT fix (2026-08-23): args 4-5 used to be dropped on the floor, so
  # every runtime image shipped WITHOUT provenance and the XC2/XC3 gates could
  # never fail — wave-5 logged "3/3 wrapper tag(s) carry no run-id annotation"
  # and still shipped a manifest mixing two source revisions. Annotations can't
  # come back (RTCACHE3: the exporter that carries them doesn't tag locally),
  # but LABELS ride the image config through `-t` and the later push, so stamp
  # them here — this helper is the choke point for both live call sites
  # (package + wrapper). CROSS_RUN_ID is exported by the orchestrator
  # (chain-lifecycle.sh) and self-defaults in build-runtime-manifest.sh.
  if declare -F ancestry_label_args >/dev/null 2>&1; then
    ancestry_label_args _ario_out "${parent_pin}" "${parent_stage}" "${CROSS_RUN_ID:-}"
  fi
}

_runtime_finish_stage() {
  local kind="$1"
  local arch="$2"
  local tag="$3"
  local parent_kind="${4:-}"

  if runtime_use_local_stage_context_outputs; then
    local context_dir
    context_dir="$(runtime_stage_context_dir "${kind}" "${arch}")"
    # rc propagation, same rule as _export_container_rootfs further below: this
    # runs under run_parallel_arch_loop, which DISABLES errexit for the whole
    # call tree, so a failure must be RETURNED. Unguarded, a ~27GB
    # `nerdctl save | tar -x` dying on ENOSPC was reported as a SUCCESSFUL
    # package build -- and the very next line deleted the only remaining copy
    # of the image. The wrapper then failed hours later on a truncated
    # oci-layout build-context, real cause long scrolled away. Found 2026-08-27.
    export_image_to_oci_layout "${NERDCTL_BIN:-nerdctl}" "${tag}" "${context_dir}" || return 1
    remove_local_image_if_exists "${NERDCTL_BIN:-nerdctl}" "${tag}"
  else
    if runtime_pushes_intermediate_images; then
      runtime_push_tag "${tag}"
    fi
    if [ "${kind}" != "wrapper" ] || ! runtime_pushes_wrapper_images; then
      runtime_refresh_stage_context "${kind}" "${arch}" "${tag}"
    fi
  fi

  if [ -n "${parent_kind}" ]; then
    runtime_remove_stage_context "${parent_kind}" "${arch}"
  fi
}

runtime_build_base_image() {
  local arch="$1"
  local tag context_dir
  local -a build_args=()

  tag="$(runtime_base_tag "${arch}")"
  append_common_build_args build_args
  append_runtime_base_parent_build_arg build_args

  if is_dry_run; then
    log "[DRY RUN] would build base image ${tag} (platform linux/${arch})"
    return 0
  fi

  # rc propagation: this runs under a disabled-errexit extent (see
  # runtime_build_chain) — failures must be RETURNED, not assumed fatal.
  run_nerdctl_build "${NERDCTL_BIN:-nerdctl}" \
    --pull=true \
    --platform "linux/${arch}" \
    -t "${tag}" \
    -f "${BASE_DOCKERFILE_PATH}" \
    "${build_args[@]}" \
    . || return 1

  if runtime_use_local_stage_context_outputs; then
    context_dir="$(runtime_stage_context_dir base "${arch}")"
    _export_container_rootfs "${NERDCTL_BIN:-nerdctl}" "${tag}" "${context_dir}" || return 1
    remove_local_image_if_exists "${NERDCTL_BIN:-nerdctl}" "${tag}"
    return 0
  fi

  if runtime_pushes_intermediate_images; then
    runtime_push_tag "${tag}"
  fi

  runtime_refresh_stage_context base "${arch}" "${tag}"
}

# ── Per-stage build-arg assembly helpers ──────────────────────────────────────
# DRY the inline --build-arg strings that are repeated across runtime_build_package_image
# and _runtime_build_wrapper.  Use append_common_build_args first, then call these.
#
# Usage:
#   append_package_build_args <nameref> <arch> <parent_image> <artifact_image> <package_base_stage>
#   append_wrapper_build_args <nameref> <arch> <parent_image>
append_package_build_args() {
  local -n _apba_out=$1
  local arch="$2" parent_image="$3" artifact_image="$4" package_base_stage="$5"
  _apba_out+=(
    --build-arg "BASE_IMAGE=${parent_image}"
    --build-arg "ARTIFACT_IMAGE=${artifact_image}"
    --build-arg "PACKAGE_BASE_STAGE=${package_base_stage}"
    --build-arg "ARTIFACT_PLATFORM=$(runtime_artifact_platform "${arch}")"
    --build-arg "BUILD_MODE=${ARTIFACT_BUILD_MODE}"
    --build-arg "TARGET_ARCH=${arch}"
  )
}

append_wrapper_build_args() {
  local -n _awba_out=$1
  local arch="$2" parent_image="$3"
  # PROV1 (2026-08-17): fill the OCI provenance labels. Dockerfile.torch
  # declares ARG BUILD_DATE=""/VCS_REF="" for its org.opencontainers.image.
  # created/.revision labels, but nothing ever passed them → every shipped
  # wrapper carried EMPTY provenance (the concrete half of the RTCACHE3
  # provenance follow-up). Best-effort: outside a git checkout VCS_REF stays "".
  local _prov_date _prov_ref
  _prov_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _prov_ref="$(git -C "${REPO_ROOT:-.}" rev-parse HEAD 2>/dev/null || true)"
  # AP3 (2026-08-18): the wheelhouse is bind-mounted into Dockerfile.torch's
  # venv RUN from a wheels-source stage instead of being baked into package —
  # pass the digest-pinned android ref (the wrapper's registry-resident
  # cross-lane ancestor, same pin XC2/XC3 stamp into the manifest).
  local _wheels_image
  _wheels_image="$(runtime_android_pin "${arch}")"
  _awba_out+=(
    --build-arg "BASE_IMAGE=${parent_image}"
    --build-arg "BUILD_MODE=native"
    --build-arg "TARGET_ARCH=${arch}"
    --build-arg "TORCH_APP_MODE=${TORCH_APP_MODE:-all}"
    --build-arg "BUILD_TYPE=${BUILD_TYPE:-Release}"
    --build-arg "BUILD_DATE=${_prov_date}"
    --build-arg "VCS_REF=${_prov_ref}"
  )
  [ -n "${_wheels_image}" ] && _awba_out+=(--build-arg "WHEELS_IMAGE=${_wheels_image}")
  # Documented operator overrides (see runtime_shared_usage_env_overrides);
  # forwarded only when set so the Dockerfile.torch defaults stay authoritative.
  append_optional_build_arg _awba_out ONNX_PACKAGE "${ONNX_PACKAGE:-}"
  append_optional_build_arg _awba_out PYTORCH_EXTRA "${PYTORCH_EXTRA:-}"
}

runtime_build_package_image() {
  local arch="$1"
  local tag parent_image parent_context_dir
  local artifact_image artifact_context_ref artifact_context_mode package_base_stage
  local -a build_args=()

  tag="$(runtime_package_tag "${arch}")"
  append_common_build_args build_args
  append_runtime_accelerator_build_args build_args

  # XC2: prefer the immutable android digest (threaded from the orchestrator) as
  # the artifact the package copies from; falls back to the mutable tag when no
  # pin was threaded (standalone/--repair run).
  local _android_pin
  _android_pin="$(runtime_android_pin "${arch}")"

  if runtime_use_local_artifact_context; then
    artifact_context_mode="${ARTIFACT_CONTEXT_MODE:-oci}"
    artifact_context_ref="$(runtime_artifact_context_ref "${arch}" "${artifact_context_mode}")"
    artifact_image="runtime_artifact"
    package_base_stage="package-image"
    build_args+=(--build-context "runtime_artifact=${artifact_context_ref}")
  else
    artifact_image="$(runtime_artifact_image_ref "${arch}")"
    [ -n "${_android_pin}" ] && artifact_image="${_android_pin}"
    package_base_stage="package-image"
  fi

  _runtime_resolve_parent_context base "${arch}" parent_image parent_context_dir build_args

  if is_dry_run; then
    log "[DRY RUN] would build package image ${tag} (platform linux/${arch})"
    return 0
  fi

  append_package_build_args build_args "${arch}" "${parent_image}" "${artifact_image}" "${package_base_stage}"

  local _rb_pull="--pull=true"
  runtime_pushes_intermediate_images || _rb_pull="--pull=false"
  # Record the android parent-digest annotation only when the package is pushed
  # (intermediate push); the local stage-context path keeps a plain `-t`.
  local _pkg_push=0
  runtime_pushes_intermediate_images && _pkg_push=1
  local -a _pkg_out=()
  append_runtime_image_output _pkg_out "${tag}" "${_pkg_push}" "${_android_pin}" android
  # RTCACHE2: the package re-materializes /opt/ffmpeg via `COPY --from=android`.
  # BuildKit's worker cache can serve a STALE copy layer from a prior run even
  # when the android artifact-source digest changed (observed 2026-08-14: a
  # media→android→runtime rebuild that dropped ffmpeg's libtensorflow shipped a
  # byte-identical wrapper because the package/wrapper fully cache-hit the 3-day
  # -old layers). RUNTIME_NO_CACHE=1 forces a clean re-evaluation so the fresh
  # artifact-source content actually lands. Unquoted: empty → no word.
  # shellcheck disable=SC2086  # intentional: empty RUNTIME_NO_CACHE must vanish
  run_nerdctl_build "${NERDCTL_BIN:-nerdctl}" \
    "${_rb_pull}" \
    ${RUNTIME_NO_CACHE:+--no-cache} \
    --platform "linux/${arch}" \
    --target "${PACKAGE_DOCKERFILE_TARGET:-package}" \
    "${_pkg_out[@]}" \
    -f "${PACKAGE_DOCKERFILE_PATH}" \
    "${build_args[@]}" \
    . || return 1

  _runtime_finish_stage package "${arch}" "${tag}" base
}

_runtime_build_wrapper() {
  local arch="$1"
  local -n _wrapper_tag_out=$2
  local -n _wrapper_parent_image_out=$3
  local -n _wrapper_build_args_out=$4

  _wrapper_tag_out="$(runtime_wrapper_tag "${arch}")"
  append_common_build_args _wrapper_build_args_out
  append_runtime_accelerator_build_args _wrapper_build_args_out

  local parent_context_dir
  _runtime_resolve_parent_context package "${arch}" _wrapper_parent_image_out parent_context_dir _wrapper_build_args_out

  if is_dry_run; then
    log "[DRY RUN] would build wrapper image ${_wrapper_tag_out} (platform linux/${arch})"
    return 0
  fi

  append_wrapper_build_args _wrapper_build_args_out "${arch}" "${_wrapper_parent_image_out}"

  local _rb_pull="--pull=true"
  runtime_pushes_intermediate_images || _rb_pull="--pull=false"
  # XC2/XC3: the wrapper is the tag that goes LIVE and is indexed into
  # :latest-cross, so stamp it with the android parent-digest (its immutable
  # cross-lane ancestor) + the run-id when it will be pushed. base/package are
  # local intermediates in the normal flow, so android is the wrapper's nearest
  # registry-resident ancestor to record.
  local _wrap_push=0
  runtime_pushes_wrapper_images && _wrap_push=1
  local -a _wrap_out=()
  append_runtime_image_output _wrap_out "${_wrapper_tag_out}" "${_wrap_push}" \
    "$(runtime_android_pin "${arch}")" android
  # RTCACHE2: same stale-worker-cache hazard as the package build — the wrapper
  # is FROM package, so a clean package rebuild normally invalidates it, but
  # gate it too so RUNTIME_NO_CACHE=1 guarantees an end-to-end fresh wrapper.
  # shellcheck disable=SC2086  # intentional: empty RUNTIME_NO_CACHE must vanish
  run_nerdctl_build "${NERDCTL_BIN:-nerdctl}" \
    "${_rb_pull}" \
    ${RUNTIME_NO_CACHE:+--no-cache} \
    --platform "linux/${arch}" \
    "${_wrap_out[@]}" \
    -f "${WRAPPER_DOCKERFILE_PATH:-linux/Dockerfile.torch}" \
    "${_wrapper_build_args_out[@]}" \
    . || return 1

  runtime_assert_provenance_stamped "${_wrapper_tag_out}" || return 1

  runtime_remove_stage_context package "${arch}"
}

# Verify the provenance we just ASKED for actually landed on the image we just
# built. Composing a correct-looking flag that silently does nothing is the
# exact failure class that cost this repo five stale ships (RTCACHE3: an
# `--output type=image,name=X` spec that built no local tag) and then months of
# inert XC2/XC3 gates (labels never emitted at all) — in both cases every log
# line stayed green. One `image inspect` right after the build closes that loop
# while the evidence is still fresh, instead of discovering it in an audit.
#
# Fails ONLY on a positive "the image is readable and the stamp is not there"
# (rc 2). A reader that could not look at all (rc 1) warns and proceeds — a
# transient inspect problem must not kill a multi-hour build. Escape hatch:
# ANCESTRY_STAMP_ENFORCE=0.
runtime_assert_provenance_stamped() {
  local tag="$1" rc=0

  is_dry_run && return 0
  [ -n "${CROSS_RUN_ID:-}" ] || return 0          # nothing was asked for
  declare -F ancestry_recorded_label >/dev/null 2>&1 || return 0

  ancestry_recorded_label "${tag}" "${ANCESTRY_RUN_ID_KEY}" >/dev/null 2>&1 || rc=$?
  case "${rc}" in
    0) return 0 ;;
    2)
      if [ "${ANCESTRY_STAMP_ENFORCE:-1}" = "0" ]; then
        warn "[ancestry] ${tag} carries no run-id label although one was requested (ANCESTRY_STAMP_ENFORCE=0, continuing)"
        return 0
      fi
      warn "[ancestry] ${tag} was built WITHOUT the run-id label this build stamped (CROSS_RUN_ID=${CROSS_RUN_ID})"
      warn "[ancestry]   the provenance mechanism is silently inert again — refusing to hand on an unverifiable image"
      warn "[ancestry]   (set ANCESTRY_STAMP_ENFORCE=0 to override)"
      return 1
      ;;
    *)
      warn "[ancestry] could not read ${tag} back to confirm its provenance stamp — proceeding (inspect unavailable, not a missing stamp)"
      return 0
      ;;
  esac
}

runtime_build_wrapper_image() {
  local arch="$1"
  local tag parent_image
  local -a build_args=()

  _runtime_build_wrapper "${arch}" tag parent_image build_args

  if is_dry_run; then
    log "[DRY RUN] would push wrapper image ${tag}"
    return 0
  fi

  if runtime_pushes_wrapper_images; then
    runtime_push_tag "${tag}"
  fi
}

runtime_build_wrapper_rootfs() {
  local arch="$1"
  local rootfs_dir="$2"
  local tag parent_image artifact_dir
  local -a build_args=()

  _runtime_build_wrapper "${arch}" tag parent_image build_args

  if is_dry_run; then
    log "[DRY RUN] would export rootfs from ${tag} to ${rootfs_dir} and push"
    return 0
  fi

  artifact_dir="$(dirname "${rootfs_dir}")"
  export_rootfs_from_image "${NERDCTL_BIN:-nerdctl}" "${tag}" "${artifact_dir}"

  if runtime_pushes_wrapper_images; then
    runtime_push_tag "${tag}"
  fi
}

runtime_build_chain() {
  local arch="$1"
  local rootfs_dir="${2:-}"

  # EXPLICIT `|| return 1` on every step (same hazard as cross_stage_run):
  # this function is invoked via run_parallel_arch_loop's `if !`, which
  # disables set -e for the whole call tree — without these, a failed base or
  # package build fell through to the next step and the lane reported success
  # with nothing built.
  runtime_build_base_image "${arch}" || return 1
  runtime_build_package_image "${arch}" || return 1

  if [ -n "${rootfs_dir}" ]; then
    runtime_build_wrapper_rootfs "${arch}" "${rootfs_dir}" || return 1
    return 0
  fi

  runtime_build_wrapper_image "${arch}" || return 1
}

runtime_write_artifact_metadata() {
  local arch="$1"
  local output_dir="$2"

  mkdir -p "${output_dir}"
  cat > "${output_dir}/artifact.env" <<EOF
TARGET_ARCH=${arch}
SOURCE_IMAGE=$(runtime_wrapper_tag "${arch}")
PACKAGE_IMAGE=$(runtime_package_tag "${arch}")
BASE_IMAGE=$(runtime_base_tag "${arch}")
ARTIFACT_IMAGE=$(runtime_artifact_image_ref "${arch}")
EOF
}

runtime_shared_usage_env_overrides() {
  cat <<'EOF'
Environment overrides:
  NERDCTL_BIN                  nerdctl executable to use
  BUILDKIT_HOST                Optional BuildKit socket/address passed to nerdctl build
  TARGET_ARCHES                Comma-separated architecture list
  TARGET_ARCH                  Alias for TARGET_ARCHES
  ARCHITECTURES                Alias for TARGET_ARCHES
  RUNTIME_USE_LOCAL_CONTEXT_CHAIN
                                true/false/auto (default: auto)
  RUNTIME_CONTEXT_ROOT         Temporary directory root for local stage handoff
  BASE_DOCKERFILE_PATH         Base Dockerfile path
  BASE_PARENT_IMAGE            Optional parent image passed as BASE_IMAGE to the
                                selected base Dockerfile (for example a GPU base)
  PACKAGE_DOCKERFILE_PATH      Package Dockerfile path
  WRAPPER_DOCKERFILE_PATH      Final wrapper (torch) Dockerfile path
  TORCH_APP_MODE               TORCH_APP_MODE passed to linux/Dockerfile.torch
  ENABLE_NVIDIA                Optional accelerator flag passed to package/torch/wrapper builds
  ENABLE_AMD                   Optional accelerator flag passed to package/torch/wrapper builds
  ONNX_PACKAGE                 Optional torch ONNX package override
  PYTORCH_EXTRA                Optional torch PyTorch extra override
  USE_FAST_UBUNTU_MIRROR       Set to true to replace archive/security/ports Ubuntu mirrors
  FAST_UBUNTU_MIRROR_URL       Mirror URL used when the fast mirror is enabled
  FAST_UBUNTU_PORTS_MIRROR_URL Optional ports mirror URL used when the fast mirror is enabled
EOF
}
