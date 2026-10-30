#!/usr/bin/env bash
# nerdctl build wrappers and build-arg helpers.
[ -n "${_BUILD_HELPERS_LOADED:-}" ] && return 0
_BUILD_HELPERS_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/image-ref-args.sh" || exit 1
: "${MEDIA_STRIP:=1}"
# shellcheck source=elf-strip.sh
source "$(dirname "${BASH_SOURCE[0]}")/elf-strip.sh"

# Echoes its argv, so never pass secrets through it.
run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  "$@"
}

# Alias of platform.sh's is_truthy, kept for existing callers.
_bool_truthy() {
  is_truthy "${1:-0}"
}

is_dry_run() {
  _bool_truthy "${DRY_RUN:-0}"
}

# Newline-separated on purpose: space-separated words stop splitting under IFS=$'\n\t'.
arch_list_to_words() {
  printf '%s\n' "${1:-}" | tr ', ' '\n\n'
}

# EXIT trap stack: several modules register cleanup without overwriting each other.
declare -a _EXIT_TRAP_STACK=()

trap_push() {
  local handler="$1"
  _EXIT_TRAP_STACK+=("${handler}")
  trap '_BH_RC=$?; for _BH_TRAP_HANDLER in "${_EXIT_TRAP_STACK[@]}"; do eval "${_BH_TRAP_HANDLER}" || true; done; exit ${_BH_RC}' EXIT
}

append_buildkit_host_arg() {
  local -n _append_buildkit_host_arg_result=$1
  if [ -n "${BUILDKIT_HOST:-}" ]; then
    _append_buildkit_host_arg_result+=(--buildkit-host "${BUILDKIT_HOST}")
  fi
}

append_mirror_build_args() {
  local -n _append_mirror_build_args_result=$1
  local use_fast_mirror="${2:-${USE_FAST_UBUNTU_MIRROR:-false}}"
  local archive_url
  archive_url="${3:-${FAST_UBUNTU_MIRROR_URL:-${FAST_UBUNTU_MIRROR_URL_DEFAULT:-$(ubuntu_default_archive_mirror_url)}}}"
  local ports_url="${4:-${FAST_UBUNTU_PORTS_MIRROR_URL:-}}"

  _append_mirror_build_args_result+=(
    --build-arg "USE_FAST_UBUNTU_MIRROR=${use_fast_mirror}"
    --build-arg "FAST_UBUNTU_MIRROR_URL=${archive_url}"
  )

  if [ -n "${ports_url}" ]; then
    _append_mirror_build_args_result+=(--build-arg "FAST_UBUNTU_PORTS_MIRROR_URL=${ports_url}")
  fi
}

append_mirror_build_args_from_env() {
  local -n _amfe_out=$1
  append_mirror_build_args _amfe_out \
    "${USE_FAST_UBUNTU_MIRROR:-false}" \
    "${FAST_UBUNTU_MIRROR_URL:-${FAST_UBUNTU_MIRROR_URL_DEFAULT:-$(ubuntu_default_archive_mirror_url)}}" \
    "${FAST_UBUNTU_PORTS_MIRROR_URL:-}"
}

append_optional_build_arg() {
  local -n _append_optional_build_arg_result=$1
  local arg_name="$2"
  local arg_value="${3:-}"
  if [ -n "${arg_value}" ]; then
    _append_optional_build_arg_result+=(--build-arg "${arg_name}=${arg_value}")
  fi
}

append_runtime_base_parent_build_arg() {
  : "${BASE_PARENT_IMAGE:=}"
  append_optional_build_arg "$1" BASE_IMAGE "${BASE_PARENT_IMAGE}"
}

# <array> [arch]: DeepStream has an amd64 route only (as the media stage rules), so another arch's package gets false, never the chain's default.
append_runtime_accelerator_build_args() {
  append_optional_build_arg "$1" ENABLE_NVIDIA "${ENABLE_NVIDIA:-}"
  append_optional_build_arg "$1" ENABLE_AMD "${ENABLE_AMD:-}"
  append_optional_build_arg "$1" ENABLE_ROCM_ASAN "${ENABLE_ROCM_ASAN:-}"
  if [ -n "${ENABLE_DEEPSTREAM:-}" ] && [ -n "${2:-}" ] && [ "${2}" != "amd64" ]; then
    append_optional_build_arg "$1" ENABLE_DEEPSTREAM false
  else
    append_optional_build_arg "$1" ENABLE_DEEPSTREAM "${ENABLE_DEEPSTREAM:-}"
  fi
  append_optional_build_arg "$1" ENABLE_TENSORRT "${ENABLE_TENSORRT:-}"
}

# <file> <what> <hint> <NAME...>: 0 when a host secret file is private and sets every NAME; otherwise says why and returns 1.
host_secret_file_ready() {
  local file="$1" what="$2" hint="$3" name
  shift 3
  [ -f "${file}" ] || return 1
  if [ -n "$(find "${file}" -perm /077 2>/dev/null)" ]; then
    printf '[WARN] %s: %s is readable by others (chmod 600 it) -- building without it\n' "${what}" "${file}" >&2
    return 1
  fi
  for name in "$@"; do
    if ! grep -q "^${name}=." "${file}"; then
      printf '[WARN] %s: %s has no %s%s -- building without it\n' "${what}" "${file}" "${name}" "${hint:+ (${hint})}" >&2
      return 1
    fi
  done
  return 0
}

# The host's asset mirror as one BuildKit secret, so neither its endpoint nor its key re-keys a RUN: docs/linux-cross-builds.md#the-asset-mirror
append_asset_mirror_secret() {
  local -n _aams_out=$1
  local file="${KATAGLYPHIS_ASSET_MIRROR_FILE:-${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/kataglyphis/asset-mirror.env}"
  case "${KATAGLYPHIS_ASSET_MIRROR:-on}" in 0|off|false|no) return 0 ;; esac
  host_secret_file_ready "${file}" "asset mirror" "" ASSET_MIRROR_URL || return 0
  _aams_out+=(--secret "id=asset_mirror,src=${file}")
}

append_common_build_args() {
  local -n _acba_out=$1
  append_mirror_build_args_from_env _acba_out
  append_version_build_args _acba_out "${2:-}"
  append_asset_mirror_secret _acba_out
}

image_exists() {
  local nerdctl_bin image_ref
  image_ref_cli_args nerdctl_bin image_ref "$@"
  "${nerdctl_bin}" image inspect "${image_ref}" >/dev/null 2>&1
}

# With RUN_NERDCTL_LOG set (the chain sets it per arch), BuildKit's output goes there and a failure's tail is shown.
run_nerdctl_build() {
  local nerdctl_bin="$1"
  shift
  local -a build_cmd=("${nerdctl_bin}" build)
  append_buildkit_host_arg build_cmd
  build_cmd+=("$@")
  if [ -z "${RUN_NERDCTL_LOG:-}" ]; then
    run "${build_cmd[@]}"
    return
  fi
  local rc=0
  run "${build_cmd[@]}" >> "${RUN_NERDCTL_LOG}" 2>&1 || rc=$?
  if [ "${rc}" -ne 0 ]; then
    tail -n 30 "${RUN_NERDCTL_LOG}" | sed 's/^/  | /'
  fi
  return "${rc}"
}

# strip_elf_tree <dir> [jobs] [strip-bin]: best-effort parallel strip; pass <triplet>-strip for a foreign tree.


# ${STRIP}, else the cross <triplet>-strip: several build scripts never set STRIP, and host strip no-ops on foreign ELFs.
_resolve_media_strip_bin() {
  local bin="${STRIP:-}"
  if [ -z "${bin}" ] \
     && declare -F cross_build_is_active >/dev/null 2>&1 \
     && cross_build_is_active 2>/dev/null \
     && declare -F cross_target_triplet >/dev/null 2>&1; then
    local _trip
    _trip="$(cross_target_triplet 2>/dev/null || true)"
    if [ -n "${_trip}" ] && command -v "${_trip}-strip" >/dev/null 2>&1; then
      bin="${_trip}-strip"
    fi
  fi
  printf '%s' "${bin:-strip}"
}

# strip_media_prefixes [prefix...]: best-effort strip of the media install trees (default set without args), not wheels.
strip_media_prefixes() {
  : "${STRIP_JOBS:=$(nproc)}"
  # The MEDIA_STRIP gate lives here, not at the call sites.
  [ "${MEDIA_STRIP}" = "1" ] || return 0
  local strip_bin jobs="${STRIP_JOBS}" p
  strip_bin="$(_resolve_media_strip_bin)"
  local -a prefixes=("$@")
  if [ "${#prefixes[@]}" -eq 0 ]; then
    prefixes=(
      /opt/ffmpeg /opt/opencv5 /opt/gstreamer /opt/libcamera
      /opt/armnn /opt/acl
      /usr/local/lib/onnxruntime-cpu /usr/local/lib/onnxruntime-genai
    )
  fi
  for p in "${prefixes[@]}"; do
    [ -d "${p}" ] || continue
    strip_elf_tree "${p}" "${jobs}" "${strip_bin}"
  done
}

# strip_media_libs <dir> <glob>...: only matching libs directly under <dir>, for shared prefixes like /usr/local/lib.
strip_media_libs() {
  [ "${MEDIA_STRIP}" = "1" ] || return 0   # DUPN1: gate lives in the helper
  local dir="$1"; shift
  { [ -d "${dir}" ] && [ "$#" -gt 0 ]; } || return 0
  local strip_bin; strip_bin="$(_resolve_media_strip_bin)"
  apply_shared_library_action "${dir}" 1 "$#" "$@" "${strip_bin}" --strip-all
}
