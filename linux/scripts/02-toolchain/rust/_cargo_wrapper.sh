#!/usr/bin/env bash
# Scaffolding for the one-command cargo_*.sh wrappers, which stay separate files so callers invoke them by name.
set -euo pipefail

_CARGO_WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_CARGO_WRAPPER_DIR/../../01-core/logging.sh"

# Writable-CARGO_HOME guard: cargo install and every build write under it.
# shellcheck source=/dev/null
source "$_CARGO_WRAPPER_DIR/_cargo_home_guard.sh"

# The images also carry Ubuntu's Rust debs, which would otherwise mix into the pinned toolchain.
# shellcheck source=/dev/null
source "$_CARGO_WRAPPER_DIR/_rust_toolchain_guard.sh"

# Uid 1001 does not own a bind-mounted checkout, so git refuses it as dubious ownership; an empty value opts out, as in lib/cmake-build.sh.
_cargo_safe_dir="${CARGO_SAFE_DIRECTORY-/workspace}"
if [ -n "${_cargo_safe_dir}" ] \
   && ! git config --global --get-all safe.directory 2>/dev/null | grep -qxF -- "${_cargo_safe_dir}"; then
  git config --global --add safe.directory "${_cargo_safe_dir}" || true
fi

# Opt-in (KATAGLYPHIS_LINKER); a value that cannot link stops here, under set -e.
# shellcheck source=/dev/null
source "$_CARGO_WRAPPER_DIR/../../lib/linker-select.sh"
linker_select_env

# cargo_install_pinned <crate> <version> [binary]; the image ships these pinned (CON65), so only a bare host builds one.
cargo_install_pinned() {
  local crate="$1" version="$2" bin="${3:-$1}" have
  have="$("${bin}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  if [ "${have}" = "${version}" ]; then
    info "${crate} ${version} is already on PATH; not building it"
    return 0
  fi
  info "Installing ${crate} ${version}${have:+ (found ${have})}"
  # --locked too: --version alone still resolves the crate's dependencies afresh.
  cargo install --locked --version "${version}" "${crate}"
}

# cargo_step <start-msg> <done-msg> -- <command...>; the -- lets messages contain spaces.
cargo_step() {
  local start_msg="$1" done_msg="$2"
  shift 2
  [ "${1:-}" = "--" ] && shift
  info "${start_msg}"
  "$@"
  info "${done_msg}"
}
