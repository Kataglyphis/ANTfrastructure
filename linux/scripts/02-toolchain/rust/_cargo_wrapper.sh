#!/usr/bin/env bash
# _cargo_wrapper.sh — shared scaffolding for the single-command cargo_*.sh
# step wrappers. Sourced (not executed) by cargo_bench.sh / cargo_debug.sh /
# cargo_test.sh, which reduce to a single cargo_step call. Keeping each wrapper
# as its own file preserves the "invoked by name" contract.
set -euo pipefail

_CARGO_WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_CARGO_WRAPPER_DIR/../../01-core/logging.sh"

# The runtime image runs as a non-root uid whose CARGO_HOME
# (/usr/local/cargo) is owned by root, so cargo dies with
# "failed to create directory .../registry". When the configured CARGO_HOME
# cannot be written, fall back to a writable one under TMPDIR rather than
# requiring the image to hand us its own. Same fix as the C++ lane's
# cmake-configure-build.sh; kept here so every cargo_*.sh inherits it.
#
# The probe is an ACTUAL write into registry/, not `[ -w ]`: on this image
# `[ -w /usr/local/cargo ]` reports the root-owned dir as writable to uid 1001
# while a real touch is denied, so the -w test silently fails to trigger.
_cargo_home="${CARGO_HOME:-$HOME/.cargo}"
if ! ( mkdir -p "$_cargo_home/registry" \
       && touch "$_cargo_home/registry/.kata_write_probe" ) 2>/dev/null; then
  export CARGO_HOME="${TMPDIR:-/tmp}/cargo-home"
  mkdir -p "$CARGO_HOME"
  info "CARGO_HOME '${_cargo_home}' not writable; using ${CARGO_HOME}"
else
  rm -f "$_cargo_home/registry/.kata_write_probe" 2>/dev/null || true
fi
unset _cargo_home

# cargo_step <start-msg> <done-msg> -- <command...>
# Logs <start-msg>, runs <command...>, then logs <done-msg>. The `--` separates
# the two message args from the command so messages may contain spaces.
cargo_step() {
  local start_msg="$1" done_msg="$2"
  shift 2
  [ "${1:-}" = "--" ] && shift
  info "${start_msg}"
  "$@"
  info "${done_msg}"
}
