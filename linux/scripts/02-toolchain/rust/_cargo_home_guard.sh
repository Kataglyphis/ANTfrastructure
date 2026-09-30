#!/usr/bin/env bash
# Redirect a CARGO_HOME this uid cannot write (root-owned in the runtime image); probe with a real write, as [ -w ] lies.
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
