#!/usr/bin/env bash
# Installs Mistral Vibe from source on a native RVA23 riscv64 host: docs/linux-host-setup.md#d4-python-cli-tools-that-build-from-source-on-riscv64
set -euo pipefail

VIBE_REPO="${VIBE_REPO:-https://github.com/mistralai/mistral-vibe.git}"
VIBE_SRC_DIR="${VIBE_SRC_DIR:-/tmp/mistral-vibe}"
VIBE_REF="${VIBE_REF:-}"
VIBE_SKIP_APT="${VIBE_SKIP_APT:-0}"
VIBE_KEEP_SPEEDUPS="${VIBE_KEEP_SPEEDUPS:-0}"

# This host's native RVA23 triple; a stock riscv64 box wants riscv64gc-unknown-linux-gnu.
export CARGO_BUILD_TARGET="${CARGO_BUILD_TARGET:-riscv64a23-unknown-linux-gnu}"
export RUSTFLAGS="${RUSTFLAGS:--C target-cpu=native}"

# Resolved, not hardcoded, so the -dev package follows the host's python3.
PY_MINOR="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"

log() { printf '[vibe] %s\n' "$*"; }
die() { printf '[vibe] ERROR: %s\n' "$*" >&2; exit 1; }

# 0. Sanity
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

# 1. Native build dependencies (interactive sudo, so an agent cannot run this step)
if [ "$VIBE_SKIP_APT" = "1" ]; then
  log "skipping apt (VIBE_SKIP_APT=1)"
else
  log "installing native build dependencies (sudo)"
  sudo apt update
  pkgs=(build-essential pkg-config libffi-dev libssl-dev openssl)
  if [ -n "$PY_MINOR" ]; then pkgs+=("python${PY_MINOR}-dev"); fi
  sudo apt install -y "${pkgs[@]}"
fi

# 2. What we build against: the whole diagnosis when a source build fails later
log "OpenSSL:        $(openssl version)"
log "openssl.pc:     $(pkg-config --modversion openssl 2>/dev/null || echo 'MISSING — libssl-dev not installed for this arch')"
log "rust host:      $(rustc -vV | sed -n 's/^host: //p')"
log "cargo target:   ${CARGO_BUILD_TARGET}"
log "python3:        $(python3 -V 2>&1)"

# 3. A failed source build leaves a poisoned cache entry that a retry would reuse
for pkg in cryptography textual-speedups pydantic-core; do
  uv cache clean "$pkg" >/dev/null 2>&1 || true
done
log "uv cache cleaned for the source-built packages"

# 4. Clean source tree
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

# 5. textual-speedups' pinned target-lexicon predates the RVA23 triple; it is an optional accelerator
if [ "$VIBE_KEEP_SPEEDUPS" = "1" ]; then
  log "keeping textual-speedups (VIBE_KEEP_SPEEDUPS=1) — expect a target-lexicon build failure on RVA23"
elif grep -q 'textual-speedups' "$VIBE_SRC_DIR/pyproject.toml"; then
  sed -i '/textual-speedups/d' "$VIBE_SRC_DIR/pyproject.toml"
  log "dropped textual-speedups from pyproject.toml (optional TUI accelerator; its pinned target-lexicon predates ${CARGO_BUILD_TARGET})"
else
  # Upstream may have bumped or removed it — say so instead of silently passing.
  log "textual-speedups not present in pyproject.toml — workaround no longer needed?"
fi

# 6. Install
log "uv tool install . (source builds ahead: cryptography, pydantic-core — minutes, not seconds)"
( cd "$VIBE_SRC_DIR" && uv tool install . )

# 7. Prove it
export PATH="$HOME/.local/bin:$PATH"
command -v mistral-vibe >/dev/null 2>&1 \
  || die "mistral-vibe not on PATH after install — add \$HOME/.local/bin to PATH (uv tool update-shell)."
log "installed: $(mistral-vibe --version)"
