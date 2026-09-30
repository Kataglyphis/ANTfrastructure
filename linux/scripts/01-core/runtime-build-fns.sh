# shellcheck shell=bash
# Per-arch runtime image builds; sourced by artifact-common.sh, whose helpers it relies on.

# One push attempt, output tee'd so the caller can classify the failure.
_runtime_push_attempt() {
  local tag="$1" log_file="${2:-/dev/null}"
  # retry policy lives in runtime_push_tag; this only reports the push rc
  run "${NERDCTL_BIN:-nerdctl}" push "${tag}" 2>&1 | tee "${log_file}"
  return "${PIPESTATUS[0]}"
}

# Transient push failures retry (PUSH_MAX_ATTEMPTS, PUSH_RETRY_BASE_SECS), permanent ones do not. docs/cross-build-verification.md
runtime_push_tag() {
  local tag="$1"
  local max_attempts="${PUSH_MAX_ATTEMPTS:-4}" base_secs="${PUSH_RETRY_BASE_SECS:-15}"
  local attempt=1 rc=0 log_file=""
  log_file="$(mktemp "${TMPDIR:-/tmp}/runtime-push-XXXXXX" 2>/dev/null || true)"

  while :; do
    rc=0
    _runtime_push_attempt "${tag}" "${log_file:-/dev/null}" || rc=$?
    [ "${rc}" -eq 0 ] && break
    if [ -n "${log_file}" ] \
       && declare -F _cross_stage_push_error_is_transient >/dev/null 2>&1 \
       && ! _cross_stage_push_error_is_transient "${log_file}"; then
      warn "[push] ${tag} failed with a PERMANENT error (not a registry/network flake) — not retrying"
      break
    fi
    if [ "${attempt}" -ge "${max_attempts}" ]; then
      warn "[push] ${tag} failed after ${attempt} attempts"
      break
    fi
    warn "[push] ${tag} attempt ${attempt}/${max_attempts} hit a transient registry/network error; retrying in ${base_secs}s"
    sleep "${base_secs}"
    attempt=$(( attempt + 1 ))
  done

  if [ -n "${log_file}" ]; then
    rm -f "${log_file}"
  fi
  return "${rc}"
}

# Immutable android digest (RUNTIME_ANDROID_PIN_<arch>): the package's ARTIFACT_IMAGE and its recorded parent.
runtime_android_pin() {
  local arch="$1" var pin
  var="$(runtime_android_pin_varname "${arch}")"
  pin="${!var:-}"
  if [ -n "${pin}" ]; then
    printf '%s' "${pin}"
    return 0
  fi
  # A resumed run has no pin: resolve the tag so provenance survives (best effort; needs a configured repo).
  local _rap_tag=""
  if declare -F registry_pin_ref >/dev/null 2>&1 \
     && declare -F cross_android_tag >/dev/null 2>&1 \
     && [ -n "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX:-}}" ]; then
    _rap_tag="$(cross_android_tag "${arch}" 2>/dev/null || true)"
    [ -z "${_rap_tag}" ] || pin="$(registry_pin_ref "${NERDCTL_BIN:-nerdctl}" "${_rap_tag}" 2>/dev/null || true)"
  fi
  printf '%s' "${pin}"
}

# Exporter spec carrying the ancestry annotations; degrades to type=image,name=<tag>, so it can always replace -t.
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

# How the runtime stage passes context and provenance: docs/cross-build-verification.md
append_runtime_image_output() {
  local -n _ario_out=$1
  local tag="$2"
  # Arg 3 (will_push) is unused: labels are free on the -t path, so provenance is stamped either way.
  local parent_pin="${4:-}" parent_stage="${5:-}"

  _ario_out+=(-t "${tag}")

  # Provenance as labels: they ride the image config through -t and the push, which annotations cannot.
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
    # Return the failure: errexit is off under run_parallel_arch_loop, and the next line deletes the only copy.
    export_image_to_oci_layout "${NERDCTL_BIN:-nerdctl}" "${tag}" "${context_dir}" || return 1
    remove_local_image_if_exists "${NERDCTL_BIN:-nerdctl}" "${tag}"
  else
    if runtime_pushes_intermediate_images; then
      runtime_push_tag "${tag}" || return 1
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
  append_common_build_args build_args "${arch}"
  append_runtime_base_parent_build_arg build_args

  if is_dry_run; then
    log "[DRY RUN] would build base image ${tag} (platform linux/${arch})"
    return 0
  fi

  # errexit is off here (see runtime_build_chain), so failures must be returned.
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
    runtime_push_tag "${tag}" || return 1
  fi

  runtime_refresh_stage_context base "${arch}" "${tag}"
}

# Per-stage build args, appended after append_common_build_args
append_package_build_args() {
  local -n _apba_out=$1
  local arch="$2" parent_image="$3" artifact_image="$4" package_base_stage="$5"
  # A local, so a failure stops here instead of an empty ARTIFACT_PLATFORM letting BuildKit pick the wrong image.
  local _apba_plat
  _apba_plat="$(runtime_artifact_platform "${arch}")" || return 1
  [ -n "${_apba_plat}" ] || { err "ARTIFACT_PLATFORM resolved empty for ${arch}"; return 1; }
  _apba_out+=(
    --build-arg "BASE_IMAGE=${parent_image}"
    --build-arg "ARTIFACT_IMAGE=${artifact_image}"
    --build-arg "PACKAGE_BASE_STAGE=${package_base_stage}"
    --build-arg "ARTIFACT_PLATFORM=${_apba_plat}"
    --build-arg "BUILD_MODE=${ARTIFACT_BUILD_MODE}"
    --build-arg "TARGET_ARCH=${arch}"
  )
}

append_wrapper_build_args() {
  local -n _awba_out=$1
  local arch="$2" parent_image="$3"
  # OCI created/revision labels; VCS_REF stays "" outside a git checkout.
  local _prov_date _prov_ref
  # Prefer the run-level values so every child of one index agrees.
  _prov_date="${CROSS_BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  _prov_ref="${CROSS_VCS_REF:-$(git -C "${REPO_ROOT:-.}" rev-parse HEAD 2>/dev/null || true)}"
  _awba_out+=(
    --build-arg "BASE_IMAGE=${parent_image}"
    --build-arg "BUILD_MODE=native"
    --build-arg "TARGET_ARCH=${arch}"
    --build-arg "TORCH_APP_MODE=${TORCH_APP_MODE:-all}"
    --build-arg "BUILD_TYPE=${BUILD_TYPE:-Release}"
    --build-arg "BUILD_DATE=${_prov_date}"
    --build-arg "VCS_REF=${_prov_ref}"
  )
  # The export root exists only in export mode and never falls back. docs/linux-cross-builds.md#the-wrappers-wheelhouse-two-deliveries
  if [ -n "${RUNTIME_WHEELS_EXPORT_ROOT:-}" ]; then
    runtime_wheels_wrapper_args _awba_out "${arch}" || return 1
  else
    _append_wheels_image_args _awba_out "${arch}" || return 1
  fi
  # Overrides pass only when set; a GPU wrapper defaults to its GPU pair, since the CPU defaults fail its gates.
  local _onnx_pkg="${ONNX_PACKAGE:-}" _torch_extra="${PYTORCH_EXTRA:-}" _pair
  _pair="$(runtime_gpu_backend_pair)"
  if [ -n "${_pair}" ]; then
    : "${_onnx_pkg:=${_pair% *}}" "${_torch_extra:=${_pair#* }}"
  fi
  append_optional_build_arg _awba_out ONNX_PACKAGE "${_onnx_pkg}"
  append_optional_build_arg _awba_out PYTORCH_EXTRA "${_torch_extra}"
}

# Image the wheels-source stage reads for <arch>, for both deliveries; empty means the WHEELS_IMAGE default.
runtime_wheels_image_ref() {
  local arch="$1" _wheels_image
  # The digest-pinned android ref, the same pin the manifest provenance records.
  _wheels_image="$(runtime_android_pin "${arch}")"
  # With a host infix or a variant, the default names another chain's android; name ours so a miss fails loudly.
  if [ -z "${_wheels_image}" ] && { [ -n "$(cross_build_host_infix)" ] || [ -n "$(cross_variant 2>/dev/null)" ]; }; then
    _wheels_image="$(cross_android_tag "${arch}" 2>/dev/null || true)"
  fi
  printf '%s' "${_wheels_image}"
}

# RUNTIME_WHEELS_SOURCE=image: the torch RUN bind-mounts /opt/wheels out of the android image.
_append_wheels_image_args() {
  local -n _awia_out=$1
  local arch="$2" _wheels_image
  _wheels_image="$(runtime_wheels_image_ref "${arch}")"
  [ -n "${_wheels_image}" ] || return 0
  _awia_out+=(--build-arg "WHEELS_IMAGE=${_wheels_image}")
  # BuildKit's OCI worker cannot see the containerd store, so pass the wheelhouse as a directory context.
  if runtime_use_local_artifact_context; then
    local _wheels_ctx
    _wheels_ctx="$(runtime_wheels_context_dir "${arch}" "${_wheels_image}")" || return 1
    _awia_out+=(--build-context "${_wheels_image}=${_wheels_ctx}")
  fi
  return 0
}

# "<ONNX_PACKAGE> <PYTORCH_EXTRA>" for a GPU wrapper, empty for CPU; assemble-torch-app.sh enforces the ROCm torch pin.
runtime_gpu_backend_pair() {
  if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
    printf '%s' 'onnxruntime-gpu pytorch-cu130'
  elif [ "${ENABLE_AMD:-false}" = "true" ]; then
    printf '%s' 'onnxruntime-migraphx pytorch-rocm10'
  fi
}

# Resolve APP_REF to a commit once per run. docs/linux-cross-builds.md#the-app-the-wrapper-builds
runtime_resolve_app_ref() {
  local _rar_ref="${APP_REF:-}" _rar_out _rar_sha
  local _rar_url='https://github.com/Kataglyphis/OrchestrANT.git'
  if [ -z "${_rar_ref}" ]; then
    err "APP_REF is empty: versions.env names the OrchestrANT ref the wrapper builds"
  fi
  if [[ "${_rar_ref}" =~ ^[0-9a-f]{40}$ ]]; then
    log "APP_REF ${_rar_ref} is a commit; building it as given"
    return 0
  fi
  if ! _rar_out="$(GIT_TERMINAL_PROMPT=0 git ls-remote "${_rar_url}" \
      "refs/heads/${_rar_ref}" "refs/tags/${_rar_ref}" "refs/tags/${_rar_ref}^{}" 2>&1)"; then
    if is_dry_run; then
      warn "[DRY RUN] cannot reach ${_rar_url}; APP_REF stays ${_rar_ref}"
      return 0
    fi
    err "cannot resolve APP_REF=${_rar_ref} at ${_rar_url}: ${_rar_out}"
  fi
  # A branch wins over a same-named tag; an annotated tag gives the commit it peels to.
  _rar_sha="$(printf '%s\n' "${_rar_out}" | awk -v r="${_rar_ref}" '
    $2 == "refs/heads/" r      { head = $1 }
    $2 == "refs/tags/" r "^{}" { peeled = $1 }
    $2 == "refs/tags/" r       { tag = $1 }
    END { print (head != "" ? head : (peeled != "" ? peeled : tag)) }')"
  if [ -z "${_rar_sha}" ]; then
    err "APP_REF=${_rar_ref} names no branch or tag of ${_rar_url}"
  fi
  log "APP_REF ${_rar_ref} -> ${_rar_sha}"
  APP_REF="${_rar_sha}"
  export APP_REF
}

runtime_build_package_image() {
  local arch="$1"
  local tag parent_image parent_context_dir
  local artifact_image artifact_context_ref artifact_context_mode package_base_stage
  local -a build_args=()

  tag="$(runtime_package_tag "${arch}")"
  append_common_build_args build_args "${arch}"
  append_runtime_accelerator_build_args build_args

  # Prefer the immutable android digest; without a threaded pin the mutable tag is used.
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

  append_package_build_args build_args "${arch}" "${parent_image}" "${artifact_image}" "${package_base_stage}" || return 1

  local _rb_pull="--pull=true"
  runtime_pushes_intermediate_images || _rb_pull="--pull=false"
  # Record the android parent-digest only when the package is pushed; the local path keeps a plain -t.
  local _pkg_push=0
  runtime_pushes_intermediate_images && _pkg_push=1
  local -a _pkg_out=()
  append_runtime_image_output _pkg_out "${tag}" "${_pkg_push}" "${_android_pin}" android
  # RUNTIME_NO_CACHE=1: BuildKit can serve a stale COPY --from=android layer after the android digest changed.
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

  # wrapper-smoke builds FROM package FROM base, so the smoke gate cleans up base unless it is skipped.
  if [ "${WRAPPER_SMOKE_GATE:-1}" = "0" ]; then
    _runtime_finish_stage package "${arch}" "${tag}" base
  else
    _runtime_finish_stage package "${arch}" "${tag}" ""
  fi
}

# Builds the wrapper-smoke target, which the package build prunes; cheap on a cache hit. WRAPPER_SMOKE_GATE=0 skips.
_runtime_run_package_smoke() {
  local arch="$1"

  is_dry_run && { log "[DRY RUN] would run wrapper-smoke gate for ${arch}"; return 0; }

  if [ "${WRAPPER_SMOKE_GATE:-1}" = "0" ]; then
    log "[smoke] wrapper-smoke gate skipped (WRAPPER_SMOKE_GATE=0)"
    return 0
  fi

  local -a build_args=()
  append_common_build_args build_args "${arch}"
  append_runtime_accelerator_build_args build_args

  local _android_pin
  _android_pin="$(runtime_android_pin "${arch}")"

  local artifact_image package_base_stage
  if runtime_use_local_artifact_context; then
    local artifact_context_ref artifact_context_mode
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

  local parent_image parent_context_dir
  _runtime_resolve_parent_context base "${arch}" parent_image parent_context_dir build_args

  append_package_build_args build_args "${arch}" "${parent_image}" "${artifact_image}" "${package_base_stage}" || return 1

  log "[smoke] running wrapper-smoke gate for ${arch} (target wrapper-smoke)"

  run_nerdctl_build "${NERDCTL_BIN:-nerdctl}" \
    --pull=false \
    --platform "linux/${arch}" \
    --target wrapper-smoke \
    -f "${PACKAGE_DOCKERFILE_PATH}" \
    "${build_args[@]}" \
    . || return 1

  log "[smoke] wrapper-smoke gate PASSED for ${arch}"
  runtime_remove_stage_context base "${arch}"
  return 0
}

_runtime_build_wrapper() {
  local arch="$1"
  local -n _wrapper_tag_out=$2
  local -n _wrapper_parent_image_out=$3
  local -n _wrapper_build_args_out=$4

  _wrapper_tag_out="$(runtime_wrapper_tag "${arch}")"
  append_common_build_args _wrapper_build_args_out "${arch}"
  append_runtime_accelerator_build_args _wrapper_build_args_out

  local parent_context_dir
  _runtime_resolve_parent_context package "${arch}" _wrapper_parent_image_out parent_context_dir _wrapper_build_args_out

  if is_dry_run; then
    log "[DRY RUN] would build wrapper image ${_wrapper_tag_out} (platform linux/${arch})"
    return 0
  fi

  append_wrapper_build_args _wrapper_build_args_out "${arch}" "${_wrapper_parent_image_out}" || return 1

  local _rb_pull="--pull=true"
  runtime_pushes_intermediate_images || _rb_pull="--pull=false"
  # The wrapper goes live, so record the run-id and its nearest registry-resident ancestor, android.
  local _wrap_push=0
  runtime_pushes_wrapper_images && _wrap_push=1
  local -a _wrap_out=()
  append_runtime_image_output _wrap_out "${_wrapper_tag_out}" "${_wrap_push}" \
    "$(runtime_android_pin "${arch}")" android
  # RUNTIME_NO_CACHE=1 applies here too, so a fresh run is fresh end to end.
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

# Reads the stamp back: fails only on a missing or foreign run-id, warns if unreadable; ANCESTRY_STAMP_ENFORCE=0 overrides.
runtime_assert_provenance_stamped() {
  local tag="$1" rc=0 value="" why=""

  is_dry_run && return 0
  [ -n "${CROSS_RUN_ID:-}" ] || return 0          # nothing was asked for
  declare -F ancestry_recorded_label >/dev/null 2>&1 || return 0

  # scope=local: before the push, the default reader's registry-copy guard rejects every fresh wrapper.
  value="$(ancestry_recorded_label "${tag}" "${ANCESTRY_RUN_ID_KEY}" local)" || rc=$?
  case "${rc}" in
    0)
      [ "${value}" = "${CROSS_RUN_ID}" ] && return 0
      # A tag from an earlier run: the build never re-tagged, which a presence check cannot see.
      why="carries run-id '${value}', not the '${CROSS_RUN_ID}' this build stamped (stale local tag — the build never re-tagged)"
      ;;
    2) why="was built WITHOUT the run-id label this build stamped (CROSS_RUN_ID=${CROSS_RUN_ID})" ;;
    *)
      warn "[ancestry] could not read ${tag} back to confirm its provenance stamp — proceeding (inspect unavailable, not a missing stamp)"
      return 0
      ;;
  esac

  if [ "${ANCESTRY_STAMP_ENFORCE:-1}" = "0" ]; then
    warn "[ancestry] ${tag} ${why} (ANCESTRY_STAMP_ENFORCE=0, continuing)"
    return 0
  fi
  warn "[ancestry] ${tag} ${why}"
  warn "[ancestry]   the provenance mechanism is silently inert again — refusing to hand on an unverifiable image"
  warn "[ancestry]   (set ANCESTRY_STAMP_ENFORCE=0 to override)"
  return 1
}

runtime_build_wrapper_image() {
  local arch="$1"
  local tag parent_image
  local -a build_args=()

  # errexit is off here: without || return 1 a failed build reaches the push, which blames the wrong step.
  _runtime_build_wrapper "${arch}" tag parent_image build_args || return 1

  if is_dry_run; then
    log "[DRY RUN] would push wrapper image ${tag}"
    return 0
  fi

  if runtime_pushes_wrapper_images; then
    runtime_push_tag "${tag}" || return 1
  fi
}

runtime_build_wrapper_rootfs() {
  local arch="$1"
  local rootfs_dir="$2"
  local tag parent_image artifact_dir
  local -a build_args=()

  # A failed build must not reach the export/push below, which would ship a stale tag.
  _runtime_build_wrapper "${arch}" tag parent_image build_args || return 1

  if is_dry_run; then
    log "[DRY RUN] would export rootfs from ${tag} to ${rootfs_dir} and push"
    return 0
  fi

  artifact_dir="$(dirname "${rootfs_dir}")"
  export_rootfs_from_image "${NERDCTL_BIN:-nerdctl}" "${tag}" "${artifact_dir}" || return 1

  if runtime_pushes_wrapper_images; then
    runtime_push_tag "${tag}" || return 1
  fi
}

runtime_build_chain() {
  local arch="$1"
  local rootfs_dir="${2:-}"

  # Explicit || return 1 on every step: run_parallel_arch_loop's `if !` disables errexit for the whole tree.
  _runtime_timed base "${arch}" runtime_build_base_image "${arch}" || return 1
  _runtime_timed package "${arch}" runtime_build_package_image "${arch}" || return 1
  _runtime_timed smoke "${arch}" _runtime_run_package_smoke "${arch}" || return 1

  if [ -n "${rootfs_dir}" ]; then
    _runtime_timed wrapper "${arch}" runtime_build_wrapper_rootfs "${arch}" "${rootfs_dir}" || return 1
    return 0
  fi

  _runtime_timed wrapper "${arch}" runtime_build_wrapper_image "${arch}" || return 1
}

# <step> <arch> <cmd...>: logs the step's wall time. docs/cross-build-verification.md#measuring-the-torch-runs-wait-before-uv-venv
_runtime_timed() {
  local step="$1" arch="$2" t0 rc=0
  shift 2
  t0="$(date +%s)"
  "$@" || rc=$?
  log "[runtime-timing] arch=${arch} step=${step} secs=$(( $(date +%s) - t0 )) rc=${rc}"
  return "${rc}"
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

# Options both runtime orchestrators document; they live here because this library handles them.
runtime_shared_usage_options() {
  cat <<'EOF'
  --image-prefix TAG            Prefix for built wrapper image tags
  --dry-run                    Print build commands without executing them
  --parallel-archs              Build per-architecture images in parallel
  --max-parallel-archs N        Max concurrent arch builds (default: 4)
  --target-arches LIST          Comma-separated target list (default: amd64,arm64,riscv64)
  --architectures LIST          Alias for --target-arches
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
  WRAPPER_SMOKE_GATE          1 (default) = run the wrapper-smoke gate after
                                package build; 0 = skip
  RUNTIME_WHEELS_SOURCE        Where the wrapper's /opt/wheels comes from: auto
                                (default, = image), image (the android image, as
                                before 2026-09-24) or export (a directory copied
                                out before each package build)
EOF
}
