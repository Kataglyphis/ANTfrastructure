#!/usr/bin/env bash
# cargo_build_doc.sh: every workspace member unless the caller picked the packages, on the pinned nightly with docs.rs links. See docs/docs-sites.md#links-into-dependencies
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
DRIVER="$(cd "${TESTS_DIR}/../02-toolchain/rust" && pwd)/cargo_build_doc.sh"
VERSIONS_ENV="${TESTS_DIR}/../01-core/versions.env"

_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT

WORKSPACE_TOML='[workspace]
members = ["crates/a"]

[package]
name = "root-crate"'
PACKAGE_TOML='[package]
name = "solo"'
PIN=nightly-2099-01-01
MAP="-Zrustdoc-map --config doc.extern-map.registries.crates-io=\"https://docs.rs/\""

# _doc_run <Cargo.toml text> [driver args...]: the driver under a cargo function that logs its doc call; prints the driver's output, then the call.
_doc_run() {
  local dir rc=0
  dir="$(mktemp -d "${_WORK}/crate.XXXXXX")"
  printf '%s\n' "$1" > "${dir}/Cargo.toml"
  shift
  # A function, not a stub on PATH: the toolchain guard hoists the image's own cargo ahead of PATH.
  (cd "${dir}" && env HOME="${dir}" CARGO_HOME="${dir}/cargo-home" CARGO_SAFE_DIRECTORY= DOC_LOG="${dir}/cargo.log" \
    bash -c 'cargo() {
        case "$1" in +*) [ "$1" = "+${STUB_TOOLCHAIN:-}" ] || return 1 ;; esac
        if [ "$2" = doc ]; then echo "cargo $*" >> "${DOC_LOG}"; mkdir -p target/doc; fi
      }
      export -f cargo; bash "$@"' _ "${DRIVER}" "$@" 2>&1) || rc=$?
  printf 'rc=%s\n' "${rc}"
  cat "${dir}/cargo.log" 2>/dev/null
}

# _doc_call <Cargo.toml text> [driver args...]: the doc call alone, on the PIN toolchain.
_doc_call() {
  RUST_NIGHTLY_TOOLCHAIN="${PIN}" STUB_TOOLCHAIN="${PIN}" _doc_run "$@" | grep '^cargo '
}

t_case "a [workspace] manifest documents every member"
t_assert_eq "cargo +${PIN} doc ${MAP} --no-deps --workspace" "$(_doc_call "${WORKSPACE_TOML}")" \
  "without --workspace cargo doc documents the root package alone"
t_assert_eq "cargo +${PIN} doc ${MAP} --no-deps --workspace --features gstreamer" "$(_doc_call "${WORKSPACE_TOML}" --features gstreamer)" \
  "the caller's arguments still follow"

t_case "a caller that picked the packages keeps its choice"
t_assert_eq "cargo +${PIN} doc ${MAP} --no-deps -p core" "$(_doc_call "${WORKSPACE_TOML}" -p core)"
t_assert_eq "cargo +${PIN} doc ${MAP} --no-deps -pcore" "$(_doc_call "${WORKSPACE_TOML}" -pcore)"
t_assert_eq "cargo +${PIN} doc ${MAP} --no-deps --package=core" "$(_doc_call "${WORKSPACE_TOML}" --package=core)"
t_assert_eq "cargo +${PIN} doc ${MAP} --no-deps --workspace" "$(_doc_call "${WORKSPACE_TOML}" --workspace)" "--workspace is not passed twice"

t_case "a single package stays as it was"
t_assert_eq "cargo +${PIN} doc ${MAP} --no-deps" "$(_doc_call "${PACKAGE_TOML}")"
t_assert_eq "cargo +${PIN} doc ${MAP} --no-deps --features x" "$(_doc_call "${PACKAGE_TOML}" --features x)"

t_case "without an override the toolchain is versions.env's pin"
pinned="$(sed -n 's/^RUST_NIGHTLY_TOOLCHAIN=//p' "${VERSIONS_ENV}")"
t_assert_contains "${pinned}" "nightly-" "versions.env pins a dated nightly"
t_assert_contains "$(unset RUST_NIGHTLY_TOOLCHAIN; STUB_TOOLCHAIN="${pinned}" _doc_run "${PACKAGE_TOML}")" "cargo +${pinned} doc ${MAP} --no-deps"

t_case "a missing pinned toolchain stops the build and says how to install it"
out="$(RUST_NIGHTLY_TOOLCHAIN="${PIN}" STUB_TOOLCHAIN=nightly-other _doc_run "${PACKAGE_TOML}")"
t_assert_contains "${out}" "rc=1"
t_assert_contains "${out}" "rustup toolchain install ${PIN} --profile minimal"
t_assert_eq 0 "$(printf '%s\n' "${out}" | grep -c '^cargo ')" "no doc call runs on another toolchain"

t_summary
