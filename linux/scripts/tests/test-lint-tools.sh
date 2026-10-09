#!/usr/bin/env bash
# The image's shellcheck and hadolint on every arch, riscv64's hadolint from source; see docs/consumer-image-contract.md#shellcheck-and-hadolint
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
ROOT="$(cd "${SCRIPTS}/../.." && pwd)"
INSTALL="${SCRIPTS}/06-packaging/install-lint-tools.sh"
BUILD_HL="${SCRIPTS}/06-packaging/build-hadolint.sh"
PINS="${SCRIPTS}/01-core/tool-pins.env"
TORCH="${ROOT}/linux/Dockerfile.torch"

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
_pin() { sed -n "s/^$1=//p" "${PINS}" | head -1; }

# A core dir whose download_verified_install records its call and installs a binary that reports FAKE_<tool>_VERSION.
mkdir -p "${_work}/core" "${_work}/bin"
cp "${SCRIPTS}/01-core/load-versions-env.sh" "${PINS}" "${_work}/core/"
cat > "${_work}/core/downloads.sh" <<'DL'
download_verified_install() {
  printf '%s %s\n' "$1" "$2" >> "${FAKE_DL_LOG}"
  case "$1" in
    *shellcheck*) printf '#!/bin/sh\n[ "$1" = --version ] || { echo "${FAKE_SC_FINDING:-SC2086}"; exit 1; }\necho "version: %s"\n' "${FAKE_SC_VERSION}" > "$3" ;;
    *hadolint*)   printf '#!/bin/sh\n[ "$1" = --version ] || { echo "DL3008"; exit 1; }\necho "Haskell Dockerfile Linter %s"\n' "${FAKE_HL_VERSION}" > "$3" ;;
  esac
  chmod +x "$3"
}
download_verified_file() { download_verified_install "$@"; }
DL
printf '#!/bin/sh\n[ "$1" = -m ] && { echo "${FAKE_ARCH}"; exit 0; }\nexec /usr/bin/uname "$@"\n' > "${_work}/bin/uname"
chmod +x "${_work}/bin/uname"
SC_V="$(_pin SHELLCHECK_VERSION)"; HL_V="$(_pin HADOLINT_VERSION)"
export FAKE_SC_VERSION="${SC_V#v}" FAKE_HL_VERSION="${HL_V#v}" FAKE_DL_LOG="${_work}/dl.log"
_install() {
  : > "${FAKE_DL_LOG}"
  FAKE_ARCH="$1" PATH="${_work}/bin:${PATH}" bash "${INSTALL}" "${_work}/prefix-$1" "${2:-}" "${_work}/core" 2>&1
}

t_case "amd64 and arm64 take both release binaries, each at its own pinned checksum"
_out="$(_install x86_64)"
t_assert_contains "${_out}" "shellcheck ${SC_V} and Haskell Dockerfile Linter ${HL_V#v} in ${_work}/prefix-x86_64 (x86_64)"
t_assert_contains "$(cat "${FAKE_DL_LOG}")" "shellcheck-${SC_V}.linux.x86_64.tar.xz $(_pin SHELLCHECK_LINUX_X86_64_SHA256)"
t_assert_contains "$(cat "${FAKE_DL_LOG}")" "${HL_V}/hadolint-linux-x86_64 $(_pin HADOLINT_LINUX_X86_64_SHA256)"
_out="$(_install aarch64)"
t_assert_contains "$(cat "${FAKE_DL_LOG}")" "shellcheck-${SC_V}.linux.aarch64.tar.xz $(_pin SHELLCHECK_LINUX_AARCH64_SHA256)"
t_assert_contains "$(cat "${FAKE_DL_LOG}")" "${HL_V}/hadolint-linux-arm64 $(_pin HADOLINT_LINUX_ARM64_SHA256)"

t_case "riscv64 takes shellcheck's riscv64 release and hadolint's source build, and refuses without one"
t_assert_ok test -n "$(_pin SHELLCHECK_LINUX_RISCV64_SHA256)"
_out="$(_install riscv64)"
t_assert_contains "${_out}" "hadolint publishes no riscv64 binary; pass the source build as HADOLINT_BIN"
printf '#!/bin/sh\n[ "$1" = --version ] || { echo "${FAKE_HL_FINDING:-DL3008}"; exit 1; }\necho "Haskell Dockerfile Linter %s"\n' "${HL_V#v}" > "${_work}/hadolint-src"; chmod +x "${_work}/hadolint-src"
_out="$(_install riscv64 "${_work}/hadolint-src")"
t_assert_contains "${_out}" "(riscv64)"
t_assert_eq "shellcheck-${SC_V}.linux.riscv64.tar.xz $(_pin SHELLCHECK_LINUX_RISCV64_SHA256)" "$(sed 's|.*/||' "${FAKE_DL_LOG}")" "one download, shellcheck's"

t_case "a tool that does not report its pin fails the install, and so does an unpinned arch"
t_assert_contains "$(FAKE_SC_VERSION=0.0.1 _install x86_64)" "shellcheck reports '0.0.1', the pin is ${SC_V}"
t_assert_contains "$(FAKE_HL_VERSION=1.0.0 _install x86_64)" "hadolint reports 'Haskell Dockerfile Linter 1.0.0', the pin is ${HL_V}"
t_assert_contains "$(FAKE_SC_FINDING=clean _install x86_64)" "shellcheck did not report SC2086"
t_assert_contains "$(FAKE_HL_FINDING=clean _install riscv64 "${_work}/hadolint-src")" "hadolint did not report a DL30xx rule"
t_assert_contains "$(_install sparc64)" "no lint tools are pinned for sparc64"
t_assert_eq 1 "$(FAKE_ARCH=sparc64 PATH="${_work}/bin:${PATH}" t_rc bash "${INSTALL}" "${_work}/p" "" "${_work}/core")"

t_case "the hadolint source build reuses a binary built from the same pins, and only that one"
mkdir -p "${_work}/cabal/hadolint-bin/${HL_V}-$(_pin HADOLINT_SOURCE_SHA256 | cut -c1-16)-$(_pin HADOLINT_HACKAGE_INDEX_STATE)"
cp "${_work}/hadolint-src" "${_work}/cabal/hadolint-bin/${HL_V}-$(_pin HADOLINT_SOURCE_SHA256 | cut -c1-16)-$(_pin HADOLINT_HACKAGE_INDEX_STATE)/hadolint"
_out="$(FAKE_ARCH=riscv64 PATH="${_work}/bin:${PATH}" bash "${BUILD_HL}" "${_work}/hl-reuse" "${_work}/core" "${_work}/cabal" 2>&1)"
t_assert_contains "${_out}" "build-hadolint: reused ${_work}/cabal/hadolint-bin/${HL_V}-"
t_assert_ok cmp "${_work}/hadolint-src" "${_work}/hl-reuse/hadolint"

t_case "the hadolint source build does nothing where a release binary exists"
_out="$(FAKE_ARCH=x86_64 PATH="${_work}/bin:${PATH}" bash "${BUILD_HL}" "${_work}/hl-out" "${_work}/core" 2>&1)"
t_assert_contains "${_out}" "x86_64 takes the release binary; nothing to build"
t_assert_eq "" "$(ls -A "${_work}/hl-out")"
t_assert_ok test -n "$(_pin HADOLINT_SOURCE_SHA256)"
t_assert_ok test -n "$(_pin HADOLINT_HACKAGE_INDEX_STATE)"

t_case "lint-shell.sh bootstraps the same riscv64 asset on a riscv64 host"
t_assert_contains "$(cat "${SCRIPTS}/lint-shell.sh")" 'shellcheck-%s.linux.riscv64.tar.xz %s\n'"' \"\${SHELLCHECK_VERSION}\" \"\${SHELLCHECK_LINUX_RISCV64_SHA256:-}\""

t_case "bump_versions.py refreshes every new pin with its version"
_bv="$(cat "${ROOT}/docs/scripts/bump_versions.py")"
t_assert_contains "${_bv}" '("SHELLCHECK_LINUX_RISCV64_SHA256", f"shellcheck-{v}.linux.riscv64.tar.xz")'
t_assert_contains "${_bv}" 'extras["HADOLINT_SOURCE_SHA256"]'
t_assert_contains "${_bv}" 'extras["HADOLINT_HACKAGE_INDEX_STATE"]'

t_case "the torch stage installs both on every arch, from the hadolint build stage"
_torch="$(cat "${TORCH}")"
t_assert_contains "${_torch}" "FROM ubuntu:\${UBUNTU_VERSION}@\${UBUNTU_DIGEST} AS hadolint-build"
t_assert_contains "${_torch}" "bash /tmp/build-hadolint.sh /out /tmp/pins"
t_assert_contains "${_torch}" "--mount=type=bind,from=hadolint-build,source=/out,target=/tmp/hadolint-build"
t_assert_contains "${_torch}" "install-lint-tools.sh /usr/local/bin /tmp/hadolint-build/hadolint"

t_case "the shipped-image contract row holds both tools to their tool-pins.env pins (mutation)"
SMOKE="${SCRIPTS}/06-packaging/smoke-runtime-image.sh"
mkdir -p "${_work}/rt/06-packaging" "${_work}/rt/01-core"; cp "${PINS}" "${_work}/rt/01-core/"
for _fn in _consumer_contract_fact _consumer_lint_tools_verdict _rt_tool_pin; do
  t_fn_src "${SMOKE}" "${_fn}" >> "${_work}/rt/06-packaging/row.sh" || exit 1
done
_lint_row() { bash -c 'source "$1"; _consumer_lint_tools_verdict lint-tools "$2" "$3"' _ "${_work}/rt/06-packaging/row.sh" "$@"; }
_pins_want="shellcheck=${SC_V#v} hadolint=${HL_V#v}"
t_assert_eq "OK lint-tools ${_pins_want}" "$(_lint_row "FACT lint-tools ${_pins_want}" "${_pins_want}")"
t_assert_contains "$(_lint_row "FACT lint-tools shellcheck= hadolint=${HL_V#v}" "${_pins_want}")" "BAD lint-tools the image has shellcheck= hadolint="
t_assert_contains "$(_lint_row "FACT lint-tools shellcheck=${SC_V#v} hadolint=" "${_pins_want}")" "BAD lint-tools"
t_assert_contains "$(_lint_row "FACT other x" "${_pins_want}")" "NOFACT lint-tools"
t_assert_eq "${SC_V}" "$(bash -c 'source "$1"; _rt_tool_pin SHELLCHECK_VERSION' _ "${_work}/rt/06-packaging/row.sh")" "the row reads tool-pins.env"
_smoke_src="$(cat "${SMOKE}")"
t_assert_contains "${_smoke_src}" 'printf '"'"'FACT lint-tools shellcheck=%s hadolint=%s\n'"'"
t_assert_contains "${_smoke_src}" 'lint-tools)    _sc="$(_rt_tool_pin SHELLCHECK_VERSION)"; _hl="$(_rt_tool_pin HADOLINT_VERSION)"'
t_assert_contains "$(grep '^_CONSUMER_CONTRACT_ROWS=' "${SMOKE}")" " lint-tools"

t_summary
