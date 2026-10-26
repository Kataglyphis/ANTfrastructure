#!/usr/bin/env bash
# The image's shellcheck on every arch and hadolint on amd64 and arm64; see docs/consumer-image-contract.md#shellcheck-and-hadolint
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
ROOT="$(cd "${SCRIPTS}/../.." && pwd)"
INSTALL="${SCRIPTS}/06-packaging/install-lint-tools.sh"
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
  FAKE_ARCH="$1" PATH="${_work}/bin:${PATH}" bash "${INSTALL}" "${_work}/prefix-$1" "${_work}/core" 2>&1
}

t_case "amd64 and arm64 take both release binaries, each at its own pinned checksum"
_out="$(_install x86_64)"
t_assert_contains "${_out}" "shellcheck ${SC_V} and Haskell Dockerfile Linter ${HL_V#v} in ${_work}/prefix-x86_64 (x86_64)"
t_assert_contains "$(cat "${FAKE_DL_LOG}")" "shellcheck-${SC_V}.linux.x86_64.tar.xz $(_pin SHELLCHECK_LINUX_X86_64_SHA256)"
t_assert_contains "$(cat "${FAKE_DL_LOG}")" "${HL_V}/hadolint-linux-x86_64 $(_pin HADOLINT_LINUX_X86_64_SHA256)"
_out="$(_install aarch64)"
t_assert_contains "$(cat "${FAKE_DL_LOG}")" "shellcheck-${SC_V}.linux.aarch64.tar.xz $(_pin SHELLCHECK_LINUX_AARCH64_SHA256)"
t_assert_contains "$(cat "${FAKE_DL_LOG}")" "${HL_V}/hadolint-linux-arm64 $(_pin HADOLINT_LINUX_ARM64_SHA256)"

t_case "riscv64 takes shellcheck's riscv64 release and installs no hadolint"
t_assert_ok test -n "$(_pin SHELLCHECK_LINUX_RISCV64_SHA256)"
_out="$(_install riscv64)"
t_assert_contains "${_out}" "NOTE: hadolint publishes no riscv64 binary; none is installed"
t_assert_contains "${_out}" "shellcheck ${SC_V} and no hadolint in ${_work}/prefix-riscv64 (riscv64)"
t_assert_eq "shellcheck-${SC_V}.linux.riscv64.tar.xz $(_pin SHELLCHECK_LINUX_RISCV64_SHA256)" "$(sed 's|.*/||' "${FAKE_DL_LOG}")" "one download, shellcheck's"
t_assert_ok test ! -e "${_work}/prefix-riscv64/hadolint"

t_case "a tool that does not report its pin fails the install, and so does an unpinned arch"
t_assert_contains "$(FAKE_SC_VERSION=0.0.1 _install x86_64)" "shellcheck reports '0.0.1', the pin is ${SC_V}"
t_assert_contains "$(FAKE_HL_VERSION=1.0.0 _install x86_64)" "hadolint reports 'Haskell Dockerfile Linter 1.0.0', the pin is ${HL_V}"
t_assert_contains "$(FAKE_SC_FINDING=clean _install x86_64)" "shellcheck did not report SC2086"
t_assert_contains "$(_install sparc64)" "no lint tools are pinned for sparc64"
t_assert_eq 1 "$(FAKE_ARCH=sparc64 PATH="${_work}/bin:${PATH}" t_rc bash "${INSTALL}" "${_work}/p" "" "${_work}/core")"

t_case "lint-shell.sh bootstraps the same riscv64 asset on a riscv64 host"
t_assert_eq "shellcheck-${SC_V}.linux.riscv64.tar.xz $(_pin SHELLCHECK_LINUX_RISCV64_SHA256)" "$(
  # shellcheck source=../01-core/lint-tool-release.sh
  source "${SCRIPTS}/01-core/lint-tool-release.sh"
  # shellcheck source=../01-core/tool-pins.env
  source "${PINS}"
  uname() { case "$1" in -s) printf Linux ;; -m) printf riscv64 ;; esac; }
  lint_tool_release_asset shellcheck "${SC_V}"
)"

t_case "the bump modules refresh every new pin with its version"
_bv="$(cat "${ROOT}"/docs/scripts/bump_*.py)"
t_assert_contains "${_bv}" '("SHELLCHECK_LINUX_RISCV64_SHA256", f"shellcheck-{v}.linux.riscv64.tar.xz")'
t_assert_fails grep -qF HADOLINT_SOURCE_SHA256 "${ROOT}"/docs/scripts/bump_tools.py

t_case "the torch stage installs both from release binaries, with no hadolint source build"
_torch="$(cat "${TORCH}")"
t_assert_contains "${_torch}" "RUN --mount=type=secret,id=asset_mirror,required=false bash /opt/scripts/packaging/install-lint-tools.sh"
t_assert_fails grep -qF hadolint-build "${TORCH}"
t_assert_fails grep -qF HADOLINT_SOURCE_SHA256 "${PINS}"

t_case "the shipped-image contract row holds both tools to their tool-pins.env pins (mutation)"
SMOKE="${SCRIPTS}/06-packaging/smoke-runtime-image.sh"
CONSUMER="${SCRIPTS}/06-packaging/runtime-consumer-contract.sh"
mkdir -p "${_work}/rt/06-packaging" "${_work}/rt/01-core"; cp "${PINS}" "${_work}/rt/01-core/"
t_fn_src "${SMOKE}" _consumer_contract_fact >> "${_work}/rt/06-packaging/row.sh" || exit 1
for _fn in _consumer_lint_tools_verdict _consumer_versioned_contract_verdict _consumer_versioned_verdict; do
  t_fn_src "${CONSUMER}" "${_fn}" >> "${_work}/rt/06-packaging/row.sh" || exit 1
done
t_fn_src "${SMOKE}" _rt_env_pin >> "${_work}/rt/06-packaging/row.sh" || exit 1
t_fn_src "${CONSUMER}" _rt_tool_pin >> "${_work}/rt/06-packaging/row.sh" || exit 1
_lint_row() { bash -c 'source "$1"; _consumer_lint_tools_verdict lint-tools "$2" "$3"' _ "${_work}/rt/06-packaging/row.sh" "$@"; }
_pins_want="shellcheck=${SC_V#v} hadolint=${HL_V#v}"
t_assert_eq "OK lint-tools ${_pins_want}" "$(_lint_row "FACT lint-tools ${_pins_want}" "${_pins_want}")"
t_assert_contains "$(_lint_row "FACT lint-tools shellcheck= hadolint=${HL_V#v}" "${_pins_want}")" "BAD lint-tools the image has shellcheck= hadolint="
t_assert_contains "$(_lint_row "FACT lint-tools shellcheck=${SC_V#v} hadolint=" "${_pins_want}")" "BAD lint-tools"
t_assert_contains "$(_lint_row "FACT other x" "${_pins_want}")" "NOFACT lint-tools"
t_assert_eq "${SC_V}" "$(bash -c 'source "$1"; _rt_tool_pin SHELLCHECK_VERSION' _ "${_work}/rt/06-packaging/row.sh")" "the row reads tool-pins.env"
_arch_row() { bash -c 'source "$1"; _consumer_versioned_verdict lint-tools "$2" "$3"' _ "${_work}/rt/06-packaging/row.sh" "$@"; }
t_assert_eq "OK lint-tools ${_pins_want}" "$(_arch_row "FACT lint-tools ${_pins_want}" amd64)" "amd64 wants hadolint at its pin"
t_assert_contains "$(_arch_row "FACT lint-tools shellcheck=${SC_V#v} hadolint=" amd64)" "BAD lint-tools"
t_assert_eq "OK lint-tools shellcheck=${SC_V#v} hadolint=" "$(_arch_row "FACT lint-tools shellcheck=${SC_V#v} hadolint=" riscv64)" "riscv64 ships no hadolint"
t_assert_contains "$(_arch_row "FACT lint-tools ${_pins_want}" riscv64)" "BAD lint-tools the image has ${_pins_want}"
_smoke_src="$(cat "${SMOKE}" "${SMOKE%/*}/runtime-consumer-contract.sh")"
t_assert_contains "${_smoke_src}" 'printf '"'"'FACT lint-tools shellcheck=%s hadolint=%s\n'"'"
t_assert_contains "${_smoke_src}" 'lint-tools)    _sc="$(_rt_tool_pin SHELLCHECK_VERSION)"; _hl="$(_rt_tool_pin HADOLINT_VERSION)"'
t_assert_contains "$(grep '^_CONSUMER_CONTRACT_ROWS=' "${SMOKE}")" " lint-tools"

t_summary
