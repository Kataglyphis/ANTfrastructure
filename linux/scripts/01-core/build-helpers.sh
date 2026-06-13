#!/usr/bin/env bash
# build-helpers.sh — nerdctl build wrappers and build-arg helpers.
#
[ -z "${_BUILD_HELPERS_LOADED:-}" ] || return 0
_BUILD_HELPERS_LOADED=1
#
# Provides:
#   _bool_truthy()                — test a value for boolean truthiness
#   is_dry_run()                  — return 0 if DRY_RUN is set to a truthy value
#   arch_list_to_words()          — convert comma-separated arch list to space-separated
#   trap_push()                   — push an EXIT trap handler (preserves existing handlers)
#   run()                         — echo + execute (DO NOT use for secret-bearing args)
#   run_quiet()                   — execute without echoing
#   append_buildkit_host_arg()    — add --buildkit-host if BUILDKIT_HOST is set
#   append_mirror_build_args()    — add USE_FAST_UBUNTU_MIRROR args
#   append_mirror_build_args_from_env() — convenience wrapper
#   append_optional_build_arg()   — add --build-arg only if value is non-empty
#   append_runtime_base_parent_build_arg() — optional BASE_IMAGE for base build
#   append_runtime_accelerator_build_args() — ENABLE_NVIDIA / ENABLE_AMD
#   image_exists()                — check if an image exists locally
#   run_nerdctl_build()           — nerdctl build with BUILDKIT_HOST support
#   pull_platform_image()         — nerdctl pull --platform

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  "$@"
}

# Like run() but does NOT echo the command. Use when build args may contain
# secrets (e.g. GITHUB_TOKEN, registry credentials) that must not appear in logs.
run_quiet() {
  "$@"
}

# Test whether a value is boolean-truthy (1, true, TRUE, yes, YES, on, ON).
# Usage: _bool_truthy "${DRY_RUN}" && echo "dry run"
#        _bool_truthy "${PARALLEL_ARCHS}" && echo "parallel"
_bool_truthy() {
  case "${1:-0}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# Returns 0 (true) when DRY_RUN is set to a truthy value (1, true, yes).
# Use this instead of repeating [ "${DRY_RUN:-0}" -eq 1 ] across scripts.
is_dry_run() {
  _bool_truthy "${DRY_RUN:-0}"
}

# Convert a comma-separated architecture list to space-separated words.
# Usage: for arch in $(arch_list_to_words "${TARGET_ARCHES}"); do ...
arch_list_to_words() {
  printf '%s' "${1:-}" | tr ',' ' '
}

# ── EXIT trap stack ───────────────────────────────────────────────────────────
# Push a handler onto the EXIT trap.  Preserves existing handlers so multiple
# modules can register cleanup without overwriting each other.
declare -a _EXIT_TRAP_STACK=()

trap_push() {
  local handler="$1"
  _EXIT_TRAP_STACK+=("${handler}")
  trap '_BH_RC=$?; for _BH_TRAP_HANDLER in "${_EXIT_TRAP_STACK[@]}"; do eval "${_BH_TRAP_HANDLER}" || true; done; exit ${_BH_RC}' EXIT
}

append_buildkit_host_arg() {
  local -n out_args_ref=$1
  if [ -n "${BUILDKIT_HOST:-}" ]; then
    out_args_ref+=(--buildkit-host "${BUILDKIT_HOST}")
  fi
}

append_mirror_build_args() {
  local -n out_args_ref=$1
  local use_fast_mirror="${2:-${USE_FAST_UBUNTU_MIRROR:-false}}"
  local archive_url="${3:-${FAST_UBUNTU_MIRROR_URL:-${FAST_UBUNTU_MIRROR_URL_DEFAULT:-https://archive.ubuntu.com/ubuntu/}}}"
  local ports_url="${4:-${FAST_UBUNTU_PORTS_MIRROR_URL:-}}"

  out_args_ref+=(
    --build-arg "USE_FAST_UBUNTU_MIRROR=${use_fast_mirror}"
    --build-arg "FAST_UBUNTU_MIRROR_URL=${archive_url}"
  )

  if [ -n "${ports_url}" ]; then
    out_args_ref+=(--build-arg "FAST_UBUNTU_PORTS_MIRROR_URL=${ports_url}")
  fi
}

# Convenience wrapper that reads mirror defaults from the environment so callers
# don't need to repeat the same fallback chain.
append_mirror_build_args_from_env() {
  local -n _amfe_out=$1
  append_mirror_build_args _amfe_out \
    "${USE_FAST_UBUNTU_MIRROR:-false}" \
    "${FAST_UBUNTU_MIRROR_URL:-${FAST_UBUNTU_MIRROR_URL_DEFAULT:-https://archive.ubuntu.com/ubuntu/}}" \
    "${FAST_UBUNTU_PORTS_MIRROR_URL:-}"
}

append_optional_build_arg() {
  local -n out_args_ref=$1
  local arg_name="$2"
  local arg_value="${3:-}"
  if [ -n "${arg_value}" ]; then
    out_args_ref+=(--build-arg "${arg_name}=${arg_value}")
  fi
}

append_runtime_base_parent_build_arg() {
  append_optional_build_arg "$1" BASE_IMAGE "${BASE_PARENT_IMAGE:-}"
}

append_runtime_accelerator_build_args() {
  append_optional_build_arg "$1" ENABLE_NVIDIA "${ENABLE_NVIDIA:-}"
  append_optional_build_arg "$1" ENABLE_AMD "${ENABLE_AMD:-}"
}

append_common_build_args() {
  local -n _acba_out=$1
  append_mirror_build_args_from_env _acba_out
  append_version_build_args _acba_out
}

ensure_local_image() {
  local image_tag="$1"
  local dockerfile_path="$2"
  local remote_tag="${3:-${image_tag}}"
  local -n _eli_build_args=$4
  local rebuild="${5:-${REBUILD_BASE:-0}}"

  if [ "${rebuild}" -eq 0 ] && image_exists "${NERDCTL_BIN:-nerdctl}" "${image_tag}"; then
    log "Using existing local image: ${image_tag}"
    return 0
  fi

  if [ "${rebuild}" -eq 0 ] && [ -n "${remote_tag}" ]; then
    log "Trying to pull remote image: ${remote_tag}"
    if retry 3 10 "pulling ${remote_tag}" pull_platform_image "${NERDCTL_BIN:-nerdctl}" linux/amd64 "${remote_tag}"; then
      if [ "${remote_tag}" != "${image_tag}" ]; then
        run "${NERDCTL_BIN:-nerdctl}" tag "${remote_tag}" "${image_tag}"
      fi
      return 0
    fi
    log "Remote image unavailable; bootstrapping ${image_tag} locally"
  else
    log "Building ${image_tag} locally"
  fi

  run_nerdctl_build "${NERDCTL_BIN:-nerdctl}" \
    --pull=false \
    --platform linux/amd64 \
    -t "${image_tag}" \
    -f "${dockerfile_path}" \
    "${_eli_build_args[@]}" \
    .
}

image_exists() {
  local nerdctl_bin image_ref
  if [ "$#" -eq 1 ]; then
    nerdctl_bin="${NERDCTL_BIN:-nerdctl}"
    image_ref="$1"
  else
    nerdctl_bin="$1"
    image_ref="$2"
  fi
  "${nerdctl_bin}" image inspect "${image_ref}" >/dev/null 2>&1
}

run_nerdctl_build() {
  local nerdctl_bin="$1"
  shift
  local -a build_cmd=("${nerdctl_bin}" build)
  append_buildkit_host_arg build_cmd
  build_cmd+=("$@")
  run "${build_cmd[@]}"
}

pull_platform_image() {
  local nerdctl_bin="$1"
  local platform="$2"
  local image_ref="$3"
  run "${nerdctl_bin}" pull --platform "${platform}" "${image_ref}"
}
