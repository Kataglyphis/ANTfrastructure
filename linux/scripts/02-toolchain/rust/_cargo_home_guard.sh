#!/usr/bin/env bash
# Redirect CARGO_HOME to a writable path when the configured one is not
# writable by the current uid.
#
# The runtime image runs as a non-root uid whose CARGO_HOME
# (/usr/local/cargo) is owned by root, so any cargo operation that writes the
# registry or installs a tool dies with "failed to create directory
# .../registry" / "Permission denied (os error 13)". Sourced by every cargo
# step - the build wrapper AND the security-check installer - so the guard
# lives in one place. The probe is a real write into registry/, not `[ -w ]`,
# which reports the root-owned dir as writable to uid 1001 while an actual
# touch is denied.
_cargo_home="${CARGO_HOME:-$HOME/.cargo}"
if ! ( mkdir -p "$_cargo_home/registry" \
       && touch "$_cargo_home/registry/.kata_write_probe" ) 2>/dev/null; then
  export CARGO_HOME="${TMPDIR:-/tmp}/cargo-home"
  mkdir -p "$CARGO_HOME"
  if command -v info >/dev/null 2>&1; then
    info "CARGO_HOME '${_cargo_home}' not writable; using ${CARGO_HOME}"
  else
    echo "CARGO_HOME '${_cargo_home}' not writable; using ${CARGO_HOME}"
  fi
else
  rm -f "$_cargo_home/registry/.kata_write_probe" 2>/dev/null || true
fi
unset _cargo_home
