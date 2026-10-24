#!/usr/bin/env bash
# Local source fixtures cover candidate precedence and fallback, not package installation or toolchain builds.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
BOOTSTRAP="${1:-${TESTS_DIR}/../02-toolchain/bootstrap.sh}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
sed "s#/opt/scripts/core#${work}/mounted#g" "${BOOTSTRAP}" > "${work}/bootstrap.sh"

_plant_bootstrap_candidates() {
  local leaf="$1" dir
  rm -rf "${work}/toolchain" "${work}/01-core" "${work}/mounted"
  for dir in toolchain 01-core mounted; do
    mkdir -p "${work}/${dir}"
    printf 'printf "loaded:%%s\\n" "%s"\n' "${dir}" > "${work}/${dir}/${leaf}"
  done
}

_run_bootstrap() {
  bash -c 'source "$1"; "$2" "$3"' _ "${work}/bootstrap.sh" "$1" "${work}/toolchain" 2>&1
}

for policy in 'common.sh source_toolchain_common_or_fallback mounted 01-core' \
              'build-helpers.sh source_toolchain_build_helpers_or_fallback 01-core mounted' \
              'elf-strip.sh source_toolchain_elf_strip 01-core mounted'; do
  read -r leaf loader second third <<< "${policy}"
  t_case "${loader}: adjacent, then distinct fallback precedence"
  _plant_bootstrap_candidates "${leaf}"
  t_assert_eq loaded:toolchain "$(_run_bootstrap "${loader}")"
  rm "${work}/toolchain/${leaf}"
  t_assert_eq "loaded:${second}" "$(_run_bootstrap "${loader}")"
  rm "${work}/${second}/${leaf}"
  t_assert_eq "loaded:${third}" "$(_run_bootstrap "${loader}")"

  t_case "${loader}: an actual source failure remains fatal under errexit"
  _plant_bootstrap_candidates "${leaf}"
  printf 'false\nprintf "source continued\\n"\n' > "${work}/toolchain/${leaf}"
  t_assert_fails _run_bootstrap "${loader}"
  t_case "${loader}: conditional callers retain the existing source status policy"
  t_assert_eq 'source continued
accepted' "$(bash -c 'source "$1"; if "$2" "$3"; then printf accepted; fi' _ "${work}/bootstrap.sh" "${loader}" "${work}/toolchain")"
done

t_case "common fallback keeps logging streams, sudo selection and apt argument order"
_plant_bootstrap_candidates common.sh
rm "${work}"/{toolchain,01-core,mounted}/common.sh
cp "${TESTS_DIR}/../01-core/sudo-policy.sh" "${work}/mounted/"
output="$(bash -c 'source "$1"; source_toolchain_common_or_fallback "$2"
  info message; warn warning
  require_sudo
  apt-get() { printf "apt:<%s>" "$@"; printf "\n"; }
  sudo() { "$@"; }
  apt_install "package with space" other
  detect_system' _ "${work}/bootstrap.sh" "${work}/toolchain" 2> "${work}/stderr")"
t_assert_eq '[INFO] message
apt:<update>apt:<-qq>
apt:<install>apt:<-y>apt:<--no-install-recommends>apt:<package with space>apt:<other>' "${output}"
t_assert_eq '[WARN] warning' "$(cat "${work}/stderr")"
t_assert_eq '[ERROR] stopped' "$(bash -c 'source "$1"; source_toolchain_common_or_fallback "$2"; die stopped' _ "${work}/bootstrap.sh" "${work}/toolchain" 2>&1)"
t_assert_fails bash -c 'source "$1"; source_toolchain_common_or_fallback "$2"; die stopped' _ "${work}/bootstrap.sh" "${work}/toolchain"

t_case "missing build helpers source the ELF companion with its own precedence"
_plant_bootstrap_candidates elf-strip.sh
t_assert_eq loaded:toolchain "$(_run_bootstrap source_toolchain_build_helpers_or_fallback)"
t_case "missing ELF companion fails with the existing diagnostic"
rm "${work}"/{toolchain,01-core,mounted}/elf-strip.sh
t_assert_fails _run_bootstrap source_toolchain_build_helpers_or_fallback
t_assert_eq 'ERROR: toolchain bootstrap requires elf-strip.sh' "$(_run_bootstrap source_toolchain_elf_strip)"

t_summary
