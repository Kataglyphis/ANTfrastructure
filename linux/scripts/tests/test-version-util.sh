#!/usr/bin/env bash
# Tests for version_util.sh: the CI version from a plain version file or a Cargo.toml, else the ref name or run number.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UTIL="${TESTS_DIR}/../02-toolchain/rust/version_util.sh"
source "${TESTS_DIR}/test-harness.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
resolve() { REF_NAME="${2:-develop}" RUN_NUMBER="${3:-77}" bash "${UTIL}" --resolve-ci "$1" 2>/dev/null; }

t_case "a plain version file: its first non-empty line, without a leading v"
printf '\n  v2.3.4\r\nignored\n' > "${work}/VERSION.txt"
t_assert_eq "2.3.4" "$(resolve "${work}/VERSION.txt")"

t_case "a workspace Cargo.toml: [workspace.package]'s version, not a member's"
mkdir -p "${work}/ws"
cat > "${work}/ws/Cargo.toml" <<'TOML'
[package]
name = "oxidant"
version.workspace = true

[workspace.package]
version = "2.3.4"
edition = "2021"

[dependencies]
serde = { version = "1.0.200", features = ["derive"] }
TOML
t_assert_eq "2.3.4" "$(resolve "${work}/ws/Cargo.toml")"

t_case "a single-crate Cargo.toml: [package]'s version"
mkdir -p "${work}/one"
printf '[package]\nname = "one"\nversion = "0.4.1"\n\n[dependencies]\nlog = { version = "0.4" }\n' > "${work}/one/Cargo.toml"
t_assert_eq "0.4.1" "$(resolve "${work}/one/Cargo.toml")"

t_case "a dependency's version is never the crate's"
mkdir -p "${work}/nover"
printf '[package]\nname = "nover"\nversion.workspace = true\n\n[dependencies]\nlog = "0.4.22"\n' > "${work}/nover/Cargo.toml"
t_assert_eq "77" "$(resolve "${work}/nover/Cargo.toml" develop 77)"

t_case "a dependency table's version is not the crate's either"
printf '[package]\nname = "dep"\nversion.workspace = true\n\n[dependencies.serde]\nversion = "1.0.200"\n' > "${work}/nover/Cargo.toml"
t_assert_eq "77" "$(resolve "${work}/nover/Cargo.toml" develop 77)"

t_case "a Cargo.toml without a version falls back to a v-tag ref name"
t_assert_eq "3.0.0" "$(resolve "${work}/nover/Cargo.toml" v3.0.0 77)"

t_case "--github-env writes VERSION and the four-part MSIX_VERSION from a Cargo.toml"
: > "${work}/env"
(cd "${work}" && GITHUB_ENV="${work}/env" REF_NAME=develop RUN_NUMBER=1 bash "${UTIL}" --github-env ws/Cargo.toml >/dev/null 2>&1)
t_assert_eq "VERSION=2.3.4 MSIX_VERSION=2.3.4.0" "$(tr '\n' ' ' < "${work}/env" | sed 's/ $//')"

t_summary
