#!/usr/bin/env bash
# Rustc wrapper for Meson cross builds; the __RUSTC_BIN__/__RUST_TARGET__ placeholders are substituted at build time.

set -euo pipefail

RUSTC_BIN="__RUSTC_BIN__"
RUST_TARGET="__RUST_TARGET__"

want_target="${RUST_TARGET}"
have_target=false
expect_target_value=false
cargo_managed=false

for arg in "$@"; do
  if [ "${expect_target_value}" = "true" ]; then
    have_target=true
    expect_target_value=false
    continue
  fi

  case "${arg}" in
    --target)
      expect_target_value=true
      ;;
    --target=*)
      have_target=true
      ;;
    */target/*)
      cargo_managed=true
      ;;
  esac
done

if [ "${have_target}" = "true" ]; then
  exec "${RUSTC_BIN}" "$@"
fi

if [ "${cargo_managed}" = "true" ]; then
  exec "${RUSTC_BIN}" "$@"
fi

exec "${RUSTC_BIN}" --target "${want_target}" "$@"
