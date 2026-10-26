# shellcheck shell=bash
# A published child is reused when its build key matches this run's. docs/linux-cross-builds.md#a-failed-arch-re-runs-alone
[ -n "${_LIB_RUNTIME_REUSE_SH_LOADED:-}" ] && return 0
_LIB_RUNTIME_REUSE_SH_LOADED=1
_LIB_RUNTIME_REUSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=linux/scripts/lib-runtime-switch.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-runtime-switch.sh"

RUNTIME_BUILD_KEY_LABEL="${RUNTIME_BUILD_KEY_LABEL:-org.kataglyphis.build-key}"
# Settings that change a wrapper's bytes but reach no versions.env key; per-arch values are hashed by their own lines.
_RUNTIME_BUILD_KEY_KNOBS=(APP_REF BUILD_TYPE TORCH_APP_MODE ONNX_PACKAGE PYTORCH_EXTRA
  RUNTIME_WHEELS_SOURCE HOST_PAYLOAD_ARCHES ARTIFACT_BUILD_MODE PACKAGE_DOCKERFILE_TARGET
  ENABLE_NVIDIA ENABLE_AMD ENABLE_ROCM_ASAN ENABLE_DEEPSTREAM ENABLE_TENSORRT CROSS_VARIANT
  BASE_PARENT_IMAGE BASE_DOCKERFILE_PATH PACKAGE_DOCKERFILE_PATH WRAPPER_DOCKERFILE_PATH)
_RUNTIME_CLOSURE_KEY=""

# Prints on or off. An unknown value is rc 2, so a typo stops a lane at its start.
runtime_reuse_mode() {
  runtime_switch_mode RUNTIME_REUSE_CHILDREN 1 on off "reuse matching children" "every child from this run"
}

runtime_build_key_varname() {
  printf 'RUNTIME_BUILD_KEY_%s' "$1"
}

# The hash of every context file the three runtime Dockerfiles read, computed once per run.
runtime_closure_key() {
  if [ -z "${_RUNTIME_CLOSURE_KEY}" ]; then
    _RUNTIME_CLOSURE_KEY="$(python3 "${_LIB_RUNTIME_REUSE_DIR}/runtime-build-key.py" --root "${REPO_ROOT}" \
      --dockerfile "${BASE_DOCKERFILE_PATH:-linux/Dockerfile.base}" \
      --dockerfile "${PACKAGE_DOCKERFILE_PATH:-linux/Dockerfile.package}" \
      --dockerfile "${WRAPPER_DOCKERFILE_PATH:-linux/Dockerfile.torch}" \
      --extra linux/scripts/01-core/versions.env --extra linux/scripts/01-core/tool-pins.env)" || return 1
  fi
  [ -n "${_RUNTIME_CLOSURE_KEY}" ] || return 1
  printf '%s' "${_RUNTIME_CLOSURE_KEY}"
}

# <arch>: what this run would build that arch from; rc 1 when an input cannot be resolved.
runtime_build_key() {
  local arch="$1" closure android name
  local -a args=()
  closure="$(runtime_closure_key)" || return 1
  android="$(runtime_android_pin "${arch}" 2>/dev/null || true)"
  # The digest alone: --image-repo moves the repo prefix without changing the parent.
  case "${android}" in *@sha256:*) android="${android##*@}" ;; *) return 1 ;; esac
  append_version_build_args args "${arch}"
  {
    printf 'closure %s\narch %s\nandroid %s\n' "${closure}" "${arch}" "${android}"
    printf 'arg %s\n' "${args[@]}"
    for name in "${_RUNTIME_BUILD_KEY_KNOBS[@]}"; do
      printf 'knob %s=%s\n' "${name}" "${!name:-}"
    done
  } | sha256sum | cut -d' ' -f1
}

# <arches...>: exports each arch's key for the wrapper label; an arch without one is never reused.
runtime_build_keys_export() {
  local arch key var
  for arch in "$@"; do
    var="$(runtime_build_key_varname "${arch}")"
    if key="$(runtime_build_key "${arch}")" && [ -n "${key}" ]; then
      printf -v "${var}" '%s' "${key}"
      export "${var?}"
    else
      warn "[runtime-reuse] ${arch}: no build key (closure or android pin unresolvable), so its published child cannot be reused"
      unset "${var}"
    fi
  done
  return 0
}

# <arch> [tag]: built-this-run | reusable | stale | missing.
runtime_child_state() {
  local arch="$1" tag="${2:-}" rid want got var
  [ -n "${tag}" ] || tag="$(runtime_wrapper_tag "${arch}")" || return 1
  rid="$(ancestry_recorded_run_id "${tag}" 2>/dev/null || true)"
  if [ -z "${rid}" ]; then printf 'missing'; return 0; fi
  if [ "${rid}" = "${CROSS_RUN_ID:-}" ]; then printf 'built-this-run'; return 0; fi
  [ "$(runtime_reuse_mode 2>/dev/null)" = on ] || { printf 'stale'; return 0; }
  var="$(runtime_build_key_varname "${arch}")"
  want="${!var:-}"
  got="$(ancestry_recorded_provenance "${tag}" "${RUNTIME_BUILD_KEY_LABEL}" 2>/dev/null || true)"
  if [ -n "${want}" ] && [ "${got}" = "${want}" ]; then printf 'reusable'; else printf 'stale'; fi
  return 0
}

# The index this run publishes: its own arches plus the reused ones, and each reused child's pinned ref.
RUNTIME_INDEX_ARCHES=""
RUNTIME_REUSED_REFS=""

# <image>: the published index's arches, one per line; rc 3 when nothing is published, 1 when unreadable.
runtime_published_arches() {
  local out err
  err="$(mktemp)" || return 1
  if ! out="$("${NERDCTL_BIN:-nerdctl}" manifest inspect "$1" 2>"${err}")"; then
    # Only a 404 means nothing to protect; any other failure is "could not check", never "safe".
    if grep -qE -e "not found|manifest unknown|MANIFEST_UNKNOWN|404" "${err}"; then
      rm -f "${err}"
      return 3
    fi
    tail -1 "${err}" >&2
    rm -f "${err}"
    return 1
  fi
  rm -f "${err}"
  printf '%s\n' "${out}" \
    | sed -n 's/.*"architecture"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | LC_ALL=C sort -u
}

# <arch>: the digest-pinned ref the plan reused for that arch; rc 1 when it reused none.
runtime_reused_ref() {
  local arch ref
  while read -r arch ref; do
    if [ "${arch}" = "$1" ]; then printf '%s' "${ref}"; return 0; fi
  done <<< "${RUNTIME_REUSED_REFS}"
  return 1
}

# <image> <target-arches>: call directly, it sets globals; a published arch outside the targets is kept only when reusable.
runtime_reuse_plan() {
  local image="$1" targets="$2" published arch tag state ref rc=0
  RUNTIME_INDEX_ARCHES="${targets}"
  RUNTIME_REUSED_REFS=""
  [ "$(runtime_reuse_mode)" = on ] || return 0
  published="$(runtime_published_arches "${image}")" || rc=$?
  if [ "${rc}" -eq 3 ]; then return 0; fi
  if [ "${rc}" -ne 0 ]; then
    warn "[runtime-reuse] could not read ${image}, so no published child is reused (the completeness gate decides)"
    return 0
  fi
  while read -r arch; do
    [ -n "${arch}" ] || continue
    case ",${targets}," in *",${arch},"*) continue ;; esac
    runtime_build_keys_export "${arch}"
    tag="$(runtime_wrapper_tag "${arch}")" || continue
    state="$(runtime_child_state "${arch}" "${tag}")"
    if [ "${state}" != reusable ]; then
      warn "[runtime-reuse] ${arch}: ${tag} is ${state}: what built it differs from this run, so it is not reused; add ${arch} to --target-arches"
      continue
    fi
    ref="$(registry_pin_ref "${NERDCTL_BIN:-nerdctl}" "${tag}" 2>/dev/null || true)"
    case "${ref}" in
      *@sha256:*) ;;
      *) warn "[runtime-reuse] ${arch}: ${tag} does not resolve to a registry digest, so it is not reused"; continue ;;
    esac
    log "[runtime-reuse] ${arch}: reusing ${ref}, built by run $(ancestry_recorded_run_id "${tag}" 2>/dev/null || true) from the same inputs"
    RUNTIME_INDEX_ARCHES="${RUNTIME_INDEX_ARCHES},${arch}"
    RUNTIME_REUSED_REFS+="${arch} ${ref}"$'\n'
  done <<< "${published}"
  return 0
}

# <check> <what failed>: runs <check> <arch> <ref> <tag> on every reused child, all of them before the verdict.
_runtime_reused_each() {
  local check="$1" what="$2" arch ref tag failed=""
  while read -r arch ref; do
    [ -n "${arch}" ] || continue
    tag="$(runtime_wrapper_tag "${arch}")" || return 1
    "${check}" "${arch}" "${ref}" "${tag}" || failed="${failed:+${failed} }${arch}"
  done <<< "${RUNTIME_REUSED_REFS}"
  [ -z "${failed}" ] && return 0
  warn "[runtime-reuse] ${what}: [${failed}]"
  return 1
}

_runtime_reuse_pull_one() {
  run "${NERDCTL_BIN:-nerdctl}" pull -q --platform "linux/$1" "$2" || return 1
  run "${NERDCTL_BIN:-nerdctl}" tag "$2" "$3"
}

_runtime_reuse_recheck_one() {
  local state now
  state="$(runtime_child_state "$1" "$3")"
  now="$(registry_pin_ref "${NERDCTL_BIN:-nerdctl}" "$3" 2>/dev/null || true)"
  if [ "${state}" = reusable ] && [ "${now##*@}" = "${2##*@}" ]; then return 0; fi
  warn "[runtime-reuse] $1: $3 is now ${state} at ${now:-no digest}, not the reusable $2 the gates read"
  return 1
}

# Re-reads every reused child from the registry, pinned, under its wrapper tag, so the gates read the bytes the index lists.
runtime_reuse_pull() {
  _runtime_reused_each _runtime_reuse_pull_one "could not pull these reused children by digest"
}

# Before the index: each reused child must still match this run's key and still be the digest the gates read.
runtime_reuse_recheck() {
  _runtime_reused_each _runtime_reuse_recheck_one "these reused children moved after their gates"
}

# <array> <arch>: the wrapper build's build-key label for that arch, when the orchestrator computed one.
runtime_build_key_label_args() {
  local -n _rbkla_out="$1"
  local var
  var="$(runtime_build_key_varname "$2")"
  [ -z "${!var:-}" ] || _rbkla_out+=(--label "${RUNTIME_BUILD_KEY_LABEL}=${!var}")
  return 0
}
