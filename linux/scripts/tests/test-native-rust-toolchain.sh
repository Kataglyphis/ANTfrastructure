#!/usr/bin/env bash
# ensure_native_rust_toolchain off-target: RUSTUP_HOME/CARGO_HOME are temp dirs,
# dpkg and the installer are stubs. docs/failure-modes.md#the-copied-rust-toolchain-is-the-builders-arch
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../06-packaging/setup-package-image.sh"
_fn_src="$(awk '/^ensure_native_rust_toolchain\(\) \{$/,/^\}$/' "${SUBJECT}")"
[ -n "${_fn_src}" ] || { echo "FAIL: ensure_native_rust_toolchain not found in ${SUBJECT}"; exit 1; }

# $1 = image arch (what dpkg reports), $2.. = toolchain dirs to pre-create.
# Prints the function's output, then "installer=<args or none>" and the
# surviving toolchain dirs.
_run() {
  local arch="$1"; shift
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "${tmp}/rustup/toolchains" "${tmp}/cargo/bin"
  local d; for d in "$@"; do mkdir -p "${tmp}/rustup/toolchains/${d}"; done
  RUSTUP_HOME="${tmp}/rustup" CARGO_HOME="${tmp}/cargo" IMG_ARCH="${arch}" bash -c '
    set -eu
    dpkg() { printf "%s\n" "${IMG_ARCH}"; }
    rust_target_triple_for_arch() {
      case "$1" in amd64) echo x86_64-unknown-linux-gnu;; arm64) echo aarch64-unknown-linux-gnu;;
                   riscv64) echo riscv64gc-unknown-linux-gnu;; *) return 1;; esac; }
    bash() { printf "installer=%s cargo_c=%s mode=%s\n" "$*" "${RUST_INSTALL_CARGO_C:-unset}" "${BUILD_MODE:-unset}"; }
    '"${_fn_src}"'
    ensure_native_rust_toolchain
    printf "left=%s\n" "$(ls "${RUSTUP_HOME}/toolchains" 2>/dev/null | tr "\n" " ")"' 2>&1
  rm -rf "${tmp}"
}

t_case "an arm64 image holding the builder's x86_64 toolchain reinstalls natively"
_out="$(_run arm64 1.98.0-x86_64-unknown-linux-gnu nightly-2026-06-28-x86_64-unknown-linux-gnu)"
t_assert_contains "${_out}" "is not aarch64-unknown-linux-gnu" "the mismatch must be named"
t_assert_contains "${_out}" "installer=/opt/scripts/toolchain/install-rust.sh cargo_c=0 mode=native" \
  "the toolchain stage's installer, without the QEMU-hostile cargo-c compile"
t_assert_contains "${_out}" "left=" "both trees are wiped before the install"
t_assert_eq "left=" "$(printf '%s\n' "${_out}" | grep '^left=')" "no x86_64 dir survives"

t_case "an arm64 image with a native toolchain is left alone"
_out="$(_run arm64 1.98.0-aarch64-unknown-linux-gnu)"
t_assert_contains "${_out}" "is native (aarch64-unknown-linux-gnu)" "native toolchain recognised"
t_assert_contains "${_out}" "left=1.98.0-aarch64-unknown-linux-gnu" "and kept"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c '^installer=')" "no reinstall"

t_case "amd64 (host == target) is a no-op"
_out="$(_run amd64 1.98.0-x86_64-unknown-linux-gnu)"
t_assert_contains "${_out}" "is native (x86_64-unknown-linux-gnu)" "the copied toolchain IS native there"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c '^installer=')" "no reinstall on amd64"

t_case "an empty RUSTUP_HOME (the 2026-08-07 missing-COPY shape) installs natively"
_out="$(_run riscv64)"
t_assert_contains "${_out}" "installer=/opt/scripts/toolchain/install-rust.sh cargo_c=0 mode=native" "self-heals instead of shipping apt's rustc"

t_summary
