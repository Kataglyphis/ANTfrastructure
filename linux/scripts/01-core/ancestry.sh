#!/usr/bin/env bash
# Machine-checked stage ancestry: docs/linux-cross-builds.md § Trap: stale-base propagation across orchestrator invocations
[ -n "${_ANCESTRY_SH_LOADED:-}" ] && return 0
_ANCESTRY_SH_LOADED=1
_ANCESTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ANCESTRY_PARENT_DIGEST_KEY="${ANCESTRY_PARENT_DIGEST_KEY:-org.kataglyphis.parent-digest}"
ANCESTRY_PARENT_STAGE_KEY="${ANCESTRY_PARENT_STAGE_KEY:-org.kataglyphis.parent-stage}"
# Lets a manifest run prove its per-arch tags come from one orchestrator run.
ANCESTRY_RUN_ID_KEY="${ANCESTRY_RUN_ID_KEY:-org.kataglyphis.run-id}"

# ancestry_output_annotations <pin> [parent_stage]: the --output annotation fragment; empty without a parent.
ancestry_output_annotations() {
  local parent_pin="${1:-}" parent_stage="${2:-}"
  [ -n "${parent_pin}" ] || return 0
  # A comma would split the exporter spec.
  case "${parent_pin}" in
    *,*) warn "[ancestry] parent pin contains a comma, not recording: ${parent_pin}"; return 0 ;;
  esac
  printf ',annotation.%s=%s' "${ANCESTRY_PARENT_DIGEST_KEY}" "${parent_pin}"
  [ -n "${parent_stage}" ] && printf ',annotation.%s=%s' "${ANCESTRY_PARENT_STAGE_KEY}" "${parent_stage}"
  return 0
}

# ancestry_run_id_annotation <run_id>: the run-id --output fragment; empty for an empty id.
ancestry_run_id_annotation() {
  local run_id="${1:-}"
  [ -n "${run_id}" ] || return 0
  case "${run_id}" in
    *,*) warn "[ancestry] run id contains a comma, not recording: ${run_id}"; return 0 ;;
  esac
  printf ',annotation.%s=%s' "${ANCESTRY_RUN_ID_KEY}" "${run_id}"
  return 0
}

# ancestry_label_args <array> <pin> <stage> <run_id>: config labels, since the runtime lane's plain `-t` cannot carry annotations.
ancestry_label_args() {
  local -n _al_out="$1"
  local parent_pin="${2:-}" parent_stage="${3:-}" run_id="${4:-}"

  _ancestry_label_safe() {
    case "${1:-}" in
      "") return 1 ;;
      *$'\n'*) warn "[ancestry] provenance value contains a newline, not recording"; return 1 ;;
    esac
    return 0
  }

  if _ancestry_label_safe "${run_id}"; then
    _al_out+=(--label "${ANCESTRY_RUN_ID_KEY}=${run_id}")
  fi
  if _ancestry_label_safe "${parent_pin}"; then
    _al_out+=(--label "${ANCESTRY_PARENT_DIGEST_KEY}=${parent_pin}")
    if _ancestry_label_safe "${parent_stage}"; then
      _al_out+=(--label "${ANCESTRY_PARENT_STAGE_KEY}=${parent_stage}")
    fi
  fi
  unset -f _ancestry_label_safe
  return 0
}

# ancestry_recorded_annotation <ref> [key]: exit 0 with the value, 2 when absent, 1 when unreadable.
ancestry_recorded_annotation() {
  local image_ref="$1" key="${2:-${ANCESTRY_PARENT_DIGEST_KEY}}"
  local helper="${_ANCESTRY_DIR}/manifest-annotation.py"

  if ! command -v python3 >/dev/null 2>&1 || [ ! -f "${helper}" ]; then
    return 1
  fi

  local manifest_json
  manifest_json="$("${NERDCTL_BIN:-nerdctl}" manifest inspect --verbose "${image_ref}" 2>/dev/null)" || return 1
  [ -n "${manifest_json}" ] || return 1

  printf '%s' "${manifest_json}" | python3 "${helper}" "${key}" 2>/dev/null
}

# ancestry_recorded_label <ref> [key] [shipped|local]: 0/2/1 as above; "shipped" distrusts a local tag that is not the registry copy.
ancestry_recorded_label() {
  local image_ref="$1" key="${2:-${ANCESTRY_PARENT_DIGEST_KEY}}" scope="${3:-shipped}"
  local nerdctl="${NERDCTL_BIN:-nerdctl}"
  local value

  value="$("${nerdctl}" image inspect --format "{{index .Config.Labels \"${key}\"}}" \
            "${image_ref}" 2>/dev/null)" || return 1
  case "${value}" in
    ""|"<no value>") return 2 ;;
  esac

  if [ "${scope}" != "local" ] && declare -F registry_pin_ref >/dev/null 2>&1; then
    local remote local_digests
    remote="$(registry_pin_ref "${nerdctl}" "${image_ref}" 2>/dev/null || true)"
    if [ -n "${remote}" ]; then
      local_digests="$("${nerdctl}" image inspect --format '{{json .RepoDigests}}' \
                        "${image_ref}" 2>/dev/null || true)"
      case "${local_digests}" in
        *"${remote##*@}"*) ;;
        *) warn "[ancestry] ${image_ref}: local tag is not the registry copy (${remote##*@}) — ignoring its provenance labels"
           return 1 ;;
      esac
    fi
  fi

  printf '%s' "${value}"
}

# Reads the registry copy's label without a pull, for --repair runs on a host that never built the wrappers.
ancestry_recorded_registry_label() {
  local image_ref="$1" key="${2:-${ANCESTRY_PARENT_DIGEST_KEY}}"
  local helper="${_ANCESTRY_DIR}/registry-config-label.py"

  command -v python3 >/dev/null 2>&1 || return 1
  [ -f "${helper}" ] || return 1
  python3 "${helper}" "${image_ref}" "${key}" 2>/dev/null
}

# Labels first (runtime lane), then annotations (cross lane); exit 0 value, 2 absent, 1 unreadable.
ancestry_recorded_provenance() {
  local image_ref="$1" key="$2"
  local value label_rc=0 ann_rc=0

  value="$(ancestry_recorded_label "${image_ref}" "${key}")" || label_rc=$?
  if [ "${label_rc}" -eq 0 ] && [ -n "${value}" ]; then
    printf '%s' "${value}"
    return 0
  fi

  # The local store could not answer; the push carried the label in the config blob.
  local reg_rc=0
  value="$(ancestry_recorded_registry_label "${image_ref}" "${key}")" || reg_rc=$?
  if [ "${reg_rc}" -eq 0 ] && [ -n "${value}" ]; then
    printf '%s' "${value}"
    return 0
  fi

  value="$(ancestry_recorded_annotation "${image_ref}" "${key}")" || ann_rc=$?
  if [ "${ann_rc}" -eq 0 ] && [ -n "${value}" ]; then
    printf '%s' "${value}"
    return 0
  fi

  # "Absent" only when some reader saw the image: an auth failure must not read as no provenance.
  if [ "${label_rc}" -eq 2 ] || [ "${reg_rc}" -eq 2 ]; then
    return 2
  fi
  return "${ann_rc:-1}"
}

# Read the recorded parent digest (thin wrapper kept for existing callers).
ancestry_recorded_parent() {
  ancestry_recorded_provenance "$1" "${ANCESTRY_PARENT_DIGEST_KEY}"
}

# Read the recorded orchestrator run id (empty/exit-2 when unstamped).
ancestry_recorded_run_id() {
  ancestry_recorded_provenance "$1" "${ANCESTRY_RUN_ID_KEY}"
}

# Compare digests, not refs: --image-repo moves every repo prefix without changing ancestry.
_ancestry_digest_of() {
  local ref="${1:-}"
  printf '%s' "${ref##*@}"
}

# Verify one child→parent link. Returns 1 only on a genuine mismatch.
_ancestry_check_link() {
  local child_ref="$1" parent_ref="$2" label="$3"
  local recorded current rc=0

  recorded="$(ancestry_recorded_parent "${child_ref}")" || rc=$?
  if [ "${rc}" -ne 0 ] || [ -z "${recorded}" ]; then
    warn "[ancestry] ${label}: ${child_ref} records no parent digest — provenance unverifiable (image predates ancestry annotations; rebuild it to enable this check)"
    return 0
  fi

  current="$(registry_pin_ref "${NERDCTL_BIN:-nerdctl}" "${parent_ref}" 2>/dev/null || true)"
  if [ -z "${current}" ]; then
    warn "[ancestry] ${label}: parent tag ${parent_ref} is not resolvable in the registry — skipping ancestry check"
    return 0
  fi

  if [ "$(_ancestry_digest_of "${recorded}")" = "$(_ancestry_digest_of "${current}")" ]; then
    log "[ancestry] ${label}: OK ($(_ancestry_digest_of "${current}"))"
    return 0
  fi

  warn "[ancestry] ${label}: STALE ANCESTOR"
  warn "[ancestry]   ${child_ref}"
  warn "[ancestry]     was built FROM : ${recorded}"
  warn "[ancestry]     but ${parent_ref} now resolves to"
  warn "[ancestry]                    : ${current}"
  return 1
}

# Checked vs found: zero found is legitimate, zero checked out of some found means no tag resolved.
_ANCESTRY_LINKS_CHECKED=0
_ANCESTRY_LINKS_FOUND=0

_ancestry_assert_branch() {
  local child="$1" arch="$2"
  local parent child_ref parent_ref label rc=0
  local depth=0

  while [ -n "${child}" ]; do
    parent="$(cross_stage_parent "${child}")"
    [ -z "${parent}" ] && break   # reached base: no parent to compare against
    _ANCESTRY_LINKS_FOUND=$((_ANCESTRY_LINKS_FOUND + 1))

    # Cycles are rejected elsewhere, but this loop must never hang a build.
    depth=$((depth + 1))
    [ "${depth}" -gt "${#CROSS_STAGE_ORDER[@]}" ] && break

    child_ref="$(cross_stage_tag "${child}" "${arch}" 2>/dev/null || true)"
    parent_ref="$(cross_stage_tag "${parent}" "${arch}" 2>/dev/null || true)"
    if [ -n "${child_ref}" ] && [ -n "${parent_ref}" ]; then
      label="${parent}→${child}"
      cross_stage_is_per_arch "${child}" && label="${label} (${arch})"
      _ANCESTRY_LINKS_CHECKED=$((_ANCESTRY_LINKS_CHECKED + 1))
      _ancestry_check_link "${child_ref}" "${parent_ref}" "${label}" || rc=1
    fi

    child="${parent}"
  done

  return "${rc}"
}

# ancestry_assert_chain <from_stage> <arches_csv>: 1 on a stale ancestor; a from-base run checks nothing.
ancestry_assert_chain() {
  local from_stage="$1" arches_csv="$2"
  local start_parent arch rc=0

  start_parent="$(cross_stage_parent "${from_stage}")"
  [ -z "${start_parent}" ] && return 0   # from base: no prior stages to verify

  log "[ancestry] verifying the ancestor chain feeding stage '${from_stage}' (arches: ${arches_csv})"
  _ANCESTRY_LINKS_CHECKED=0
  _ANCESTRY_LINKS_FOUND=0

  for arch in $(arch_list_to_words "${arches_csv}"); do
    _ancestry_assert_branch "${start_parent}" "${arch}" || rc=1
  done

  if [ "${rc}" -ne 0 ]; then
    warn "[ancestry] ---"
    warn "[ancestry] A parent image was rebuilt AFTER the child that consumes it."
    warn "[ancestry] Starting at '${from_stage}' would silently build on the stale child."
    warn "[ancestry] Fix: rerun --from-stage at or before the OLDEST stage reported"
    warn "[ancestry]      above, so the rebuilt content propagates down the chain."
    warn "[ancestry] Override (you accept the stale ancestor): CROSS_VERIFY_ANCESTRY=0"
  elif [ "${_ANCESTRY_LINKS_FOUND}" -eq 0 ]; then
    log "[ancestry] no ancestor links to compare above '${from_stage}' — nothing to verify"
  elif [ "${_ANCESTRY_LINKS_CHECKED}" -eq 0 ]; then
    warn "[ancestry] compared ZERO links — every stage tag failed to resolve, so this"
    warn "[ancestry] verified NOTHING. Treating as a failure rather than printing 'verified'."
    warn "[ancestry] Override: CROSS_VERIFY_ANCESTRY=0"
    rc=1
  else
    log "[ancestry] ancestor chain verified (${_ANCESTRY_LINKS_CHECKED} link(s))"
  fi
  return "${rc}"
}

# runtime_ancestry_assert_wrappers <arches_csv>: each pushed wrapper must descend from the current android tag.
runtime_ancestry_assert_wrappers() {
  local arches_csv="$1" arch rc=0 wrapper_ref android_ref
  declare -F runtime_stage_tag >/dev/null 2>&1 || return 0
  local parent_stage
  for arch in $(arch_list_to_words "${arches_csv}"); do
    wrapper_ref="$(runtime_stage_tag wrapper "${arch}" 2>/dev/null || true)"
    [ -n "${wrapper_ref}" ] || continue
    # The stage the writer stamped (android), never runtime_stage_parent's "package".
    parent_stage="$(ancestry_recorded_provenance "${wrapper_ref}" "${ANCESTRY_PARENT_STAGE_KEY}" 2>/dev/null || true)"
    [ -n "${parent_stage}" ] || parent_stage=android
    # Resolve as the writer did, via ARTIFACT_IMAGE_PREFIX: IMAGE_REPO is not exported to this child process.
    android_ref=""
    if [ "${parent_stage}" = "android" ] && declare -F runtime_artifact_image_ref >/dev/null 2>&1; then
      android_ref="$(runtime_artifact_image_ref "${arch}" 2>/dev/null || true)"
    fi
    if [ -z "${android_ref}" ]; then
      android_ref="$(runtime_stage_tag "${parent_stage}" "${arch}" 2>/dev/null || true)"
    fi
    [ -n "${android_ref}" ] || continue
    _ancestry_check_link "${wrapper_ref}" "${android_ref}" "${parent_stage}→wrapper (${arch})" || rc=1
  done
  return "${rc}"
}

# Manifest coherence: a partial rebuild leaves per-arch tags from different runs, so run ids must agree.

# An empty run id is unknown provenance, not a distinct generation.
_ancestry_distinct_nonempty() {
  local a
  for a in "$@"; do [ -n "${a}" ] && printf '%s\n' "${a}"; done | sort -u
}

# ancestry_run_ids_coherent <run_id>...: 1 when two different non-empty run ids are present.
ancestry_run_ids_coherent() {
  local -a distinct
  mapfile -t distinct < <(_ancestry_distinct_nonempty "$@")
  [ "${#distinct[@]}" -le 1 ]
}
