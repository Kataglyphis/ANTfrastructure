#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../01-core/modules.sh"
source_modules_framework "${SCRIPT_DIR}"
source_module common.sh

# Provide fallback build helpers if not loaded from common.sh
build_init() { local ws="$1" logd="$2"; _BUILD_WORKSPACE="${ws}"; mkdir -p "${logd}"; }
build_log()  { printf '[BUILD] %s\n' "$*"; }
build_run_step() { local label="$1"; shift; printf '[STEP] %s: ' "${label}"; "$@" && printf 'OK\n' || { printf 'FAIL\n'; return 1; }; }
build_warn() { printf '[WARN] %s\n' "$*" >&2; }
build_finish() { exit "${1:-0}"; }

Workspace="${WORKSPACE:-$PWD}"
Binary="${BINARY:-}"
Version="${VERSION:-}"
SkipSecurity="${SKIP_SECURITY:-false}"
SkipBench="${SKIP_BENCH:-false}"

build_init "$Workspace" "logs"

build_log "=== Build Environment ==="
build_log "Workspace: $_BUILD_WORKSPACE"
build_log "BINARY: $Binary"
build_log "VERSION: $Version"

cd "$_BUILD_WORKSPACE"

build_run_step "Verify Toolchain" rustup --version  || true
build_run_step "Verify Cargo" cargo --version || true

if [ "$SkipSecurity" != "true" ]; then
  build_run_step "Security Checks (audit & deny)" bash -c '
    cargo install --locked cargo-audit cargo-deny 2>/dev/null || true
    cargo audit 2>/dev/null || warn "cargo audit failed, continuing..."
    cargo deny check advisories licenses bans sources 2>/dev/null || warn "cargo deny failed, continuing..."
  ' || build_warn "Security checks completed with warnings"
fi

  build_run_step "Format Check" bash -c '
  rustup component add rustfmt 2>/dev/null || true
  cargo fmt --all -- --check
'

  build_run_step "Linting (cargo clippy)" bash -c '
  rustup component add clippy 2>/dev/null || true
  cargo clippy --all-targets --all-features -- -D warnings
'

  build_run_step "Unit Tests" cargo test --all --verbose

if [ "$SkipBench" != "true" ]; then
  build_run_step "Benchmarks" bash -c 'cargo bench "$@"' || build_warn "Benchmarks skipped or failed"
fi

  build_run_step "Release Build" bash -c 'cargo build --release "$@"'

build_finish 0
