# shellcheck shell=bash
# Inputs that killed runtime lanes hours in, checked before any arch builds: docs/linux-cross-builds.md#the-runtime-lane-input-preflight
[ -n "${_LIB_RUNTIME_PREFLIGHT_SH_LOADED:-}" ] && return 0
_LIB_RUNTIME_PREFLIGHT_SH_LOADED=1

# shellcheck source=linux/scripts/lib-runtime-switch.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-runtime-switch.sh"

# Installers the package stage executes, as "<pin variable> <url>"; uv is absent because the base ships uv's release binary.
RUNTIME_PREFLIGHT_INSTALLERS=(
  "RUSTUP_INIT_SHA256 https://sh.rustup.rs"
)

# Prints on or off. An unknown value is rc 2, so a typo stops a lane at its start.
runtime_preflight_mode() {
  runtime_switch_mode RUNTIME_INPUT_PREFLIGHT 1 on off "check the inputs" "build without the check"
}

# The package stage's base is built in this run, so its own parent stands in: same release, same sources.
runtime_preflight_parent_image() {
  printf '%s' "${BASE_PARENT_IMAGE:-ubuntu:${UBUNTU_VERSION:?UBUNTU_VERSION is required}@${UBUNTU_DIGEST:?UBUNTU_DIGEST is required}}"
}

# Each pinned installer downloaded again and hashed; rc 1 names every mismatch.
runtime_preflight_installers() {
  local dir spec name url sha rc=0
  dir="$(mktemp -d "${TMPDIR:-/tmp}/runtime-preflight.XXXXXX")" || return 1
  for spec in "${RUNTIME_PREFLIGHT_INSTALLERS[@]}"; do
    name="${spec%% *}"
    url="${spec#* }"
    sha="${!name:-}"
    if [ -z "${sha}" ]; then
      log "[runtime-preflight] ${name} is empty: ${url} is not pinned, not checked"
      continue
    fi
    if download_verified_file "${url}" "${sha}" "${dir}/${name}"; then
      log "[runtime-preflight] OK: ${url} matches ${name}"
    else
      printf '[ERROR] [runtime-preflight] %s no longer matches %s: upstream rotated it; re-verify and bump the pin (bump_versions.py)\n' "${url}" "${name}" >&2
      rc=1
    fi
  done
  rm -rf "${dir}"
  return "${rc}"
}

# <arch>: package-apt-plan.sh in the parent image under linux/<arch>, QEMU for a foreign one.
runtime_preflight_apt_arch() {
  local arch="$1" image scripts="${REPO_ROOT:?}/linux/scripts" a
  local -a mirror=() envs=()
  image="$(runtime_preflight_parent_image)" || return 1
  append_mirror_build_args_from_env mirror
  for a in "${mirror[@]}"; do
    if [ "${a}" = --build-arg ]; then envs+=(-e); else envs+=("${a}"); fi
  done
  "${NERDCTL_BIN:-nerdctl}" run --rm --platform "linux/${arch}" \
    -v "${scripts}/01-core:/opt/scripts/core:ro" \
    -v "${scripts}/06-packaging:/opt/scripts/packaging:ro" \
    -e "TARGET_ARCH=${arch}" \
    -e "PYTHON_VERSION=${PYTHON_VERSION:?PYTHON_VERSION is required}" \
    -e "PYTHON_MAJOR_MINOR=${PYTHON_VERSION%.*}" \
    -e "GCC_VERSION=${GCC_VERSION:?GCC_VERSION is required}" \
    -e "LLVM_RELEASE=${LLVM_RELEASE:?LLVM_RELEASE is required}" \
    -e "JDK_PACKAGE=${JDK_PACKAGE:?JDK_PACKAGE is required}" \
    "${envs[@]}" \
    "${image}" bash /opt/scripts/packaging/package-apt-plan.sh
}

# One worker's output, prefixed with its arch, since the arches run side by side.
_runtime_preflight_apt_worker() {
  runtime_preflight_apt_arch "$1" 2>&1 | sed -u "s/^/[runtime-preflight $1] /"
  return "${PIPESTATUS[0]}"
}

# Call before the first arch builds: refuses the lane on an apt conflict or a rotated installer.
runtime_input_preflight() {
  local mode failed=0
  local -a preflight_arches=()
  mode="$(runtime_preflight_mode)" || return 2
  if [ "${mode}" = off ]; then
    log "[runtime-preflight] RUNTIME_INPUT_PREFLIGHT=0: skipped, the lane builds without it"
    return 0
  fi
  mapfile -t preflight_arches < <(arch_list_to_words "${TARGET_ARCHES:?TARGET_ARCHES is required}" | sed '/^$/d')
  if is_dry_run; then
    log "[DRY RUN] [runtime-preflight] would simulate the package stage's apt set for ${preflight_arches[*]} and re-hash ${#RUNTIME_PREFLIGHT_INSTALLERS[@]} pinned installer(s)"
    return 0
  fi
  log "[runtime-preflight] apt plans for ${preflight_arches[*]} and ${#RUNTIME_PREFLIGHT_INSTALLERS[@]} pinned installer(s) (RUNTIME_INPUT_PREFLIGHT=0 skips this)"
  runtime_preflight_installers || failed=1
  PARALLEL_ARCHS=1 run_parallel_arch_loop _runtime_preflight_apt_worker \
    "$(arch_loop_flag_prefix runtime-preflight-flags)" "${#preflight_arches[@]}" "${preflight_arches[@]}" || failed=1
  if [ "${failed}" -ne 0 ]; then
    printf '[ERROR] [runtime-preflight] refused: the lines above name the input; fix it, or set RUNTIME_INPUT_PREFLIGHT=0 to build anyway\n' >&2
    return 1
  fi
  log "[runtime-preflight] passed: every arch's apt set resolves and every pinned installer matches"
}
