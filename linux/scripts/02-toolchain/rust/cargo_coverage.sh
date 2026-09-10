#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../01-core/logging.sh"

# The tarpaulin pin comes from versions.env, through the SAFE loader and never
# `source`: that file is inert data whose values may contain shell
# metacharacters (CUDA_ARCHITECTURES=80;86;89;90 once ran three arch numbers as
# commands). Until 2026-09-09 the line below was a bare `cargo install
# cargo-tarpaulin`, so the tool that produces a consumer's coverage number was
# whatever crates.io served that minute — a number that moves on its own is not
# a measurement, and a coverage ratchet cannot be built on one.
# shellcheck source=../../01-core/load-versions-env.sh
source "$SCRIPT_DIR/../../01-core/load-versions-env.sh"
load_versions_env "$SCRIPT_DIR/../../01-core/versions.env"
[ -n "${CARGO_TARPAULIN_VERSION:-}" ] || err "CARGO_TARPAULIN_VERSION is not set (versions.env not found?)."

info "Installing cargo-tarpaulin ${CARGO_TARPAULIN_VERSION}..."
# --locked as well as --version: the version alone still resolves the crate's
# DEPENDENCIES freshly on every run, which is the same floating build by a
# smaller name.
cargo install --locked --version "${CARGO_TARPAULIN_VERSION}" cargo-tarpaulin

info "Running coverage with tarpaulin..."
# Forward any arguments (for example: --features <feature>) to cargo-tarpaulin
cargo tarpaulin --ignore-tests --out Html --out Xml --engine llvm "$@"

info "Coverage report generated successfully."
