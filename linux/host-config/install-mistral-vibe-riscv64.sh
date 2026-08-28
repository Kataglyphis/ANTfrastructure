#!/usr/bin/env bash
# ==============================================================================
# install-mistral-vibe-riscv64.sh — install the Mistral Vibe CLI on a NATIVE
# riscv64 host (RVA23), from source, with the two riscv64-specific workarounds.
#
# WHY A SCRIPT: `uv tool install mistral-vibe` does not work on riscv64 the way
# it does on amd64/arm64. PyPI ships no riscv64 wheels for this dependency set,
# so uv builds `cryptography`, `pydantic-core` and `textual-speedups` FROM
# SOURCE — which pulls in a Rust toolchain, a C toolchain, OpenSSL headers and
# the CPython headers, none of which uv installs for you. The two failures you
# hit are unrelated to each other and their error text points nowhere useful:
#
#   1. `cryptography` fails to link — it needs libssl/libffi dev packages and a
#      working `pkg-config openssl`, not just the `openssl` binary.
#   2. `textual-speedups` fails to build for the RVA23 target — it pins a
#      `target-lexicon` old enough that it does not know the
#      `riscv64a23-unknown-linux-gnu` triple, so the build script rejects the
#      target before compiling anything. It is a pure OPTIONAL speedup (a Rust
#      accelerator for Textual's CSS/layout), so dropping the dependency costs
#      TUI performance and nothing else. Vibe runs without it.
#
# The build target matters: this host's Rust is configured for the native RVA23
# profile (`riscv64a23-unknown-linux-gnu`), NOT the generic
# `riscv64gc-unknown-linux-gnu`. Leaving CARGO_BUILD_TARGET unset makes cargo
# use the host default, which is what you want on a stock riscv64 box and what
# you do NOT want here — hence the override, and hence workaround 2.
#
# WHAT IT DOES
#   - installs the native build dependencies with apt (needs INTERACTIVE sudo)
#   - prints the OpenSSL / Rust / Python facts it is building against
#   - clears the uv build cache for the two packages that fail half-built
#   - clones mistral-vibe into a scratch tree, drops textual-speedups, installs
#   - proves the result by running `mistral-vibe --version`
#
# USAGE
#   bash linux/host-config/install-mistral-vibe-riscv64.sh
#
#   VIBE_SRC_DIR=/tmp/mistral-vibe   where to clone (wiped and re-cloned)
#   VIBE_REF=<tag|branch|sha>        pin a revision instead of the default HEAD
#   VIBE_SKIP_APT=1                  skip the apt step (already installed)
#   VIBE_KEEP_SPEEDUPS=1             do NOT drop textual-speedups (see above)
#   CARGO_BUILD_TARGET=<triple>      override the RVA23 default
#
# Full write-up, including what to do when a NEW dependency starts failing:
# docs/linux-host-setup.md § "D4. Python CLI tools that build from source on
# riscv64".
# ==============================================================================
set -euo pipefail

VIBE_REPO="${VIBE_REPO:-https://github.com/mistralai/mistral-vibe.git}"
VIBE_SRC_DIR="${VIBE_SRC_DIR:-/tmp/mistral-vibe}"
VIBE_REF="${VIBE_REF:-}"
VIBE_SKIP_APT="${VIBE_SKIP_APT:-0}"
VIBE_KEEP_SPEEDUPS="${VIBE_KEEP_SPEEDUPS:-0}"

# The native RVA23 triple this host's Rust is set up for. Override for a stock
# riscv64 box: CARGO_BUILD_TARGET=riscv64gc-unknown-linux-gnu.
export CARGO_BUILD_TARGET="${CARGO_BUILD_TARGET:-riscv64a23-unknown-linux-gnu}"
export RUSTFLAGS="${RUSTFLAGS:--C target-cpu=native}"

# Python headers: whatever `python3` is, we need ITS -dev package. Resolved
# rather than hardcoded so this does not rot the next time the host moves to a
# newer CPython.
PY_MINOR="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"

log() { printf '[vibe] %s\n' "$*"; }
die() { printf '[vibe] ERROR: %s\n' "$*" >&2; exit 1; }

# --- 0. sanity ---------------------------------------------------------------
arch="$(uname -m)"
[ "$arch" = "riscv64" ] || log "WARNING: host is ${arch}, not riscv64 — the workarounds below are riscv64-specific but harmless elsewhere."

# uv installs itself under ~/.local/bin and is not on a login PATH by default.
if [ -f "$HOME/.local/bin/env" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.local/bin/env"
fi
export PATH="$HOME/.local/bin:$PATH"

command -v uv    >/dev/null 2>&1 || die "uv not found. Install it: curl -LsSf https://astral.sh/uv/install.sh | sh"
command -v cargo >/dev/null 2>&1 || die "cargo not found — cryptography/pydantic-core are built from source on riscv64 and need a Rust toolchain (rustup)."
command -v git   >/dev/null 2>&1 || die "git not found."

# --- 1. native build dependencies --------------------------------------------
# Needs interactive sudo — an agent cannot run this step unattended.
if [ "$VIBE_SKIP_APT" = "1" ]; then
  log "skipping apt (VIBE_SKIP_APT=1)"
else
  log "installing native build dependencies (sudo)"
  sudo apt update
  pkgs=(build-essential pkg-config libffi-dev libssl-dev openssl)
  if [ -n "$PY_MINOR" ]; then pkgs+=("python${PY_MINOR}-dev"); fi
  sudo apt install -y "${pkgs[@]}"
fi

# --- 2. print what we are building against -----------------------------------
# These four lines are the whole diagnosis when a source build fails later:
# a missing openssl.pc, a host triple that is not the one cargo targets, or a
# python3 whose headers were never installed.
log "OpenSSL:        $(openssl version)"
log "openssl.pc:     $(pkg-config --modversion openssl 2>/dev/null || echo 'MISSING — libssl-dev not installed for this arch')"
log "rust host:      $(rustc -vV | sed -n 's/^host: //p')"
log "cargo target:   ${CARGO_BUILD_TARGET}"
log "python3:        $(python3 -V 2>&1)"

# --- 3. drop half-built cache entries ----------------------------------------
# A failed source build leaves a poisoned entry behind; the retry then "succeeds"
# from cache or fails identically for a reason you already fixed.
for pkg in cryptography textual-speedups pydantic-core; do
  uv cache clean "$pkg" >/dev/null 2>&1 || true
done
log "uv cache cleaned for the source-built packages"

# --- 4. clean source tree ----------------------------------------------------
case "$VIBE_SRC_DIR" in
  /|"$HOME"|"") die "refusing to wipe VIBE_SRC_DIR='${VIBE_SRC_DIR}'";;
esac
log "cloning ${VIBE_REPO} -> ${VIBE_SRC_DIR}"
rm -rf "$VIBE_SRC_DIR"
git clone "$VIBE_REPO" "$VIBE_SRC_DIR"
if [ -n "$VIBE_REF" ]; then
  git -C "$VIBE_SRC_DIR" checkout --detach "$VIBE_REF"
  log "pinned to ${VIBE_REF}"
fi

# --- 5. workaround: textual-speedups does not know the RVA23 triple ----------
if [ "$VIBE_KEEP_SPEEDUPS" = "1" ]; then
  log "keeping textual-speedups (VIBE_KEEP_SPEEDUPS=1) — expect a target-lexicon build failure on RVA23"
elif grep -q 'textual-speedups' "$VIBE_SRC_DIR/pyproject.toml"; then
  sed -i '/textual-speedups/d' "$VIBE_SRC_DIR/pyproject.toml"
  log "dropped textual-speedups from pyproject.toml (optional TUI accelerator; its pinned target-lexicon predates ${CARGO_BUILD_TARGET})"
else
  # Upstream may have bumped or removed it — say so instead of silently passing.
  log "textual-speedups not present in pyproject.toml — workaround no longer needed?"
fi

# --- 6. install --------------------------------------------------------------
log "uv tool install . (source builds ahead: cryptography, pydantic-core — minutes, not seconds)"
( cd "$VIBE_SRC_DIR" && uv tool install . )

# --- 7. prove it -------------------------------------------------------------
export PATH="$HOME/.local/bin:$PATH"
command -v mistral-vibe >/dev/null 2>&1 \
  || die "mistral-vibe not on PATH after install — add \$HOME/.local/bin to PATH (uv tool update-shell)."
log "installed: $(mistral-vibe --version)"
