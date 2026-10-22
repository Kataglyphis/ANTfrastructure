#!/usr/bin/env bash
# Shared bootstrap policy keeps release selection and checksum refusal aligned across lint gates.
_lint_tool_release_host() {
  local tool="$1" host
  host="$(uname -s)/$(uname -m)"
  case "${host}" in
    Linux/x86_64|Linux/amd64) host=linux-amd64 ;;
    Linux/aarch64|Linux/arm64) host=linux-arm64 ;;
    Linux/riscv64) host=linux-riscv64 ;;
    MINGW*/x86_64|MSYS*/x86_64|CYGWIN*/x86_64) host=windows-amd64 ;;
    MINGW*/aarch64|MSYS*/aarch64|CYGWIN*/aarch64|MINGW*/arm64|MSYS*/arm64|CYGWIN*/arm64)
      # Preserve hadolint's existing ARM selection; no other tool supports this host.
      [ "${tool}" = hadolint ] || return 1
      host=linux-arm64 ;;
    *) return 1 ;;
  esac
  printf '%s' "${host}"
}

lint_tool_release_asset() {
  local tool="$1" version="$2" host asset checksum
  host="$(_lint_tool_release_host "${tool}")" || return $?
  case "${tool}/${host}" in
    shellcheck/linux-amd64) asset="shellcheck-${version}.linux.x86_64.tar.xz"; checksum=SHELLCHECK_LINUX_X86_64_SHA256 ;;
    shellcheck/linux-arm64) asset="shellcheck-${version}.linux.aarch64.tar.xz"; checksum=SHELLCHECK_LINUX_AARCH64_SHA256 ;;
    shellcheck/linux-riscv64) asset="shellcheck-${version}.linux.riscv64.tar.xz"; checksum=SHELLCHECK_LINUX_RISCV64_SHA256 ;;
    shellcheck/windows-amd64) asset="shellcheck-${version}.zip"; checksum=SHELLCHECK_WINDOWS_SHA256 ;;
    actionlint/linux-amd64) asset="actionlint_${version}_linux_amd64.tar.gz"; checksum=ACTIONLINT_LINUX_AMD64_SHA256 ;;
    actionlint/linux-arm64) asset="actionlint_${version}_linux_arm64.tar.gz"; checksum=ACTIONLINT_LINUX_ARM64_SHA256 ;;
    actionlint/windows-amd64) asset="actionlint_${version}_windows_amd64.zip"; checksum=ACTIONLINT_WINDOWS_AMD64_SHA256 ;;
    hadolint/linux-amd64) asset=hadolint-linux-x86_64; checksum=HADOLINT_LINUX_X86_64_SHA256 ;;
    hadolint/linux-arm64) asset=hadolint-linux-arm64; checksum=HADOLINT_LINUX_ARM64_SHA256 ;;
    hadolint/windows-amd64) asset=hadolint-windows-x86_64.exe; checksum=HADOLINT_WINDOWS_X86_64_SHA256 ;;
    *) return 1 ;;
  esac
  printf '%s %s\n' "${asset}" "${!checksum:-}"
}

_lint_tool_load_pin() {
  # shellcheck source=./load-versions-env.sh
  source "${CORE_DIR}/load-versions-env.sh" || return $?
  load_versions_env "${CORE_DIR}/tool-pins.env"
}

lint_tool_ensure() {
  local tool="$1" output="$2" path_bin version pin_name asset expected_sha
  pin_name="${tool^^}_VERSION"
  # ShellCheck's PATH copy must match its pin; the other gates retain their PATH preference.
  if [ "${tool}" = shellcheck ]; then
    _lint_tool_load_pin || return $?
    [ -n "${!pin_name:-}" ] || err "${pin_name} is not set (tool-pins.env not found?)."
  fi
  path_bin="$(command -v "${tool}" || true)"
  if [ -n "${path_bin}" ]; then
    if [ "${tool}" != shellcheck ] || [ "$("${path_bin}" --version 2>/dev/null | sed -n 's/^version: //p')" = "${!pin_name#v}" ]; then
      printf -v "${output}" '%s' "${path_bin}"
      return 0
    fi
  fi
  if [ "${tool}" != shellcheck ]; then _lint_tool_load_pin || return $?; fi
  version="${!pin_name:-}"
  [ -n "${version}" ] || err "${pin_name} is not set (tool-pins.env not found?)."
  read -r asset expected_sha < <(lint_tool_release_asset "${tool}" "${version}") \
    || err "Unsupported platform for ${tool} bootstrap ($(uname -s)/$(uname -m)); install ${tool} on PATH instead."
  [ -n "${expected_sha}" ] || err "No pinned ${tool} SHA256 for ${asset}; add one to tool-pins.env."
  _lint_tool_install "${tool}" "${output}" "${version}" "${asset}" "${expected_sha}"
}

_lint_tool_install() {
  local tool="$1" output="$2" version="$3" asset="$4" expected_sha="$5"
  local cache_name cache_root binary member repo tag
  cache_name="${tool^^}_CACHE_DIR"
  cache_root="${!cache_name:-${TMPDIR:-/tmp}}/${tool}-${version}"
  binary="${tool}"
  case "${asset}" in *.zip|*.exe) binary="${tool}.exe" ;; esac
  printf -v "${output}" '%s' "${cache_root}/${binary}"
  [ ! -x "${!output}" ] || return 0
  # shellcheck source=./downloads.sh
  source "${CORE_DIR}/downloads.sh" || err "downloads.sh not available for verified ${tool} fetch"
  case "${tool}" in
    shellcheck) repo=koalaman/shellcheck; tag="${version}"; member="${binary}"; case "${asset}" in *.tar.xz) member="shellcheck-${version}/${binary}" ;; esac ;;
    actionlint) repo=rhysd/actionlint; tag="v${version}"; member="${binary}" ;;
    hadolint) repo=hadolint/hadolint; tag="${version}"; member='' ;;
    *) return 2 ;;
  esac
  download_verified_install "https://github.com/${repo}/releases/download/${tag}/${asset}" \
    "${expected_sha}" "${!output}" ${member:+"${member}"} \
    || err "Verified install of ${asset} failed (checksum mismatch, network or extraction error)."
}
