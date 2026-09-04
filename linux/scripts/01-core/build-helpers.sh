#!/usr/bin/env bash
# build-helpers.sh — nerdctl build wrappers and build-arg helpers.
#
[ -n "${_BUILD_HELPERS_LOADED:-}" ] && return 0
_BUILD_HELPERS_LOADED=1
: "${MEDIA_STRIP:=1}"
#
# Provides:
#   _bool_truthy()                — test a value for boolean truthiness
#   is_dry_run()                  — return 0 if DRY_RUN is set to a truthy value
#   arch_list_to_words()          — convert comma-separated arch list to newline-separated (IFS-safe)
#   trap_push()                   — push an EXIT trap handler (preserves existing handlers)
#   run()                         — echo + execute (DO NOT use for secret-bearing args)
#   (run_quiet removed 2026-08-08: zero callers; recover from git history)
#   append_buildkit_host_arg()    — add --buildkit-host if BUILDKIT_HOST is set
#   append_mirror_build_args()    — add USE_FAST_UBUNTU_MIRROR args
#   append_mirror_build_args_from_env() — convenience wrapper
#   append_optional_build_arg()   — add --build-arg only if value is non-empty
#   append_runtime_base_parent_build_arg() — optional BASE_IMAGE for base build
#   append_runtime_accelerator_build_args() — ENABLE_NVIDIA / ENABLE_AMD
#   image_exists()                — check if an image exists locally
#   run_nerdctl_build()           — nerdctl build with BUILDKIT_HOST support
#   strip_elf_tree()              — parallel `strip --strip-all` over an ELF tree

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  "$@"
}

# Test whether a value is boolean-truthy (1, true, TRUE, yes, YES, on, ON).
# Thin alias delegating to the canonical is_truthy() (platform.sh). Kept for
# the existing callers in cross-stage-build.sh, parallel-loop.sh, and
# context-management.sh.
# Usage: _bool_truthy "${DRY_RUN}" && echo "dry run"
#        _bool_truthy "${PARALLEL_ARCHS}" && echo "parallel"
_bool_truthy() {
  is_truthy "${1:-0}"
}

# Returns 0 (true) when DRY_RUN is set to a truthy value (1, true, yes).
# Use this instead of repeating [ "${DRY_RUN:-0}" -eq 1 ] across scripts.
is_dry_run() {
  _bool_truthy "${DRY_RUN:-0}"
}

# Convert a comma/space-separated architecture list to NEWLINE-separated words.
#
# Newlines on purpose: the old space-separated output made every
# `for arch in $(arch_list_to_words ...)` silently stop splitting in scripts
# that set IFS=$'\n\t' (16 call sites carried that latent bug). Both the
# default IFS and the strict $'\n\t' contain \n, so newline output splits
# correctly under either — the bug class is now impossible by construction.
# (`wc -w` and unquoted argv expansion are unaffected.)
arch_list_to_words() {
  printf '%s\n' "${1:-}" | tr ', ' '\n\n'
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
  local archive_url="${3:-${FAST_UBUNTU_MIRROR_URL:-${FAST_UBUNTU_MIRROR_URL_DEFAULT:-$(ubuntu_default_archive_mirror_url)}}}"
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
    "${FAST_UBUNTU_MIRROR_URL:-${FAST_UBUNTU_MIRROR_URL_DEFAULT:-$(ubuntu_default_archive_mirror_url)}}" \
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
  append_version_build_args _acba_out "${2:-}"
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

# ── ELF tree stripping ────────────────────────────────────────────────────────
# Strip every ELF object under <dir> in parallel. Detects ELF files via `file`
# (both executables and shared objects), then pipes them to `strip --strip-all`
# through `xargs -P<jobs>`. Honors ${SUDO}. Best-effort: it never aborts the
# caller (mirrors the `|| true` used by build-clang.sh / build-gcc.sh).
# Centralizes the find|file|awk|xargs strip pattern duplicated in 02-toolchain.
#
# Usage: strip_elf_tree <dir> <jobs> [strip-bin]
#   <jobs>      defaults to $(nproc)
#   <strip-bin> defaults to `strip`; pass a cross <triplet>-strip when stripping
#               a foreign-arch tree.
strip_elf_tree() {
  local dir="$1" jobs="${2:-$(nproc)}" strip_bin="${3:-strip}"
  [ -n "${dir}" ] || return 0
  [ -d "${dir}" ] || return 0
  ${SUDO:-} find "${dir}" -type f -exec file {} + 2>/dev/null \
    | awk -F': *' '/ELF/{print $1}' \
    | xargs -r -P"${jobs}" "${strip_bin}" --strip-all 2>/dev/null || true
}

# _resolve_media_strip_bin — pick the right `strip` for strip_media_prefixes.
# Prefers ${STRIP} (setup_linux_cross_env exports the target <triplet>-strip),
# else derives the cross <triplet>-strip when a cross build is active and the
# cross bin symlinks are on PATH (opencv/litert/onnxruntime build scripts do NOT
# call setup_linux_cross_env, so STRIP is unset there — without this they'd fall
# back to host `strip`, a no-op on foreign ELFs, the AP1 finding). Falls back to
# plain `strip` for native. Fully guarded: every probe `|| true`, missing helpers
# just yield host strip — never aborts a set -e caller.
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

# strip_media_prefixes [prefix...] — AP4: strip symbol tables from the media
# install prefixes. Resolves the strip binary via _resolve_media_strip_bin (cross
# <triplet>-strip when cross, host strip when native), so it works whether or not
# the caller exported ${STRIP}. Best-effort per prefix (each goes through
# strip_elf_tree, which never aborts the caller). With no args, strips the default
# media set. If no cross-strip is resolvable it falls back to host strip and
# leaves foreign ELFs unstripped (a missed size win, never a build break).
#
# NB: not a wheel stripper — wheels carry per-file <triplet>.so that a tree walk
# would still strip correctly, but AP1's wheel-env forwarding is the dedicated
# path for those. This is for the plain /opt/<lib> and /usr/local trees.
strip_media_prefixes() {
  # DUPN1: the MEDIA_STRIP gate lives HERE (not at the 9 call sites) — one
  # authority, call sites keep only the declare -F guard + `|| true`.
  [ "${MEDIA_STRIP}" = "1" ] || return 0
  local strip_bin jobs="${STRIP_JOBS:-$(nproc)}" p
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

# strip_media_libs <dir> <name-glob> [name-glob...] — AP4: strip ONLY the libs
# matching <name-glob>s directly under <dir> (maxdepth 1). For a library that
# installs into a SHARED prefix (e.g. litert into /usr/local/lib, next to the
# base CPython libs) where strip_media_prefixes' whole-tree walk would wrongly
# strip unrelated base libs. Resolves the cross/host strip via
# _resolve_media_strip_bin; --strip-all keeps .dynsym. Best-effort; the caller
# owns the MEDIA_STRIP gate (mirrors strip_media_prefixes).
strip_media_libs() {
  [ "${MEDIA_STRIP}" = "1" ] || return 0   # DUPN1: gate lives in the helper
  local dir="$1"; shift
  { [ -d "${dir}" ] && [ "$#" -gt 0 ]; } || return 0
  local strip_bin; strip_bin="$(_resolve_media_strip_bin)"
  local -a name_expr=()
  local g
  for g in "$@"; do
    if [ "${#name_expr[@]}" -eq 0 ]; then name_expr=( -name "${g}" )
    else name_expr+=( -o -name "${g}" ); fi
  done
  find "${dir}" -maxdepth 1 -type f \( "${name_expr[@]}" \) \
    -exec "${strip_bin}" --strip-all {} + 2>/dev/null || true
}
