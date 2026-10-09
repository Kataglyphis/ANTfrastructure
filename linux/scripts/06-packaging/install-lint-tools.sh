#!/usr/bin/env bash
# [PREFIX [HADOLINT_BIN [CORE_DIR]]]: the pinned shellcheck and hadolint on PATH, SHA-verified. docs/consumer-image-contract.md#shellcheck-and-hadolint
set -euo pipefail

PREFIX="${1:-/usr/local/bin}"
HADOLINT_BIN="${2:-}"
CORE_DIR="${3:-/opt/scripts/core}"

die() { printf 'install-lint-tools: ERROR: %s\n' "$*" >&2; exit 1; }

# shellcheck source=../01-core/load-versions-env.sh
source "${CORE_DIR}/load-versions-env.sh"
load_versions_env "${CORE_DIR}/tool-pins.env"
# shellcheck source=../01-core/downloads.sh
source "${CORE_DIR}/downloads.sh"
: "${SHELLCHECK_VERSION:?SHELLCHECK_VERSION missing from tool-pins.env}"
: "${HADOLINT_VERSION:?HADOLINT_VERSION missing from tool-pins.env}"

# <arch>: "<shellcheck asset arch> <its sha key> <hadolint asset> <its sha key>"; a dash is no upstream binary.
lint_tool_assets() {
  case "$1" in
    x86_64|amd64)  printf 'x86_64 SHELLCHECK_LINUX_X86_64_SHA256 hadolint-linux-x86_64 HADOLINT_LINUX_X86_64_SHA256\n' ;;
    aarch64|arm64) printf 'aarch64 SHELLCHECK_LINUX_AARCH64_SHA256 hadolint-linux-arm64 HADOLINT_LINUX_ARM64_SHA256\n' ;;
    riscv64)       printf 'riscv64 SHELLCHECK_LINUX_RISCV64_SHA256 - -\n' ;;
    *) return 1 ;;
  esac
}

arch="$(uname -m)"
read -r sc_arch sc_key hl_asset hl_key < <(lint_tool_assets "${arch}") || die "no lint tools are pinned for ${arch}"
mkdir -p "${PREFIX}"

sc_sha="${!sc_key:-}"
[ -n "${sc_sha}" ] || die "${sc_key} is not pinned in tool-pins.env"
download_verified_install \
  "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.${sc_arch}.tar.xz" \
  "${sc_sha}" "${PREFIX}/shellcheck" "shellcheck-${SHELLCHECK_VERSION}/shellcheck" \
  || die "the verified shellcheck ${SHELLCHECK_VERSION} download failed"

if [ "${hl_asset}" != - ]; then
  hl_sha="${!hl_key:-}"
  [ -n "${hl_sha}" ] || die "${hl_key} is not pinned in tool-pins.env"
  download_verified_install \
    "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/${hl_asset}" \
    "${hl_sha}" "${PREFIX}/hadolint" || die "the verified hadolint ${HADOLINT_VERSION} download failed"
elif [ -n "${HADOLINT_BIN}" ]; then
  install -m 0755 "${HADOLINT_BIN}" "${PREFIX}/hadolint"
else
  die "hadolint publishes no ${arch} binary; pass the source build as HADOLINT_BIN"
fi

have="$("${PREFIX}/shellcheck" --version | sed -n 's/^version: //p')"
[ "${have}" = "${SHELLCHECK_VERSION#v}" ] || die "shellcheck reports '${have}', the pin is ${SHELLCHECK_VERSION}"
have="$("${PREFIX}/hadolint" --version)"
case "${have}" in
  *" ${HADOLINT_VERSION#v}"|*" ${HADOLINT_VERSION#v}-"*|*" ${HADOLINT_VERSION#v} "*) ;;
  *) die "hadolint reports '${have}', the pin is ${HADOLINT_VERSION}" ;;
esac
# Each must also flag what it exists to flag: a binary that runs but cannot lint is no gate.
probe="$(mktemp -d)"
printf '#!/bin/sh\necho $1\n' > "${probe}/probe.sh"
printf 'FROM scratch\nRUN apt-get install foo\n' > "${probe}/Dockerfile"
case "$("${PREFIX}/shellcheck" "${probe}/probe.sh" 2>&1 || true)" in
  *SC2086*) ;;
  *) die "shellcheck did not report SC2086 on an unquoted \$1" ;;
esac
case "$("${PREFIX}/hadolint" --no-color "${probe}/Dockerfile" 2>&1 || true)" in
  *DL30*) ;;
  *) die "hadolint did not report a DL30xx rule on an unpinned apt-get install" ;;
esac
rm -rf "${probe}"
printf 'install-lint-tools: shellcheck %s and %s in %s (%s)\n' "${SHELLCHECK_VERSION}" "${have}" "${PREFIX}" "${arch}"
