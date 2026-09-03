#!/usr/bin/env bash
# setup-package-image.sh helpers run off-target with their collaborators stubbed:
#   ensure_native_rust_toolchain  docs/failure-modes.md#the-copied-rust-toolchain-is-the-builders-arch
#   bootstrap_flutter_sdk         docs/artifact-copy-completeness.md#bootstrapping-flutter-in-the-package-stage
# Plus the uid the chown and the useradd must agree on, across two Dockerfiles.
#   docs/artifact-copy-completeness.md#the-runtime-uid-is-a-contract
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../06-packaging/setup-package-image.sh"

# ---- ensure_native_rust_toolchain: RUSTUP_HOME/CARGO_HOME are temp dirs, dpkg and the installer stubs
_fn_src="$(t_fn_src "${SUBJECT}" ensure_native_rust_toolchain)" || exit 1

# $1 = image arch (what dpkg reports), $2.. = toolchain dirs to pre-create.
# Prints the function's output, then "installer=<args or none>" and the
# surviving toolchain dirs.
_rust() {
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
_out="$(_rust arm64 1.98.0-x86_64-unknown-linux-gnu nightly-2026-06-28-x86_64-unknown-linux-gnu)"
t_assert_contains "${_out}" "is not aarch64-unknown-linux-gnu" "the mismatch must be named"
t_assert_contains "${_out}" "installer=/opt/scripts/toolchain/install-rust.sh cargo_c=0 mode=native" \
  "the toolchain stage's installer, without the QEMU-hostile cargo-c compile"
t_assert_contains "${_out}" "left=" "both trees are wiped before the install"
t_assert_eq "left=" "$(printf '%s\n' "${_out}" | grep '^left=')" "no x86_64 dir survives"

t_case "an arm64 image with a native toolchain is left alone"
_out="$(_rust arm64 1.98.0-aarch64-unknown-linux-gnu)"
t_assert_contains "${_out}" "is native (aarch64-unknown-linux-gnu)" "native toolchain recognised"
t_assert_contains "${_out}" "left=1.98.0-aarch64-unknown-linux-gnu" "and kept"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c '^installer=')" "no reinstall"

t_case "amd64 (host == target) is a no-op"
_out="$(_rust amd64 1.98.0-x86_64-unknown-linux-gnu)"
t_assert_contains "${_out}" "is native (x86_64-unknown-linux-gnu)" "the copied toolchain IS native there"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c '^installer=')" "no reinstall on amd64"

t_case "an empty RUSTUP_HOME (the 2026-08-07 missing-COPY shape) installs natively"
_out="$(_rust riscv64)"
t_assert_contains "${_out}" "installer=/opt/scripts/toolchain/install-rust.sh cargo_c=0 mode=native" "self-heals instead of shipping apt's rustc"


# ---- bootstrap_flutter_sdk: /opt/flutter is a temp tree; flutter/git/dpkg/chown/assert_elf_arch record their calls
_fn_src="$(t_fn_src "${SUBJECT}" bootstrap_flutter_sdk)" || exit 1

# $1 = whether /opt/flutter/bin/flutter exists (yes|no), $2 = the stub flutter's
# exit code, $3 = what it prints. Prints the function's output, then "rc=<n>".
_flutter() {
  local present="$1" flutter_rc="$2" flutter_out="$3"
  local tmp; tmp="$(mktemp -d)"
  if [ "${present}" = yes ]; then
    mkdir -p "${tmp}/opt/flutter/bin"
    printf '#!/bin/sh\nprintf "%%s\\n" "${FLUTTER_OUT}"; exit "${FLUTTER_RC}"\n' > "${tmp}/opt/flutter/bin/flutter"
    chmod +x "${tmp}/opt/flutter/bin/flutter"
  fi
  FLUTTER_RC="${flutter_rc}" FLUTTER_OUT="${flutter_out}" RUNTIME_UID=1001 bash -c '
    set -eu
    dpkg() { printf "arm64\n"; }
    git() { printf "git %s\n" "$*"; }
    chown() { printf "chown %s\n" "$*"; }
    assert_elf_arch() { printf "assert_elf_arch %s\n" "$*"; }
    '"$(printf '%s\n' "${_fn_src}" | sed "s#/opt/flutter#${tmp}/opt/flutter#g")"'
    bootstrap_flutter_sdk
    echo "rc=$?"' 2>&1 || echo "rc=$?"
  rm -rf "${tmp}"
}

t_case "riscv64's empty /opt/flutter is a no-op"
_out="$(_flutter no 0 "")"
t_assert_eq "rc=0" "${_out}" "nothing to bootstrap, nothing printed"

t_case "a flutter that fails to bootstrap fails the stage and shows why"
_out="$(_flutter yes 1 "Downloading Dart SDK from Flutter engine ...
curl: (6) Could not resolve host: storage.googleapis.com")"
t_assert_contains "${_out}" "Could not resolve host" "flutter's own output is the diagnosis"
t_assert_contains "${_out}" "ERROR: flutter --version failed while bootstrapping the arm64 Dart SDK" "and it is named as this stage's failure"
t_assert_contains "${_out}" "rc=1" "hard failure"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c '^chown')" "no handover of a broken cache"

t_case "a bootstrap that succeeds proves the Dart SDK's arch and hands the cache to the runtime user"
_out="$(_flutter yes 0 "Flutter 3.47.1 • channel stable • https://github.com/flutter/flutter.git
Tools • Dart 3.13.1 • DevTools 2.60.0")"
t_assert_contains "${_out}" "git config --system --add safe.directory" "root needs the safe.directory to read the uid-1001 checkout"
t_assert_contains "${_out}" "Flutter 3.47.1 • channel stable" "the version line is reported"
t_assert_contains "${_out}" "assert_elf_arch /" "the cached dart is checked against the image arch"
t_assert_contains "${_out}" "/bin/cache/dart-sdk/bin/dart arm64" "for the arch dpkg reports"
t_assert_contains "${_out}" "chown -R 1001:1001 /" "the root-written cache is handed to the runtime user"
t_assert_contains "${_out}" "OK: Flutter bootstrapped for arm64, bin/cache owned by uid 1001" "and the stage says so"
t_assert_contains "${_out}" "rc=0" "success"

# ---- the chown target (Dockerfile.package) and the user (Dockerfile.torch)
_DF_DIR="${TESTS_DIR}/../.."
_uid_arg() { grep -oP '(?<=^ARG RUNTIME_UID=)\d+' "${_DF_DIR}/$1" | head -1; }

t_case "both Dockerfiles default RUNTIME_UID to the same uid"
t_assert_eq "$(_uid_arg Dockerfile.package)" "$(_uid_arg Dockerfile.torch)" \
  "package chowns /opt/flutter to it, torch creates the user with it"
t_assert_eq "1001" "$(_uid_arg Dockerfile.package)" "and it is the uid the smokes assert"

t_case "Dockerfile.torch pins useradd to that uid and proves it"
_useradd="$(grep -m1 'useradd' "${_DF_DIR}/Dockerfile.torch")"
t_assert_contains "${_useradd}" 'useradd -m -l -u ${RUNTIME_UID}' \
  "without -u the first free uid wins, which is 1001 only by luck"
t_assert_contains "$(grep -A1 'useradd' "${_DF_DIR}/Dockerfile.torch")" 'id -u kataglyphis' \
  "a base image that already owns the uid must fail the build, not ship a mismatch"

t_summary
