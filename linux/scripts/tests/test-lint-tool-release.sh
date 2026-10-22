#!/usr/bin/env bash
# Stubbed releases exercise platform, pin and cache policy; no network or real extraction runs here.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/lint-tool-release.sh"
D="$(mktemp -d)"
trap 'rm -rf "${D}"' EXIT
CORE_DIR="${D}/core"
mkdir -p "${CORE_DIR}" "${D}/bin"
cp "${TESTS_DIR}/../01-core/load-versions-env.sh" "${CORE_DIR}/"
cat > "${CORE_DIR}/tool-pins.env" <<'PINS'
SHELLCHECK_VERSION=v1.2.3
ACTIONLINT_VERSION=4.5.6
HADOLINT_VERSION=v7.8.9
SHELLCHECK_LINUX_X86_64_SHA256=sc-amd64
SHELLCHECK_LINUX_AARCH64_SHA256=sc-arm64
SHELLCHECK_LINUX_RISCV64_SHA256=sc-riscv64
SHELLCHECK_WINDOWS_SHA256=sc-win
ACTIONLINT_LINUX_AMD64_SHA256=al-amd64
ACTIONLINT_LINUX_ARM64_SHA256=al-arm64
ACTIONLINT_WINDOWS_AMD64_SHA256=al-win
HADOLINT_LINUX_X86_64_SHA256=hl-amd64
HADOLINT_LINUX_ARM64_SHA256=hl-arm64
HADOLINT_WINDOWS_X86_64_SHA256=hl-win
PINS
source "${CORE_DIR}/tool-pins.env"
export LINT_RELEASE_LOG="${D}/download.log"
cat > "${CORE_DIR}/downloads.sh" <<'DOWNLOAD'
download_verified_install() {
  printf '<%s>' "$@" >> "${LINT_RELEASE_LOG}"
  printf '\n' >> "${LINT_RELEASE_LOG}"
  [ "${DOWNLOAD_STATUS:-0}" = 0 ] || return "${DOWNLOAD_STATUS}"
  mkdir -p "$(dirname "$3")"
  printf '#!/bin/sh\nexit 0\n' > "$3"
  chmod +x "$3"
}
DOWNLOAD
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
uname() { case "$1" in -s) printf '%s' "${TEST_OS:-Linux}" ;; -m) printf '%s' "${TEST_ARCH:-x86_64}" ;; esac; }
command() {
  if [ "$1" = -v ]; then
    [ "${TEST_PATH_TOOL:-}" = "${2:-}" ] || return 1
    printf '%s/%s\n' "${D}/bin" "$2"
  else
    builtin command "$@"
  fi
}
while read -r tool os arch asset sha; do
  t_case "${tool} ${os}/${arch} selects the matching asset and checksum"
  t_assert_eq "${asset} ${sha}" "$(TEST_OS="${os}" TEST_ARCH="${arch}" lint_tool_release_asset "${tool}" fixture)"
done <<'CASES'
shellcheck Linux amd64 shellcheck-fixture.linux.x86_64.tar.xz sc-amd64
shellcheck Linux arm64 shellcheck-fixture.linux.aarch64.tar.xz sc-arm64
shellcheck Linux riscv64 shellcheck-fixture.linux.riscv64.tar.xz sc-riscv64
shellcheck MINGW64_NT x86_64 shellcheck-fixture.zip sc-win
actionlint Linux x86_64 actionlint_fixture_linux_amd64.tar.gz al-amd64
actionlint Linux aarch64 actionlint_fixture_linux_arm64.tar.gz al-arm64
actionlint MSYS_NT x86_64 actionlint_fixture_windows_amd64.zip al-win
hadolint Linux x86_64 hadolint-linux-x86_64 hl-amd64
hadolint Linux aarch64 hadolint-linux-arm64 hl-arm64
hadolint CYGWIN_NT x86_64 hadolint-windows-x86_64.exe hl-win
CASES
for tool in shellcheck actionlint hadolint; do
  t_case "${tool} refuses unsupported hosts"
  t_assert_eq 1 "$(TEST_OS=Darwin t_rc lint_tool_release_asset "${tool}" fixture)"
  t_assert_eq 1 "$(TEST_ARCH=sparc t_rc lint_tool_release_asset "${tool}" fixture)"
done
_resolve() {
  local resolved=''
  lint_tool_ensure "$1" resolved
  printf 'RESOLVED <%s>\n' "${resolved}"
}
_resolve_subprocess() {
  ( _resolve "$@" )
}
export SHELLCHECK_CACHE_DIR="${D}/sc cache" ACTIONLINT_CACHE_DIR="${D}/al cache" HADOLINT_CACHE_DIR="${D}/hl cache"
t_case "archive members and release URL prefixes stay tool-specific"
for tool in shellcheck actionlint hadolint; do
  t_assert_contains "$(_resolve "${tool}")" 'RESOLVED <'
done
t_assert_contains "$(cat "${LINT_RELEASE_LOG}")" '<https://github.com/koalaman/shellcheck/releases/download/v1.2.3/shellcheck-v1.2.3.linux.x86_64.tar.xz><sc-amd64>'
t_assert_contains "$(cat "${LINT_RELEASE_LOG}")" '<shellcheck-v1.2.3/shellcheck>'
t_assert_contains "$(cat "${LINT_RELEASE_LOG}")" '<https://github.com/rhysd/actionlint/releases/download/v4.5.6/actionlint_4.5.6_linux_amd64.tar.gz><al-amd64>'
t_assert_contains "$(cat "${LINT_RELEASE_LOG}")" '<actionlint>'
t_assert_contains "$(cat "${LINT_RELEASE_LOG}")" "<https://github.com/hadolint/hadolint/releases/download/v7.8.9/hadolint-linux-x86_64><hl-amd64><${D}/hl cache/hadolint-v7.8.9/hadolint>"
t_case "an executable versioned cache is reused without another download"
: > "${LINT_RELEASE_LOG}"
t_assert_eq 0 "$(t_rc _resolve_subprocess shellcheck)"
t_assert_eq '' "$(cat "${LINT_RELEASE_LOG}")"
t_case "actionlint and hadolint retain their installed PATH preference"
for tool in actionlint hadolint; do
  t_assert_eq "RESOLVED <${D}/bin/${tool}>" "$(TEST_PATH_TOOL="${tool}" _resolve "${tool}")"
done
printf '#!/bin/sh\nprintf "version: 1.2.3\\n"\n' > "${D}/bin/shellcheck"
chmod +x "${D}/bin/shellcheck"
t_case "ShellCheck accepts only the pinned PATH version"
t_assert_eq "RESOLVED <${D}/bin/shellcheck>" "$(TEST_PATH_TOOL=shellcheck _resolve shellcheck)"
printf '#!/bin/sh\nprintf "version: 0.0.1\\n"\n' > "${D}/bin/shellcheck"
t_assert_eq "RESOLVED <${D}/sc cache/shellcheck-v1.2.3/shellcheck>" "$(TEST_PATH_TOOL=shellcheck _resolve shellcheck)"
t_case "missing checksums fail even when a cached binary exists"
sed -i '/SHELLCHECK_LINUX_X86_64_SHA256=/d' "${CORE_DIR}/tool-pins.env"
unset SHELLCHECK_LINUX_X86_64_SHA256
t_assert_eq 1 "$(t_rc _resolve_subprocess shellcheck)"
t_case "verified-download failures cannot resolve a tool"
rm -f "${D}/al cache/actionlint-4.5.6/actionlint"
t_assert_eq 1 "$(DOWNLOAD_STATUS=8 t_rc _resolve_subprocess actionlint)"
t_case "missing release versions fail before a download"
sed -i '/ACTIONLINT_VERSION=/d' "${CORE_DIR}/tool-pins.env"
unset ACTIONLINT_VERSION
t_assert_eq 1 "$(t_rc _resolve_subprocess actionlint)"
t_assert_contains "$(t_out _resolve_subprocess actionlint)" 'ACTIONLINT_VERSION is not set'
t_summary
