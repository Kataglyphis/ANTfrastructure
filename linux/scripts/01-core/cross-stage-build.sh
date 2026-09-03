#!/usr/bin/env bash
# cross-stage-build.sh — shared cross-lane stage build functions.
# Depends on build-helpers.sh, stage-defs.sh, digest-pinning.sh, logging.sh;
# ancestry.sh is optional (parent-digest annotations).
[ -n "${_CROSS_STAGE_BUILD_SH_LOADED:-}" ] && return 0
_CROSS_STAGE_BUILD_SH_LOADED=1

# _disk_guard_free_gb for the salvage free-space check below (idempotent load).
_CROSS_STAGE_BUILD_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[ -f "${_CROSS_STAGE_BUILD_SH_DIR}/disk-guard.sh" ] \
  && source "${_CROSS_STAGE_BUILD_SH_DIR}/disk-guard.sh"

# Log file path for <label>; empty when LOG_DIR is unset and the caller then
# builds unlogged. build-cross-chain.sh defaults LOG_DIR (STALE-LOG 2026-08-23).
cross_stage_log_redirect() {
  local label="$1"
  if [ -n "${LOG_DIR:-}" ]; then
    mkdir -p "${LOG_DIR}"
    local f="${LOG_DIR}/${label}.log"
    # Truncate once per orchestrator run so repeated runs don't interleave old
    # failures with current output; $$ is stable across parallel-arch subshells.
    local marker="${f}.run" rid="${CROSS_RUN_ID:-$$}"
    if [ "$(cat "${marker}" 2>/dev/null || true)" != "${rid}" ]; then
      : > "${f}"
      printf '%s' "${rid}" > "${marker}" 2>/dev/null || true
    fi
    printf '%s' "${f}"
  fi
}

# True when the log tail shows a transient registry/network PUSH failure worth
# retrying. No log file means we cannot classify, so assume transient.
_cross_stage_push_error_is_transient() {
  local log_file="${1:-}"
  [ -n "${log_file}" ] && [ -r "${log_file}" ] || return 0
  tail -n 300 "${log_file}" 2>/dev/null | grep -qiE \
    'use of closed network connection|failed to do request|failed to copy|error reading from server|unexpected EOF|i/o timeout|TLS handshake timeout|connection reset by peer|connection refused|temporarily unavailable|(500|502|503|504) (Internal Server Error|Bad Gateway|Service Unavailable|Gateway Time-?out)|too many requests|[^0-9]429[^0-9]'
}

# D5: the post-failure cache salvage writes GBs for stages that rebuild anyway.
# False (with a warning) when free space is below SALVAGE_MIN_FREE_GB — set it
# to 0 to always salvage. Unknown free space keeps the old behaviour.
_cross_salvage_disk_ok() {
  local cache_dir="${1:-}" free_gb
  local min_gb="${SALVAGE_MIN_FREE_GB:-${CROSS_DISK_GUARD_GB:-40}}"
  declare -F _disk_guard_free_gb >/dev/null 2>&1 || return 0
  case "${min_gb}" in ''|*[!0-9]*) return 0 ;; esac
  [ "${min_gb}" -gt 0 ] || return 0
  free_gb="$(_disk_guard_free_gb "${cache_dir}")"
  [ -n "${free_gb}" ] || return 0
  [ "${free_gb}" -ge "${min_gb}" ] && return 0
  warn "build failed with only ${free_gb}G free (< ${min_gb}G) — SKIPPING the local cache-export salvage; those stages are rebuilt anyway (SALVAGE_MIN_FREE_GB=0 to always salvage)"
  return 1
}

# ── C (2026-08-30): local OCI-layout stage handoff for --no-push chains ─────
# BuildKit's OCI worker resolves FROM against the REGISTRY, so a multi-stage
# --no-push chain silently builds every child on the last PUSHED parent. The
# fix mirrors the runtime lane's proven handoff: every stage built locally is
# exported to an OCI layout dir, and the child appends
#   --build-context <parent-tag>=oci-layout://<dir>
# so its FROM resolves against the image THIS RUN built. The export machinery
# (export_image_to_oci_layout) comes from context-management.sh, loaded by
# artifact-common.sh. CROSS_LOCAL_CONTEXT_HANDOFF=0 disables.
CROSS_CONTEXT_ROOT="${CROSS_CONTEXT_ROOT:-${XDG_CACHE_HOME:-${HOME:-/root}/.cache}/opencode/cross-stage-contexts}"

cross_local_handoff_enabled() {
  [ "${CROSS_NO_PUSH:-0}" = "1" ] || return 1
  [ "${CROSS_LOCAL_CONTEXT_HANDOFF:-1}" = "1" ] || return 1
  declare -F export_image_to_oci_layout >/dev/null 2>&1
}

# Age-based sweep for workdirs left by killed runs (same shape as the runtime
# lane's _runtime_sweep_orphaned_contexts — a live run's dirs are younger than
# CROSS_CONTEXT_KEEP_HOURS and are never refreshed, so age is a safe proxy).
_cross_sweep_orphaned_contexts() {
  local keep_hours="${CROSS_CONTEXT_KEEP_HOURS:-24}" d freed=0
  [ -d "${CROSS_CONTEXT_ROOT}" ] || return 0
  while IFS= read -r d; do
    [ -n "${d}" ] || continue
    [ "${d}" = "${CROSS_CONTEXT_WORKDIR:-}" ] && continue
    log "[context] reclaiming orphaned cross stage-context $(basename "${d}") (older than ${keep_hours}h)"
    rm -rf "${d}" && freed=$((freed + 1))
  done < <(find "${CROSS_CONTEXT_ROOT}" -mindepth 1 -maxdepth 1 -type d \
             -name 'cross-flow.*' -mmin "+$((keep_hours * 60))" 2>/dev/null || true)
  [ "${freed}" -eq 0 ] || log "[context] reclaimed ${freed} orphaned cross stage-context tree(s)"
}

cross_ensure_local_context_workdir() {
  cross_local_handoff_enabled || return 0
  if [ -n "${CROSS_CONTEXT_WORKDIR:-}" ]; then
    mkdir -p "${CROSS_CONTEXT_WORKDIR}"
    return 0
  fi
  mkdir -p "${CROSS_CONTEXT_ROOT}" 2>/dev/null || true
  _cross_sweep_orphaned_contexts
  CROSS_CONTEXT_WORKDIR="$(mktemp -d "${CROSS_CONTEXT_ROOT}/cross-flow.XXXXXX")"
}

cross_cleanup_local_context_workdir() {
  if [ -n "${CROSS_CONTEXT_WORKDIR:-}" ] && [ -d "${CROSS_CONTEXT_WORKDIR}" ]; then
    rm -rf "${CROSS_CONTEXT_WORKDIR}"
  fi
  CROSS_CONTEXT_WORKDIR=""
}

cross_stage_context_dir() {
  local stage="$1" arch="${2:-}"
  cross_ensure_local_context_workdir || return 1
  [ -n "${CROSS_CONTEXT_WORKDIR:-}" ] || return 1
  printf '%s' "${CROSS_CONTEXT_WORKDIR}/${stage}${arch:+-${arch}}"
}

# _cross_stage_build_impl <push_flag> <label> <tag> <dockerfile> [build args...]
# push=1 pushes to the registry with cache export; push=0 builds locally only.
# Seams of _cross_stage_build_impl, extracted so the main function reads as the
# sequence it is. Behaviour is pinned by tests/test-cross-stage-build-cmd.sh.
# docs/refactoring-backlog.md F1

# --pull for this build: local builds and digest-pinned bases need no refresh.
_cross_build_pull_flag() {
  local push_flag="$1"; shift
  if [ "${push_flag}" -eq 0 ]; then
    printf '%s' "--pull=false"
  elif _has_digest_pinned_base "$@"; then
    printf '%s' "--pull=false"
  else
    printf '%s' "--pull=true"
  fi
}

# Push output + opt-in attestation. See docs/build-cache-tiers.md.
_cross_build_append_push_output() {
  local -n _out="$1"
  local tag="$2" push_flag="$3"
  [ "${push_flag}" -eq 1 ] || return 0
    # Stamp the parent ref this build consumed onto the pushed manifest: it is how
    # a LATER partial run proves it is not on a stale ancestor (see ancestry.sh).
    local _ancestry_ann=""
    if declare -F ancestry_output_annotations >/dev/null 2>&1; then
      _ancestry_ann="$(ancestry_output_annotations \
        "${_CROSS_STAGE_PARENT_PIN:-}" "${_CROSS_STAGE_PARENT_STAGE:-}")"
    fi
    # PUSH1 (2026-08-18): zstd (not force-compression) for NEW layers — push time
    # is the chain ceiling on a ~4-5 MB/s uplink. Knob: CROSS_LAYER_COMPRESSION.
    _out+=(
      --output "type=image,name=${tag},push=true,compression=${CROSS_LAYER_COMPRESSION:-zstd}${_ancestry_ann}"
    )
    # Opt-in SLSA provenance + SBOM as OCI referrers; off by default because the
    # SBOM scanner adds time to every stage.
    if [ -n "${BUILD_ATTEST:-}" ]; then
      _out+=(
        --provenance=mode=max
        --sbom=true
      )
    fi
}

# The three cache tiers: local export (primary), local import (only when the slug
# holds a manifest) and the inline registry cache (push only).
# docs/build-cache-tiers.md
_cross_build_append_cache_args() {
  local -n _out="$1"
  local tag="$2" push_flag="$3" _cache_dir="$4" _cache_slug="$5"
  # A LOCAL buildkit cache is primary: it survives rebuilds and never hits ghcr's
  # 400 on oversized mode=max cache blobs. See docs/build-cache-tiers.md.
  if [ -z "${NO_CACHE:-}" ]; then
    mkdir -p "${_cache_dir}/${_cache_slug}" 2>/dev/null || true
    # Only READ when the slug holds a manifest: --cache-from at an index.json-less
    # dir logs a "could not read" that reads like a fault but is a clean miss.
    if [ -s "${_cache_dir}/${_cache_slug}/index.json" ]; then
      _out+=( --cache-from "type=local,src=${_cache_dir}/${_cache_slug}" )
    fi
    # Set by the chain disk-guard when pruning could not clear the free-space
    # threshold: stop WRITING new local exports, keep READING what survived.
    if [ -z "${CROSS_NO_LOCAL_CACHE_EXPORT:-}" ]; then
      _out+=(
        --cache-to "type=local,dest=${_cache_dir}/${_cache_slug},mode=max"
      )
    fi
    # Inline cache (mode=min, in the image config — no separate blob, so no 400)
    # lets other hosts warm-start from the tag. NO_CACHE_EXPORT skips only this.
    if [ "${push_flag}" -eq 1 ] && [ -z "${NO_CACHE_EXPORT:-}" ]; then
      _out+=(
        --cache-from "type=registry,ref=${tag}"
        --cache-to "type=inline"
      )
    fi
  fi
}

_cross_stage_build_impl() {
  local push_flag="$1" label="$2" tag="$3" dockerfile="$4"
  shift 4
  local -a extra=("$@")
  local -a common_args=()
  append_common_build_args common_args

  local log_file
  log_file="$(cross_stage_log_redirect "${label}")"

  local pull_flag
  pull_flag="$(_cross_build_pull_flag "${push_flag}" "${extra[@]}")"

  local -a build_cmd=(
    "${NERDCTL_BIN:-nerdctl}" build
    "${pull_flag}"
    ${NO_CACHE:+--no-cache}
    --platform linux/amd64
    -t "${tag}"
    -f "${dockerfile}"
  )

  _cross_build_append_push_output build_cmd "${tag}" "${push_flag}"

  local _cache_dir _cache_slug
  _cache_dir="${BUILDKIT_CACHE_DIR:-${HOME:-/root}/.cache/kata-buildcache}"
  _cache_slug="$(printf '%s' "${tag}" | tr '/:@' '___')"
  _cross_build_append_cache_args build_cmd "${tag}" "${push_flag}" \
    "${_cache_dir}" "${_cache_slug}"

  append_buildkit_host_arg build_cmd
  build_cmd+=("${extra[@]}" "${common_args[@]}" .)

  if is_dry_run; then
    printf '[DRY RUN] '
    printf '%q ' "${build_cmd[@]}"
    printf '\n'
    return 0
  fi

  # A transient registry hiccup must not discard a completed multi-GB build: retry
  # the whole command (layers cache-hit). PUSH_MAX_ATTEMPTS, PUSH_RETRY_BASE_SECS.
  local _max_attempts=1
  [ "${push_flag}" -eq 1 ] && _max_attempts="${PUSH_MAX_ATTEMPTS:-4}"
  local _attempt=1 _rc=0 _delay _regcache_fails=0
  while :; do
    if [ -n "${log_file}" ]; then
      # Real pipe, not process substitution: the shell waits for tee, so a fast
      # failure's tail still reaches the log. PIPESTATUS[0] is the build's rc.
      run "${build_cmd[@]}" 2>&1 | tee -a "${log_file}"
      _rc="${PIPESTATUS[0]}"
    else
      run "${build_cmd[@]}"
      _rc=$?
    fi
    [ "${_rc}" -eq 0 ] && return 0
    if [ "${_attempt}" -ge "${_max_attempts}" ] \
       || ! _cross_stage_push_error_is_transient "${log_file}"; then
      # S1: --cache-to type=local only materializes on a SUCCESSFUL solve — re-drive
      # per --target to salvage completed subtrees. docs/build-cache-tiers.md
      if [ -z "${NO_CACHE:-}" ] && [ -z "${CROSS_NO_LOCAL_CACHE_EXPORT:-}" ] \
         && [ "${SALVAGE_CACHE_EXPORT:-1}" != "0" ] && ! is_dry_run \
         && _cross_salvage_disk_ok "${_cache_dir}"; then
        local -a _salvage_targets=()
        mapfile -t _salvage_targets < <(grep -iE \
          '^FROM[[:space:]].+[[:space:]]AS[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]*$' \
          "${dockerfile}" 2>/dev/null | awk '{print $NF}')
        if [ "${#_salvage_targets[@]}" -gt 0 ]; then
          warn "build failed; salvaging local cache exports for ${#_salvage_targets[@]} named stages of ${dockerfile##*/} (SALVAGE_CACHE_EXPORT=0 disables)"
          # A target whose subtree holds the broken vertex RE-RUNS it, hence the
          # hard timeout; and later file-order targets sit downstream of the same
          # break, hence the stop after 2 consecutive failures.
          local _tgt _salvage_fails=0 _salvage_ok=0
          for _tgt in "${_salvage_targets[@]}"; do
            [ "${_salvage_fails}" -ge 2 ] && break
            if timeout "${SALVAGE_TARGET_TIMEOUT:-600}" \
                 "${NERDCTL_BIN:-nerdctl}" build --pull=false --platform linux/amd64 \
                 --target "${_tgt}" -f "${dockerfile}" \
                 --cache-from "type=local,src=${_cache_dir}/${_cache_slug}" \
                 --cache-to "type=local,dest=${_cache_dir}/${_cache_slug},mode=max" \
                 "${extra[@]}" "${common_args[@]}" . >/dev/null 2>&1; then
              _salvage_ok=$((_salvage_ok + 1)); _salvage_fails=0
            else
              _salvage_fails=$((_salvage_fails + 1))
            fi
          done
          warn "salvage-cache-export: ${_salvage_ok}/${#_salvage_targets[@]} named stages exported to the local cache for ${tag}"
        fi
      fi
      return "${_rc}"
    fi
    # ghcr cache-import flake (2026-08-18): the registry cache IMPORT is itself the
    # failing read, so after 2 hits drop it — the local cache still fast-forwards.
    if [ -n "${log_file}" ] \
       && tail -n 40 "${log_file}" 2>/dev/null | grep -qE 'DeadlineExceeded|httpReadSeeker'; then
      _regcache_fails=$(( _regcache_fails + 1 ))
      if [ "${_regcache_fails}" -ge 2 ]; then
        local -a _no_regcache=()
        local _i=0 _arg
        while [ "${_i}" -lt "${#build_cmd[@]}" ]; do
          _arg="${build_cmd[${_i}]}"
          case "${_arg}:${build_cmd[$(( _i + 1 ))]:-}" in
            --cache-from:type=registry*|--cache-to:type=inline*)
              _i=$(( _i + 2 )); continue ;;
          esac
          _no_regcache+=("${_arg}")
          _i=$(( _i + 1 ))
        done
        if [ "${#_no_regcache[@]}" -lt "${#build_cmd[@]}" ]; then
          warn "registry cache import failed ${_regcache_fails}x (DeadlineExceeded/httpReadSeeker) — dropping type=registry cache-from + inline cache-to from the remaining retries (local cache stays active)"
          build_cmd=("${_no_regcache[@]}")
        fi
      fi
    fi
    _delay="$(( _attempt * ${PUSH_RETRY_BASE_SECS:-15} ))"
    warn "Push attempt ${_attempt}/${_max_attempts} for ${tag} hit a transient registry/network error; retrying in ${_delay}s (built layers are cached, only the push repeats)"
    sleep "${_delay}"
    _attempt="$(( _attempt + 1 ))"
  done
}

cross_stage_build_and_push() {
  _cross_stage_build_impl 1 "$@"
}

cross_stage_build_local() {
  _cross_stage_build_impl 0 "$@"
}

# Digest-pinned parent ref for a stage: this run's captured pins first, else the
# parent tag's registry digest. Empty for base. Needs the pin vars in scope.
cross_stage_resolve_parent_pin() {
  local stage="$1" arch="${2:-}"
  local parent parent_tag parent_pin_varname captured

  parent="$(cross_stage_parent "${stage}")"
  [ -z "${parent}" ] && return 0  # base has no parent

  parent_tag="$(cross_stage_tag "${parent}" "${arch}")"
  [ -z "${parent_tag}" ] && { warn "No tag for parent stage '${parent}' of '${stage}'"; return 1; }

  parent_pin_varname="$(cross_stage_pin_varname "${parent}")"
  [ -z "${parent_pin_varname}" ] && { warn "No pin varname for parent stage '${parent}'"; return 1; }

  if cross_stage_is_per_arch "${parent}"; then
    local -n pin_map="${parent_pin_varname}"
    captured="${pin_map[$arch]:-}"
  else
    captured="${!parent_pin_varname:-}"
  fi

  if is_dry_run; then
    printf '%s' "${captured:-${parent_tag}@sha256:dry-run-placeholder}"
    return 0
  fi

  resolve_pin "${captured}" "${parent_tag}"
}

# Prefer a pin captured in this run; otherwise the registry digest of the tag.
resolve_pin() {
  local captured="$1" tag="$2"
  if [ -n "${captured}" ]; then
    printf '%s' "${captured}"
    return 0
  fi
  local result
  result="$(retry 3 10 "registry digest for ${tag}" registry_pin_ref "${NERDCTL_BIN:-nerdctl}" "${tag}")" || {
    warn "Failed to resolve registry digest for ${tag}. Is the image pushed?"
    return 1
  }
  if [ -z "${result}" ]; then
    warn "Registry pin ref returned empty for ${tag}. Is the image pushed?"
    return 1
  fi
  printf '%s' "${result}"
}

# Appends BASE_IMAGE to the build_args nameref and sets _CROSS_STAGE_PARENT_PIN.
# Call directly: a $(...) subshell would discard that and drop BASE_IMAGE.
_cross_stage_run_resolve_parent() {
  local -n _csrrp_out="$1"
  local stage="$2" arch="$3" push_flag="$4" parent="$5"
  _CROSS_STAGE_PARENT_PIN=""
  # Parent stage NAME travels with the pin so the annotation is self-describing.
  _CROSS_STAGE_PARENT_STAGE="${parent}"

  if [ -z "${parent}" ]; then
    return 0
  fi

  if [ "${push_flag}" -eq 1 ]; then
    local parent_pin
    parent_pin="$(cross_stage_resolve_parent_pin "${stage}" "${arch}")" || {
      err "Failed to resolve parent pin for stage '${stage}' (parent: ${parent}). Ensure the parent image is pushed to the registry."
    }
    [ -n "${parent_pin}" ] && _csrrp_out+=(--build-arg "BASE_IMAGE=${parent_pin}")
    _CROSS_STAGE_PARENT_PIN="${parent_pin}"
  else
    local parent_tag
    parent_tag="$(cross_stage_tag "${parent}" "${arch}")"
    [ -z "${parent_tag}" ] && { err "No tag for parent stage: ${parent}"; }
    _csrrp_out+=(--build-arg "BASE_IMAGE=${parent_tag}")
    # C (2026-08-30): local OCI-layout handoff. When the parent was BUILT THIS
    # RUN, serve its layout as a named context so the child's FROM resolves to
    # the local image, never the registry. Missing context = parent not built
    # this run (--only/--from-stage) = today's registry fallback, unchanged.
    if cross_local_handoff_enabled; then
      local parent_ctx
      parent_ctx="$(cross_stage_context_dir "${parent}" "${arch}" 2>/dev/null || true)"
      if [ -n "${parent_ctx}" ] && [ -f "${parent_ctx}/index.json" ]; then
        _csrrp_out+=(--build-context "${parent_tag}=oci-layout://${parent_ctx}")
        log "[stage ${stage}-${arch}] local OCI handoff: ${parent_tag} <- ${parent_ctx}"
      fi
    fi
  fi
}

_cross_stage_run_dispatch() {
  local label="$1" tag="$2" dockerfile="$3" push_flag="$4"
  shift 4
  if [ "${push_flag}" -eq 1 ]; then
    cross_stage_build_and_push "${label}" "${tag}" "${dockerfile}" "$@"
  else
    cross_stage_build_local "${label}" "${tag}" "${dockerfile}" "$@"
  fi
}

_cross_stage_run_capture_pin() {
  local stage="$1" arch="$2" label="$3" tag="$4"

  local pin_varname
  pin_varname="$(cross_stage_pin_varname "${stage}")"
  [ -z "${pin_varname}" ] && { err "No pin varname for stage: ${stage}"; }

  local pinned_digest
  pinned_digest="$(retry 5 10 "registry digest for ${tag}" registry_pin_ref "${NERDCTL_BIN:-nerdctl}" "${tag}")"
  [ -z "${pinned_digest}" ] && { err "Failed to capture digest pin for ${tag}"; }

  if cross_stage_is_per_arch "${stage}"; then
    if ! declare -p "${pin_varname}" &>/dev/null; then
      log "[stage ${label}] pinned ${pinned_digest} (pin variable ${pin_varname} not in scope, skipping storage)"
    else
      local -n pin_map="${pin_varname}"
      pin_map["${arch}"]="${pinned_digest}"
      log "[stage ${label}] pinned ${pinned_digest}"
      local built_flag_varname="${stage^^}_BUILT_THIS_RUN"
      if declare -p "${built_flag_varname}" &>/dev/null; then
        local -n built_flag="${built_flag_varname}"
        built_flag["${arch}"]=1
      fi
      # Under --parallel-archs this runs in a background SUBSHELL, so the array
      # writes above are lost to the parent; parallel_loop_harvest() reads these.
      if [ -n "${PARALLEL_LOOP_FLAGDIR:-}" ] && [ -d "${PARALLEL_LOOP_FLAGDIR}" ]; then
        printf '%s' "${pinned_digest}" > "${PARALLEL_LOOP_FLAGDIR}/pin.${stage}.${arch}"
        : > "${PARALLEL_LOOP_FLAGDIR}/built.${stage}.${arch}"
      fi
    fi
  else
    if declare -p "${pin_varname}" &>/dev/null; then
      printf -v "${pin_varname}" '%s' "${pinned_digest}"
      log "[stage ${label}] pinned ${!pin_varname}"
    else
      log "[stage ${label}] pinned ${pinned_digest} (pin variable ${pin_varname} not in scope, skipping storage)"
    fi
  fi
}

# cross_stage_run <stage> [arch] [push=1]: resolve parent, build, capture pin.
# push=0 builds locally against the mutable parent tag and captures no pin.
cross_stage_run() {
  local stage="$1" arch="${2:-}" push_flag="${3:-1}"
  # --no-push (CROSS_NO_PUSH=1): build every stage locally, skip the ghcr push.
  [ "${CROSS_NO_PUSH:-0}" = "1" ] && push_flag=0
  local label tag dockerfile parent parent_pin
  local -a build_args=()

  label="${stage}"
  cross_stage_is_per_arch "${stage}" && label="${stage}-${arch}"

  dockerfile="$(cross_stage_dockerfile "${stage}")" || {
    err "Stage '${stage}' is not known. Valid stages: ${CROSS_STAGE_ORDER[*]}"
  }
  [ -z "${dockerfile}" ] && {
    err "Stage '${stage}' has no Dockerfile (it delegates to another script — use a different entry point)"
  }
  tag="$(cross_stage_tag "${stage}" "${arch}")"
  [ -z "${tag}" ] && { err "No tag for stage: ${stage} ${arch:+arch=${arch}}"; }

  parent="$(cross_stage_parent "${stage}")"

  # Call directly, never via $(...): it mutates the build_args nameref.
  _cross_stage_run_resolve_parent build_args "${stage}" "${arch}" "${push_flag}" "${parent}"
  parent_pin="${_CROSS_STAGE_PARENT_PIN}"

  cross_stage_build_args build_args "${stage}" "${arch}"

  # Explicit `|| return 1`: run_parallel_arch_loop's `if !` disables set -e for
  # this call tree, so a failed build would otherwise pin and march on.
  if [ "${push_flag}" -eq 1 ]; then
    log "[stage ${label}] building ${tag}${parent_pin:+ FROM ${parent_pin}}"
    _cross_stage_run_dispatch "${label}" "${tag}" "${dockerfile}" 1 "${build_args[@]}" || return 1
  else
    log "[stage ${label}] building ${tag} locally"
    _cross_stage_run_dispatch "${label}" "${tag}" "${dockerfile}" 0 "${build_args[@]}" || return 1
  fi

  if [ "${push_flag}" -eq 0 ]; then
    # Record built-this-run for LOCAL builds too: without it the runtime handoff
    # pulls the STALE published parent over the image this run just built.
    if ! is_dry_run && cross_stage_is_per_arch "${stage}"; then
      local built_flag_varname="${stage^^}_BUILT_THIS_RUN"
      if declare -p "${built_flag_varname}" &>/dev/null; then
        local -n _local_built_flag="${built_flag_varname}"
        _local_built_flag["${arch}"]=1
      fi
      if [ -n "${PARALLEL_LOOP_FLAGDIR:-}" ] && [ -d "${PARALLEL_LOOP_FLAGDIR}" ]; then
        : > "${PARALLEL_LOOP_FLAGDIR}/built.${stage}.${arch}"
      fi
    fi
    # C (2026-08-30): export the image to its OCI layout so the CHILD stage
    # resolves FROM locally (the parent half of the --no-push handoff; the
    # --build-context append lives in _cross_stage_run_resolve_parent).
    # rc propagated: run_parallel_arch_loop disables errexit for this call tree.
    if ! is_dry_run && cross_local_handoff_enabled; then
      local ctx_dir
      ctx_dir="$(cross_stage_context_dir "${stage}" "${arch}")" || return 1
      log "[stage ${label}] exporting OCI layout for local handoff → ${ctx_dir}"
      export_image_to_oci_layout "${NERDCTL_BIN:-nerdctl}" "${tag}" "${ctx_dir}" || return 1
      # The android image ALSO becomes the runtime lane's artifact: the no-push
      # package build must copy from THIS image, not the registry. The helper
      # reads ARTIFACT_CONTEXT_ROOT/$arch (set by the orchestrator), which is
      # exactly where we just wrote the layout.
      if [ "${stage}" = "android" ]; then
        local artifact_dir
        artifact_dir="$(cross_stage_context_dir android-artifacts "${arch}")" || return 1
        log "[stage android-${arch}] exporting artifact layout for the runtime lane → ${artifact_dir}"
        export_image_to_oci_layout "${NERDCTL_BIN:-nerdctl}" "${tag}" "${artifact_dir}" || return 1
      fi
    fi
    return 0
  fi
  if is_dry_run; then
    log "[stage ${label}] [DRY RUN] would pin ${tag}"
    return 0
  fi

  _cross_stage_run_capture_pin "${stage}" "${arch}" "${label}" "${tag}"
}

# Harvest hook for run_parallel_arch_loop: read worker-persisted pins and
# built-this-run flags back into the parent's arrays (subshell writes are lost).
parallel_loop_harvest() {
  local flagdir="$1" f name stage arch pin_varname built_varname
  for f in "${flagdir}"/pin.*.*; do
    [ -f "${f}" ] || continue
    name="${f##*/pin.}"
    stage="${name%%.*}"
    arch="${name##*.}"
    pin_varname="$(cross_stage_pin_varname "${stage}" 2>/dev/null || true)"
    [ -n "${pin_varname}" ] || continue
    if declare -p "${pin_varname}" &>/dev/null; then
      local -n _hv_pin_map="${pin_varname}"
      _hv_pin_map["${arch}"]="$(cat "${f}")"
      log "[stage ${stage}-${arch}] pin harvested from parallel worker"
    fi
    built_varname="${stage^^}_BUILT_THIS_RUN"
    if [ -f "${flagdir}/built.${stage}.${arch}" ] && declare -p "${built_varname}" &>/dev/null; then
      local -n _hv_built="${built_varname}"
      _hv_built["${arch}"]=1
    fi
  done
}

# Build the argument array for build-runtime-manifest.sh from orchestrator state:
# one canonical source for the orchestrator/runtime-helper handoff.
cross_stage_assemble_runtime_helper_args() {
  local -n _arha_out=${1}
  _arha_out=(
    --image "${FINAL_IMAGE}"
    --target-arches "${TARGET_ARCHES}"
    --artifact-image-prefix "${IMAGE_REPO}:cross-android"
    --artifact-build-mode cross
  )
  # XC2: export (not flags — the child inherits via run_runtime_stage's `env`
  # exec) this run's android digests, so the helper skips the mutable tag.
  if declare -p ANDROID_PIN &>/dev/null; then
    local -n _arha_android_pin=ANDROID_PIN
    local _arha_arch _arha_var
    for _arha_arch in $(arch_list_to_words "${TARGET_ARCHES}"); do
      [ -n "${_arha_android_pin[$_arha_arch]:-}" ] || continue
      _arha_var="$(runtime_android_pin_varname "${_arha_arch}")"
      export "${_arha_var}=${_arha_android_pin[$_arha_arch]}"
    done
  fi
  # Under --no-push the per-arch wrapper tags are never pushed, and `nerdctl
  # manifest create` resolves members FROM the registry — so skip the manifest.
  if [ "${CROSS_NO_PUSH:-0}" = "1" ]; then
    _arha_out+=(--skip-manifest)
  else
    _arha_out+=(--push)
  fi
  if _bool_truthy "${USE_FAST_UBUNTU_MIRROR:-false}"; then
    _arha_out+=(--fast-ubuntu-mirror --fast-ubuntu-mirror-url "${FAST_UBUNTU_MIRROR_URL}")
    if [ -n "${FAST_UBUNTU_PORTS_MIRROR_URL:-}" ]; then
      _arha_out+=(--fast-ubuntu-ports-mirror-url "${FAST_UBUNTU_PORTS_MIRROR_URL}")
    fi
  fi
}
