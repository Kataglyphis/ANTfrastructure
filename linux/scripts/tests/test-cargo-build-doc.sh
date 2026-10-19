#!/usr/bin/env bash
# cargo_build_doc.sh documents every member of a workspace unless the caller picked the packages. See docs/shared-script-libraries.md#every-crate-of-a-workspace
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
DRIVER="$(cd "${TESTS_DIR}/../02-toolchain/rust" && pwd)/cargo_build_doc.sh"

_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT

WORKSPACE_TOML='[workspace]
members = ["crates/a"]

[package]
name = "root-crate"'
PACKAGE_TOML='[package]
name = "solo"'

# _doc_call <Cargo.toml text> [driver args...]: runs the driver with a cargo function that logs its doc call; prints that call.
_doc_call() {
  local dir
  dir="$(mktemp -d "${_WORK}/crate.XXXXXX")"
  printf '%s\n' "$1" > "${dir}/Cargo.toml"
  shift
  # A function, not a stub on PATH: the toolchain guard hoists the image's own cargo ahead of PATH.
  (cd "${dir}" && env HOME="${dir}" CARGO_HOME="${dir}/cargo-home" CARGO_SAFE_DIRECTORY= DOC_LOG="${dir}/cargo.log" \
    bash -c 'cargo() { if [ "$1" = doc ]; then echo "cargo $*" >> "${DOC_LOG}"; mkdir -p target/doc; fi; }
      export -f cargo; bash "$@"' _ "${DRIVER}" "$@" >/dev/null 2>&1)
  cat "${dir}/cargo.log" 2>/dev/null
}

t_case "a [workspace] manifest documents every member"
t_assert_eq "cargo doc --no-deps --workspace" "$(_doc_call "${WORKSPACE_TOML}")" \
  "without --workspace cargo doc documents the root package alone"
t_assert_eq "cargo doc --no-deps --workspace --features gstreamer" "$(_doc_call "${WORKSPACE_TOML}" --features gstreamer)" \
  "the caller's arguments still follow"

t_case "a caller that picked the packages keeps its choice"
t_assert_eq "cargo doc --no-deps -p core" "$(_doc_call "${WORKSPACE_TOML}" -p core)"
t_assert_eq "cargo doc --no-deps -pcore" "$(_doc_call "${WORKSPACE_TOML}" -pcore)"
t_assert_eq "cargo doc --no-deps --package=core" "$(_doc_call "${WORKSPACE_TOML}" --package=core)"
t_assert_eq "cargo doc --no-deps --workspace" "$(_doc_call "${WORKSPACE_TOML}" --workspace)" "--workspace is not passed twice"

t_case "a single package stays as it was"
t_assert_eq "cargo doc --no-deps" "$(_doc_call "${PACKAGE_TOML}")"
t_assert_eq "cargo doc --no-deps --features x" "$(_doc_call "${PACKAGE_TOML}" --features x)"

t_summary
