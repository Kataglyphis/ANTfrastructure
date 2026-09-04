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


# ---- hand_root_created_paths_to_runtime_user: real find over a real tree, chown stubbed on PATH
_fn_src="$(t_fn_src "${SUBJECT}" hand_root_created_paths_to_runtime_user)" || exit 1

# $1 = RUNTIME_UID. The fixture trees are owned by whoever runs the suite, so
# $(id -u) is the amd64 shape (COPY --chown already did it) and any other uid the
# post-reinstall shape (root created everything). -exec runs the REAL chown, so
# the stub has to be on PATH, not a shell function.
_handover() {
  local tmp stub; tmp="$(mktemp -d)"; stub="${tmp}/stub"
  mkdir -p "${stub}" "${tmp}/rustup/toolchains/1.98.0" "${tmp}/rustup/tmp" "${tmp}/cargo/bin"
  : > "${tmp}/cargo/bin/cargo-cbuild"
  printf '#!/bin/sh\nprintf "chown %%s\\n" "$*"\n' > "${stub}/chown"
  chmod +x "${stub}/chown"
  RUSTUP_HOME="${tmp}/rustup" CARGO_HOME="${tmp}/cargo" RUNTIME_UID="$1" PATH="${stub}:${PATH}" bash -c '
    set -eu
    '"${_fn_src}"'
    hand_root_created_paths_to_runtime_user "${RUSTUP_HOME}" "${CARGO_HOME}"
    echo "rc=$?"' 2>&1 | sed "s#${tmp}#TMP#g"
  rm -rf "${tmp}"
}

t_case "a tree the COPY --chown already owns is not touched"
_out="$(_handover "$(id -u)")"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c '^chown')" \
  "chowning it anyway copies the 2.2 GB rustup/cargo pair up into this layer"
t_assert_contains "${_out}" "owned by uid $(id -u)" "and it still reports the ownership it guarantees"
t_assert_contains "${_out}" "rc=0" "success"

t_case "the root-owned tree the foreign-arch reinstall leaves is handed to the runtime uid"
_out="$(_handover 12345)"
t_assert_contains "${_out}" "chown -h 12345:12345" "-h so a root-owned symlink is retargeted, not its target"
t_assert_contains "${_out}" "TMP/rustup/tmp" "rustup writes its temp files here on every toolchain install"
t_assert_contains "${_out}" "TMP/rustup/toolchains" "and a new toolchain dir here -- 'rustup toolchain install nightly' must work"
t_assert_contains "${_out}" "TMP/cargo/bin/cargo-cbuild" "the apt fallback links wire_cargo_symlinks makes as root"
t_assert_contains "${_out}" "rc=0" "success"

t_case "main hands the toolchain over after BOTH of the writers that run as root"
_main="$(t_fn_src "${SUBJECT}" main)" || exit 1
_at() { printf '%s\n' "${_main}" | grep -n -e "$1" | head -1 | cut -d: -f1; }
_handover_at="$(_at hand_root_created_paths_to_runtime_user)"
t_assert_ok test "$(_at ensure_native_rust_toolchain)" -lt "${_handover_at}"
t_assert_ok test "$(_at wire_cargo_symlinks)" -lt "${_handover_at}"
t_assert_contains "${_main}" 'hand_root_created_paths_to_runtime_user "${RUSTUP_HOME:?}" "${CARGO_HOME:?}"' \
  "both trees, or the half root re-installed stays unwritable at uid 1001"

# ---- bootstrap_flutter_sdk: /opt/flutter is a temp tree; flutter/git/dpkg/assert_elf_arch record their calls
# It carries no chown of its own -- it calls the same handover the rust trees use,
# so the fixture sources both functions and the assertions below are on the helper's
# real find, not a second copy of it.
_fn_src="$(t_fn_src "${SUBJECT}" bootstrap_flutter_sdk)" || exit 1
_handover_src="$(t_fn_src "${SUBJECT}" hand_root_created_paths_to_runtime_user)" || exit 1

# A uid this test does NOT run as, so every fixture path reads as root-created.
_UID_FOREIGN=1001; [ "$(id -u)" != 1001 ] || _UID_FOREIGN=1002

# $1 = whether /opt/flutter/bin/flutter exists (yes|no), $2 = the stub flutter's
# exit code, $3 = what it prints, $4 = RUNTIME_UID. The fixture carries what root
# leaves behind in the real stage (bin/cache, fetched git refs, the flutter_tools
# .dart_tool) beside a framework file the COPY --chown already owned. `chown` is a
# PATH stub because `find -exec` runs the binary, never a shell function. Prints
# the function's output, then "rc=<n>".
_flutter() {
  local present="$1" flutter_rc="$2" flutter_out="$3" uid="$4"
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "${tmp}/bin"
  printf '#!/bin/sh\nprintf "chown %%s\\n" "$*"\n' > "${tmp}/bin/chown"
  chmod +x "${tmp}/bin/chown"
  if [ "${present}" = yes ]; then
    mkdir -p "${tmp}/opt/flutter/bin" \
             "${tmp}/opt/flutter/bin/cache/dart-sdk/bin" \
             "${tmp}/opt/flutter/.git/refs/remotes/origin" \
             "${tmp}/opt/flutter/packages/flutter_tools/.dart_tool" \
             "${tmp}/opt/flutter/packages/flutter/lib"
    : > "${tmp}/opt/flutter/.git/FETCH_HEAD"
    : > "${tmp}/opt/flutter/bin/cache/dart-sdk/bin/dart"
    : > "${tmp}/opt/flutter/packages/flutter_tools/.dart_tool/package_config.json"
    : > "${tmp}/opt/flutter/packages/flutter/lib/material.dart"
    printf '#!/bin/sh\nprintf "%%s\\n" "${FLUTTER_OUT}"; exit "${FLUTTER_RC}"\n' > "${tmp}/opt/flutter/bin/flutter"
    chmod +x "${tmp}/opt/flutter/bin/flutter"
  fi
  PATH="${tmp}/bin:${PATH}" FLUTTER_RC="${flutter_rc}" FLUTTER_OUT="${flutter_out}" RUNTIME_UID="${uid}" bash -c '
    set -eu
    dpkg() { printf "arm64\n"; }
    git() { printf "git %s\n" "$*"; }
    assert_elf_arch() { printf "assert_elf_arch %s\n" "$*"; }
    '"${_handover_src}"'
    '"$(printf '%s\n' "${_fn_src}" | sed "s#/opt/flutter#${tmp}/opt/flutter#g")"'
    bootstrap_flutter_sdk
    echo "rc=$?"' 2>&1 || echo "rc=$?"
  rm -rf "${tmp}"
}

t_case "riscv64's empty /opt/flutter is a no-op"
_out="$(_flutter no 0 "" "${_UID_FOREIGN}")"
t_assert_eq "rc=0" "${_out}" "nothing to bootstrap, nothing printed"

t_case "a flutter that fails to bootstrap fails the stage and shows why"
_out="$(_flutter yes 1 "Downloading Dart SDK from Flutter engine ...
curl: (6) Could not resolve host: storage.googleapis.com" "${_UID_FOREIGN}")"
t_assert_contains "${_out}" "Could not resolve host" "flutter's own output is the diagnosis"
t_assert_contains "${_out}" "ERROR: flutter --version failed while bootstrapping the arm64 Dart SDK" "and it is named as this stage's failure"
t_assert_contains "${_out}" "rc=1" "hard failure"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c '^chown')" "no handover of a broken cache"

t_case "a bootstrap that succeeds proves the Dart SDK's arch and hands EVERY root-created path over"
_out="$(_flutter yes 0 "Flutter 3.47.1 • channel stable • https://github.com/flutter/flutter.git
Tools • Dart 3.13.1 • DevTools 2.60.0" "${_UID_FOREIGN}")"
t_assert_contains "${_out}" "git config --system --add safe.directory" "root needs the safe.directory to read the uid-1001 checkout"
t_assert_contains "${_out}" "Flutter 3.47.1 • channel stable" "the version line is reported"
t_assert_contains "${_out}" "assert_elf_arch /" "the cached dart is checked against the image arch"
t_assert_contains "${_out}" "/bin/cache/dart-sdk/bin/dart arm64" "for the arch dpkg reports"
t_assert_contains "${_out}" "chown -h ${_UID_FOREIGN}:${_UID_FOREIGN} " "-h, so a symlink is retargeted and not its target"
t_assert_contains "${_out}" "/bin/cache/dart-sdk/bin/dart" "the cache root wrote"
t_assert_contains "${_out}" "/packages/flutter_tools/.dart_tool/package_config.json" \
  "the file that made 'flutter pub get' fail for every consumer of the 2026-09-04 image"
t_assert_contains "${_out}" "/.git/FETCH_HEAD" "and the git internals the root-run flutter fetch left behind"
t_assert_contains "${_out}" "/opt/flutter owned by uid ${_UID_FOREIGN}" "the shared handover names the tree it took over"
t_assert_contains "${_out}" "OK: Flutter bootstrapped for arm64" "and the stage says so"
t_assert_contains "${_out}" "rc=0" "success"

t_case "the flutter bootstrap delegates the handover instead of copying the idiom"
t_assert_contains "${_fn_src}" "hand_root_created_paths_to_runtime_user /opt/flutter" \
  "one owner for 'chown exactly what root created', called by both the rust and the flutter site"
t_assert_eq 0 "$(printf '%s\n' "${_fn_src}" | grep -c -e '-exec chown')" \
  "a second copy of the find/chown drifts from the helper the size rule is proven against"

t_case "a tree the runtime user already owns is not chowned at all"
_out="$(_flutter yes 0 "Flutter 3.47.1 • channel stable" "$(id -u)")"
t_assert_eq 0 "$(printf '%s\n' "${_out}" | grep -c '^chown')" \
  "a blanket chown -R would rewrite 716 MB of COPY --chown'd metadata into this layer on every arch"
t_assert_contains "${_out}" "rc=0" "and it still succeeds"


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

t_case "the rustup and cargo COPYs carry --chown, like /opt/flutter's"
for _tree in rustup cargo; do
  _line="$(grep -m1 -e "artifact-source /usr/local/${_tree} " "${_DF_DIR}/Dockerfile.package")"
  t_assert_contains "${_line}" 'COPY --link --chown=${RUNTIME_UID}:${RUNTIME_UID}' \
    "/usr/local/${_tree} root-owned = rustup dies on '\$RUSTUP_HOME/tmp: Permission denied' at uid 1001"
done

t_summary
