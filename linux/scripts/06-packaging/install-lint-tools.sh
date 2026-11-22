#!/usr/bin/env bash
# [PREFIX [CORE_DIR]]: the pinned shellcheck, hadolint and gitleaks on PATH, SHA-verified. docs/consumer-image-contract.md#shellcheck-and-hadolint
set -euo pipefail

PREFIX="${1:-/usr/local/bin}"
CORE_DIR="${2:-/opt/scripts/core}"

die() { printf 'install-lint-tools: ERROR: %s\n' "$*" >&2; exit 1; }

# shellcheck source=../01-core/load-versions-env.sh
source "${CORE_DIR}/load-versions-env.sh"
load_versions_env "${CORE_DIR}/tool-pins.env"
# shellcheck source=../01-core/downloads.sh
source "${CORE_DIR}/downloads.sh"
: "${SHELLCHECK_VERSION:?SHELLCHECK_VERSION missing from tool-pins.env}"
: "${HADOLINT_VERSION:?HADOLINT_VERSION missing from tool-pins.env}"
: "${GITLEAKS_VERSION:?GITLEAKS_VERSION missing from tool-pins.env}"

# <arch>: "<shellcheck asset arch> <its sha key> <hadolint asset> <its sha key> <gitleaks asset arch> <its sha key>"; a dash is no upstream binary.
lint_tool_assets() {
  case "$1" in
    x86_64|amd64)  printf 'x86_64 SHELLCHECK_LINUX_X86_64_SHA256 hadolint-linux-x86_64 HADOLINT_LINUX_X86_64_SHA256 linux_x64 GITLEAKS_LINUX_X64_SHA256\n' ;;
    aarch64|arm64) printf 'aarch64 SHELLCHECK_LINUX_AARCH64_SHA256 hadolint-linux-arm64 HADOLINT_LINUX_ARM64_SHA256 linux_arm64 GITLEAKS_LINUX_ARM64_SHA256\n' ;;
    riscv64)       printf 'riscv64 SHELLCHECK_LINUX_RISCV64_SHA256 - - - -\n' ;;
    *) return 1 ;;
  esac
}

arch="$(uname -m)"
read -r sc_arch sc_key hl_asset hl_key gl_arch gl_key < <(lint_tool_assets "${arch}") || die "no lint tools are pinned for ${arch}"
mkdir -p "${PREFIX}"

sc_sha="${!sc_key:-}"
[ -n "${sc_sha}" ] || die "${sc_key} is not pinned in tool-pins.env"
# GitHub's release CDN answered HTTP 500 for shellcheck's aarch64 asset for about a minute (2026-10-21), and the arm64 wrapper died in it.
DOWNLOAD_RETRY_DELAY="${DOWNLOAD_RETRY_DELAY:-20}" download_verified_install \
  "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.${sc_arch}.tar.xz" \
  "${sc_sha}" "${PREFIX}/shellcheck" "shellcheck-${SHELLCHECK_VERSION}/shellcheck" \
  || die "the verified shellcheck ${SHELLCHECK_VERSION} download failed"

if [ "${hl_asset}" != - ]; then
  hl_sha="${!hl_key:-}"
  [ -n "${hl_sha}" ] || die "${hl_key} is not pinned in tool-pins.env"
  download_verified_install \
    "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/${hl_asset}" \
    "${hl_sha}" "${PREFIX}/hadolint" || die "the verified hadolint ${HADOLINT_VERSION} download failed"
else
  # No upstream binary, and a source build under QEMU costs hours per chain, so this arch ships shellcheck alone.
  printf 'install-lint-tools: NOTE: hadolint publishes no %s binary; none is installed\n' "${arch}"
fi

# The secret scan's own pin, so a gate without network finds it on PATH instead of downloading it (owner, 2026-11-20, CON222).
if [ "${gl_arch}" != - ]; then
  gl_sha="${!gl_key:-}"
  [ -n "${gl_sha}" ] || die "${gl_key} is not pinned in tool-pins.env"
  download_verified_install \
    "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${gl_arch}.tar.gz" \
    "${gl_sha}" "${PREFIX}/gitleaks" "gitleaks" || die "the verified gitleaks ${GITLEAKS_VERSION} download failed"
else
  printf 'install-lint-tools: NOTE: gitleaks publishes no %s binary; none is installed\n' "${arch}"
fi

have="$("${PREFIX}/shellcheck" --version | sed -n 's/^version: //p')"
[ "${have}" = "${SHELLCHECK_VERSION#v}" ] || die "shellcheck reports '${have}', the pin is ${SHELLCHECK_VERSION}"
gl_have='no gitleaks'
if [ "${gl_arch}" != - ]; then
  gl_have="$("${PREFIX}/gitleaks" version)"
  [ "${gl_have#v}" = "${GITLEAKS_VERSION}" ] || die "gitleaks reports '${gl_have}', the pin is ${GITLEAKS_VERSION}"
  gl_have="gitleaks ${GITLEAKS_VERSION}"
fi
hl_have='no hadolint'
if [ "${hl_asset}" != - ]; then
  hl_have="$("${PREFIX}/hadolint" --version)"
  case "${hl_have}" in
    *" ${HADOLINT_VERSION#v}"|*" ${HADOLINT_VERSION#v}-"*|*" ${HADOLINT_VERSION#v} "*) ;;
    *) die "hadolint reports '${hl_have}', the pin is ${HADOLINT_VERSION}" ;;
  esac
fi
# Each must also flag what it exists to flag: a binary that runs but cannot lint is no gate.
probe="$(mktemp -d)"
printf '#!/bin/sh\necho $1\n' > "${probe}/probe.sh"
printf 'FROM scratch\nRUN apt-get install foo\n' > "${probe}/Dockerfile"
case "$("${PREFIX}/shellcheck" "${probe}/probe.sh" 2>&1 || true)" in
  *SC2086*) ;;
  *) die "shellcheck did not report SC2086 on an unquoted \$1" ;;
esac
if [ "${hl_asset}" != - ]; then
  case "$("${PREFIX}/hadolint" --no-color "${probe}/Dockerfile" 2>&1 || true)" in
    *DL30*) ;;
    *) die "hadolint did not report a DL30xx rule on an unpinned apt-get install" ;;
  esac
fi
if [ "${gl_arch}" != - ]; then
  # A token in GitHub's PAT shape, made here so no file of the hub holds one; 7 is gitleaks' exit for a leak found.
  token="$(head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  printf 'token = "ghp_%s"\n' "${token:0:36}" > "${probe}/planted.toml"
  rm -f "${probe}/probe.sh" "${probe}/Dockerfile"
  gl_rc=0
  "${PREFIX}/gitleaks" detect --no-git --source "${probe}" --no-banner --redact --exit-code 7 > /dev/null 2>&1 || gl_rc=$?
  [ "${gl_rc}" = 7 ] || die "gitleaks did not report a planted GitHub token (exit ${gl_rc})"
fi
rm -rf "${probe}"
printf 'install-lint-tools: shellcheck %s and %s in %s (%s)\n' "${SHELLCHECK_VERSION}" "${hl_have}" "${PREFIX}" "${arch}"
printf 'install-lint-tools: %s in %s (%s)\n' "${gl_have}" "${PREFIX}" "${arch}"
