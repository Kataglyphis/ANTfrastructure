#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${REPO_ROOT}/logs/code-quality/wsl"
LOG_FILE="${LOG_DIR}/wsl-quality.log"
log_child=0
if [ "${1:-}" = --log-child ]; then log_child=1; shift; fi
MODE="${1:-setup}"

usage() {
  cat <<'EOF'
Usage: bash linux/scripts/wsl-quality.sh [setup|check|all] [--jobs N]

  setup  install pinned Linux and PowerShell quality-check prerequisites
  check  run Linux preflight, mutation proofs, and Windows PowerShell checks
  all    install prerequisites, then run every local quality check
  --jobs N  limit parallel test workers (default: 4)
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

case "${MODE}" in
  help|--help|-h) usage; exit 0 ;;
  setup|check|all) ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -le 3 ] || die "expected one command and optional --jobs N; see --help"

jobs=4
if [ "$#" -gt 0 ]; then shift; fi
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --jobs ] || die "expected --jobs N; see --help"
  jobs="$2"
  [[ "${jobs}" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
fi

if [ "${log_child}" -eq 0 ]; then
  mkdir -p "${LOG_DIR}"
  git -C "${REPO_ROOT}" check-ignore -q --no-index -- logs \
    || die "logs/ must stay ignored by Git"
  _args=("${MODE}" --jobs "${jobs}")
  set +e
  "${BASH_SOURCE[0]}" --log-child "${_args[@]}" 2>&1 | tee "${LOG_FILE}"
  _status="${PIPESTATUS[0]}"
  exit "${_status}"
fi

resolve_windows_pwsh() {
  type -P pwsh.exe || true
}

WINDOWS_PWSH_BIN="$(resolve_windows_pwsh)"
PATH="/usr/local/sbin:/usr/local/bin:${HOME}/.local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

VERSIONS_FILE="${REPO_ROOT}/linux/scripts/01-core/versions.env"
TOOL_PINS_FILE="${REPO_ROOT}/linux/scripts/01-core/tool-pins.env"
source "${REPO_ROOT}/linux/scripts/01-core/load-versions-env.sh"
unset UV_VERSION PYTHON_VERSION PWSH_VERSION PWSH_LINUX_X64_SHA256 PWSH_LINUX_ARM64_SHA256 \
  PSSCRIPTANALYZER_VERSION PSSCRIPTANALYZER_NUPKG_SHA256 SHELLCHECK_VERSION
load_versions_env "${VERSIONS_FILE}"
load_versions_env "${TOOL_PINS_FILE}"

: "${UV_VERSION:?UV_VERSION is missing from versions.env}"
: "${PYTHON_VERSION:?PYTHON_VERSION is missing from versions.env}"
: "${PWSH_VERSION:?PWSH_VERSION is missing from versions.env}"
: "${PSSCRIPTANALYZER_VERSION:?PSSCRIPTANALYZER_VERSION is missing from versions.env}"
: "${SHELLCHECK_VERSION:?SHELLCHECK_VERSION is missing from tool-pins.env}"

PWSH_BIN="${HOME}/.local/bin/pwsh"
PWSH_HOME="${HOME}/.local/share/antfrastructure/powershell/${PWSH_VERSION}"
PESTER_MIN_VERSION="$(sed -n "s/^\$pesterMinVersion = \[version\]'\([0-9.]*\)'/\1/p" \
  "${REPO_ROOT}/windows/scripts/tests/Invoke-Tests.ps1")"
[ -n "${PESTER_MIN_VERSION}" ] || die "could not read Pester's minimum version from Invoke-Tests.ps1"

require_wsl_ubuntu() {
  [ -r /etc/os-release ] || die "this setup requires Ubuntu under WSL2"
  . /etc/os-release
  [ "${ID:-}" = ubuntu ] || die "this setup requires Ubuntu under WSL2 (found ${ID:-unknown})"
  grep -qi microsoft /proc/sys/kernel/osrelease \
    || die "this setup must run inside WSL2, not Linux on the Windows mount"
  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) die "PowerShell quality checks are unsupported on $(uname -m)" ;;
  esac
}

run_as_root() {
  if [ "${EUID}" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "sudo is required to install Ubuntu packages"
  fi
}

install_os_packages() {
  local package
  local -a packages=(ca-certificates curl git jq libgssapi-krb5-2 libicu-dev \
    python3 python3-venv ripgrep tar unzip xz-utils)
  local -a missing=()
  for package in "${packages[@]}"; do
    dpkg-query -W -f='${db:Status-Status}' "${package}" 2>/dev/null | grep -qx installed \
      || missing+=("${package}")
  done
  [ "${#missing[@]}" -gt 0 ] || { printf 'Ubuntu test packages are already installed.\n'; return 0; }
  run_as_root apt-get update -qq
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
}

ensure_uv() {
  local current=""
  if command -v uv >/dev/null 2>&1; then current="$(uv --version | awk '{print $2}')"; fi
  if [ "${current}" != "${UV_VERSION}" ] || ! command -v uvx >/dev/null 2>&1; then
    printf 'Installing the repository-pinned uv %s.\n' "${UV_VERSION}"
    run_as_root bash "${REPO_ROOT}/linux/scripts/01-core/base-image.sh" install-uv --version "${UV_VERSION}"
  fi
}

ensure_shellcheck() {
  local current="" pinned_bin
  if command -v shellcheck >/dev/null 2>&1; then
    current="$(shellcheck --version | sed -n 's/^version: //p' | head -n 1)"
  fi
  # The pin is the release tag (v0.11.0); --version prints the bare number.
  if [ "${current}" != "${SHELLCHECK_VERSION#v}" ]; then
    pinned_bin="$(bash "${REPO_ROOT}/linux/scripts/lint-shell.sh" --print-bin)"
    install -d "${HOME}/.local/bin"
    install -m 0755 "${pinned_bin}" "${HOME}/.local/bin/shellcheck"
  fi
}

pwsh_modules_are_ready() {
  local command
  [ -x "${PWSH_BIN}" ] || return 1
  command="
\$ErrorActionPreference = 'Stop'
if (\$PSVersionTable.PSVersion.ToString() -ne '${PWSH_VERSION}') { exit 1 }
\$analyzer = Get-Module -ListAvailable PSScriptAnalyzer | Where-Object Version -eq ([version]'${PSSCRIPTANALYZER_VERSION}') | Select-Object -First 1
\$pester = Get-Module -ListAvailable Pester | Where-Object Version -ge ([version]'${PESTER_MIN_VERSION}') | Select-Object -First 1
if (\$null -eq \$analyzer -or \$null -eq \$pester) { exit 1 }
"
  "${PWSH_BIN}" -NoLogo -NoProfile -NonInteractive -Command "${command}" >/dev/null 2>&1
}

ensure_pwsh() {
  if pwsh_modules_are_ready; then
    ln -sfn "${PWSH_HOME}/pwsh" "${PWSH_BIN}"
    return 0
  fi
  source "${REPO_ROOT}/linux/scripts/01-core/downloads.sh"
  source "${REPO_ROOT}/linux/scripts/06-packaging/package-image-wiring.sh"
  install_pwsh "${VERSIONS_FILE}" "${PWSH_HOME}" "${HOME}/.local/bin" "$(uname -m)"
}

ensure_pester() {
  "${PWSH_BIN}" -NoLogo -NoProfile -NonInteractive -Command "
\$ErrorActionPreference = 'Stop'
\$minimum = [version]'${PESTER_MIN_VERSION}'
\$module = Get-Module -ListAvailable Pester | Where-Object Version -ge \$minimum | Select-Object -First 1
if (\$null -eq \$module) {
    Install-Module Pester -MinimumVersion \$minimum -Scope CurrentUser -Force -SkipPublisherCheck -Repository PSGallery
}
"
}

require_windows_interop() {
  [ -n "${WINDOWS_PWSH_BIN}" ] && [ -x "${WINDOWS_PWSH_BIN}" ] \
    || die "Windows PowerShell 7 (pwsh.exe) is missing from WSL interop PATH"
  command -v wslpath >/dev/null 2>&1 || die "wslpath is missing; enable WSL interop"
}

native_ps_command() {
  local encoded
  encoded="$(printf '%s' "$1" | python3 -c '
import base64
import sys

print(base64.b64encode(sys.stdin.buffer.read().decode("utf-8").encode("utf-16le")).decode("ascii"))
')" || return 1
  "${WINDOWS_PWSH_BIN}" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "${encoded}"
}

windows_pwsh7_ready() {
  native_ps_command 'if (-not $IsWindows -or $PSVersionTable.PSVersion.Major -lt 7) { exit 1 }' >/dev/null 2>&1
}

windows_pester_ready() {
  local command
  command="\$m = Get-Module -ListAvailable Pester | Where-Object { \$_.Version -ge [version]'${PESTER_MIN_VERSION}' }; if (-not \$m) { exit 1 }"
  native_ps_command "${command}" >/dev/null 2>&1
}

ensure_windows_pester() {
  local bootstrap quoted command
  require_windows_interop
  windows_pwsh7_ready || die "pwsh.exe must be native Windows PowerShell 7 or newer"
  windows_pester_ready && return 0
  bootstrap="$(wslpath -w "${REPO_ROOT}/windows/scripts/modules/WindowsCi.ModuleBootstrap.psm1")" \
    || die "cannot map the Windows Pester bootstrap path"
  [ -n "${bootstrap}" ] || die "cannot map the Windows Pester bootstrap path"
  quoted="${bootstrap//\'/\'\'}"
  command="\$ErrorActionPreference = 'Stop'; Import-Module '${quoted}' -ErrorAction Stop; Install-PinnedPowerShellModule -Name Pester -Version '${PESTER_MIN_VERSION}' -Minimum -SkipPublisherCheck | Out-Null"
  native_ps_command "${command}" || die "Windows Pester installation failed"
  windows_pester_ready || die "Windows Pester >= ${PESTER_MIN_VERSION} is still missing after setup"
}

setup_environment() {
  require_wsl_ubuntu
  require_windows_interop
  install_os_packages
  ensure_uv
  uv python install "${PYTHON_VERSION}"
  uv sync --project quality --locked --python "${PYTHON_VERSION}"
  ensure_pwsh
  ensure_pester
  ensure_windows_pester
  ensure_shellcheck
  verify_environment
}

verify_environment() {
  local tool shellcheck_version
  require_wsl_ubuntu
  for tool in bash git jq python3 rg shellcheck uv uvx; do
    command -v "${tool}" >/dev/null 2>&1 || die "${tool} is missing; run bash linux/scripts/wsl-quality.sh setup"
  done
  [ "$(uv --version | awk '{print $2}')" = "${UV_VERSION}" ] \
    || die "uv is not ${UV_VERSION}; run bash linux/scripts/wsl-quality.sh setup"
  shellcheck_version="$(shellcheck --version | sed -n 's/^version: //p' | head -n 1)"
  [ "${shellcheck_version}" = "${SHELLCHECK_VERSION#v}" ] \
    || die "shellcheck is not ${SHELLCHECK_VERSION}; run bash linux/scripts/wsl-quality.sh setup"
  pwsh_modules_are_ready || die "pinned pwsh, PSScriptAnalyzer or Pester is missing; run bash linux/scripts/wsl-quality.sh setup"
  require_windows_interop
  windows_pwsh7_ready || die "pwsh.exe must be native Windows PowerShell 7 or newer"
  windows_pester_ready || die "Windows Pester >= ${PESTER_MIN_VERSION} is missing; run bash linux/scripts/wsl-quality.sh setup"
  uv run --project quality --locked --no-sync \
    --python "${PYTHON_VERSION}" python -c 'import pytest, yaml; print("Locked Python quality environment is ready.")'
}

run_logged() {
  local name="$1"
  shift
  printf '\n== %s ==\n' "${name}"
  "$@" 2>&1 | tee "${LOG_DIR}/${name}.log"
}

run_windows_tests() {
  local windows_test_script
  windows_test_script="$(wslpath -w "${REPO_ROOT}/windows/scripts/tests/Invoke-Tests.ps1")" \
    || die "cannot map the Windows test runner path"
  [ -n "${windows_test_script}" ] || die "cannot map the Windows test runner path"
  run_logged windows-tests "${WINDOWS_PWSH_BIN}" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${windows_test_script}" -Jobs "$1"
}

run_quality_checks() {
  local python_command="uv run --project quality --locked --no-sync --python ${PYTHON_VERSION} python"
  local parallelism="${jobs}"
  verify_environment
  mkdir -p "${LOG_DIR}"
  run_logged linux-preflight env PREFLIGHT_PYTHON="${python_command}" PREFLIGHT_JOBS="${parallelism}" \
    RUN_TESTS_JOBS="${parallelism}" LINT_SHELL_JOBS="${parallelism}" PREFLIGHT_SKIP=mutations \
    bash "${REPO_ROOT}/linux/scripts/preflight.sh"
  run_logged mutation-proofs env PREFLIGHT_PYTHON="${python_command}" \
    uv run --project quality --locked --no-sync --python "${PYTHON_VERSION}" python \
    "${REPO_ROOT}/docs/scripts/verify_mutations.py" --jobs "${parallelism}"
  run_logged windows-lint pwsh -NoLogo -NoProfile -File "${REPO_ROOT}/windows/scripts/Invoke-Lint.ps1" \
    -FailOnAnalyzer -Jobs "${parallelism}"
  run_logged windows-complexity pwsh -NoLogo -NoProfile -File "${REPO_ROOT}/windows/scripts/Invoke-CodeComplexity.ps1" \
    -Strict -JsonPath "${LOG_DIR}/windows-complexity.json"
  run_windows_tests "${parallelism}"
}

main() {
  case "${MODE}" in
    setup) setup_environment ;;
    check) run_quality_checks ;;
    all) setup_environment; run_quality_checks ;;
  esac
}

main
