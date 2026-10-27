#!/usr/bin/env bash
# Stubbed interop checks do not exercise real Windows PowerShell or WSL path translation.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
RUNNER="${TESTS_DIR}/../wsl-quality.sh"

_expect_rejected() {
  local expected="$1" label="$2" status
  shift 2
  if bash "${RUNNER}" "$@" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  t_assert_eq "${expected}" "${status}" "${label}"
}

t_case "WSL quality runner parses without installing host packages"
t_assert_ok bash -n "${RUNNER}"

t_case "help documents setup, full checks and combined use"
_help="$(bash "${RUNNER}" --help)"
t_assert_contains "${_help}" "setup" "setup is callable from WSL"
t_assert_contains "${_help}" "check" "all local quality checks have one entry point"
t_assert_contains "${_help}" "all" "setup and check can run together"

t_case "setup resolves its tools and Python packages from repository pins"
_source="$(cat "${RUNNER}")"
t_assert_contains "${_source}" 'install-uv --version "${UV_VERSION}"' "uv uses the shared release pin"
t_assert_contains "${_source}" 'uv sync --project quality --locked' "Python tools come from the locked quality project"
t_assert_contains "${_source}" 'PSScriptAnalyzer' "PowerShell lint installs its pinned analyzer"

t_case "check runs mutation proofs after the non-mutation preflight"
t_assert_contains "${_source}" 'PREFLIGHT_SKIP=mutations' "preflight mutation work is not duplicated"
t_assert_contains "${_source}" 'verify_mutations.py" --jobs' "the whole mutation manifest still runs"
t_assert_contains "${_source}" 'logs/code-quality/wsl' "run logs stay in the ignored log tree"

t_case "the worker limit reaches nested shell lint and test suites"
t_assert_contains "${_source}" "RUN_TESTS_JOBS=\"\${parallelism}\"" "script suites use the requested worker limit"
t_assert_contains "${_source}" "LINT_SHELL_JOBS=\"\${parallelism}\"" "shell lint uses the requested worker limit"

t_case "unknown commands fail before touching the host"
_expect_rejected 2 "bad command must not start an install" unknown

t_case "invalid worker counts fail before touching the host"
_expect_rejected 1 "a zero-worker test run must be rejected" check --jobs 0

_temp_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)" || exit 1
_WORK="$(mktemp -d "${_temp_root%/}/wsl-quality.XXXXXXXX")" || exit 1
case "$(cd "${_WORK}" && pwd -P)" in "${_temp_root%/}"/wsl-quality.*) ;; *) exit 1 ;; esac
trap 'rm -rf -- "${_WORK}"' EXIT
_BIN="${_WORK}/bin with space"
_ROOT="${_WORK}/repo with space"
_LOG="${_WORK}/logs"
_BASH="$(command -v bash)"
mkdir -p "${_BIN}" "${_ROOT}/linux/scripts" "${_ROOT}/windows/scripts/tests" "${_LOG}" "${_WORK}/empty"
printf '%s\n' '#!/usr/bin/env bash' 'echo preflight-fixture' > "${_ROOT}/linux/scripts/preflight.sh"
cat > "${_BIN}/wslpath" <<'SH'
#!/usr/bin/env bash
[ "${TEST_WSLPATH_RC:-0}" -eq 0 ] || exit "${TEST_WSLPATH_RC}"
[ "$1" = -w ] && [ "$#" -eq 2 ] || exit 2
[ "${TEST_WSLPATH_EMPTY:-0}" -ne 1 ] || exit 0
case "$2" in
  */WindowsCi.ModuleBootstrap.psm1) printf '%s\n' "${TEST_BOOTSTRAP_PATH}" ;;
  */Invoke-Tests.ps1) printf '%s\n' "${TEST_WINDOWS_TEST_PATH}" ;;
  *) exit 2 ;;
esac
SH
cat > "${_BIN}/pwsh.exe" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${TEST_NATIVE_ARGV}"
encoded=""
next=0
for arg in "$@"; do
  if [ "${next}" -eq 1 ]; then encoded="${arg}"; break; fi
  [ "${arg}" = -EncodedCommand ] && next=1
done
if [ -n "${encoded}" ]; then
  decoded="$(python3 -c '
import base64
import sys

print(base64.b64decode(sys.argv[1]).decode("utf-16le"))
' "${encoded}")" || exit 1
  printf '%s\n' "${decoded}" >> "${TEST_NATIVE_COMMANDS}"
  case "${decoded}" in
    *'PSVersionTable.PSVersion.Major'*) exit "${TEST_NATIVE_VERSION_RC:-0}" ;;
    *'Get-Module -ListAvailable Pester'*) [ -f "${TEST_PESTER_STATE}" ]; exit $? ;;
    *'Install-PinnedPowerShellModule'*)
      [ "${TEST_BOOTSTRAP_RC:-0}" -eq 0 ] || exit "${TEST_BOOTSTRAP_RC}"
      [ "${TEST_BOOTSTRAP_NO_INSTALL:-0}" -eq 1 ] || : > "${TEST_PESTER_STATE}"
      exit 0 ;;
    *) exit 2 ;;
  esac
fi
printf '%s\n' 'native Windows tests fixture'
exit "${TEST_NATIVE_EXIT:-0}"
SH
cat > "${_BIN}/pwsh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_LINUX_CALLS}"
SH
cat > "${_BIN}/uv" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { printf '%s\n' 'uv 0.1.0'; exit 0; }
printf '%s\n' 'uv fixture'
SH
cat > "${_BIN}/shellcheck" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'version: 9.8.7'
SH
for _tool in jq rg uvx; do
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${_BIN}/${_tool}"
done
chmod +x "${_BIN}/wslpath" "${_BIN}/pwsh.exe" "${_BIN}/pwsh" "${_BIN}/uv" "${_BIN}/shellcheck" \
  "${_BIN}/jq" "${_BIN}/rg" "${_BIN}/uvx"

_DRIVER="${_WORK}/driver.sh"
printf '%s\n' 'set -euo pipefail' > "${_DRIVER}"
for _function in die resolve_windows_pwsh require_windows_interop native_ps_command windows_pwsh7_ready \
  windows_pester_ready ensure_windows_pester verify_environment run_logged run_windows_tests run_quality_checks; do
  t_fn_src "${RUNNER}" "${_function}" >> "${_DRIVER}" || exit 1
done
cat >> "${_DRIVER}" <<'SH'
require_wsl_ubuntu() { :; }
pwsh_modules_are_ready() { :; }
case "${TEST_MODE}" in
  resolve) resolve_windows_pwsh ;;
  require) require_windows_interop ;;
  ensure) ensure_windows_pester ;;
  verify) verify_environment ;;
  run) verify_environment() { :; }; run_quality_checks ;;
esac
SH

_fixture() {
  local driver="$1" mode="$2" output status
  shift 2
  output="$(env TEST_BOOTSTRAP_NO_INSTALL=0 TEST_BOOTSTRAP_RC=0 TEST_NATIVE_EXIT=0 TEST_NATIVE_VERSION_RC=0 TEST_WSLPATH_EMPTY=0 TEST_WSLPATH_RC=0 \
    TEST_MODE="${mode}" REPO_ROOT="${_ROOT}" LOG_DIR="${_LOG}" PYTHON_VERSION=3.15 UV_VERSION=0.1.0 SHELLCHECK_VERSION=9.8.7 \
    PESTER_MIN_VERSION=6.2 jobs=3 WINDOWS_PWSH_BIN="${_BIN}/pwsh.exe" \
    TEST_NATIVE_ARGV="${_WORK}/native-argv" TEST_NATIVE_COMMANDS="${_WORK}/native-commands" \
    TEST_PESTER_STATE="${_WORK}/pester-installed" TEST_LINUX_CALLS="${_WORK}/linux-calls" \
    TEST_WINDOWS_TEST_PATH='C:\repo space\windows\scripts\tests\Invoke-Tests.ps1' \
    TEST_BOOTSTRAP_PATH="C:\repo 'space'\windows\scripts\modules\WindowsCi.ModuleBootstrap.psm1" \
    PATH="${_BIN}:${PATH}" "$@" "${_BASH}" "${driver}" 2>&1)"
  status=$?
  printf 'RC=%s\n%s\n' "${status}" "${output}"
}

t_case "Windows pwsh is resolved before PATH is narrowed"
t_assert_contains "$(_fixture "${_DRIVER}" resolve)" "${_BIN}/pwsh.exe" "the original PATH supplies the interop executable"
case "${_source}" in
  *'WINDOWS_PWSH_BIN="$(resolve_windows_pwsh)"'*'PATH="/usr/local/sbin:'*) t_assert_ok true ;;
  *) t_assert_ok false ;;
esac

t_case "missing native pwsh or wslpath fails with a useful diagnostic"
_missing="$(_fixture "${_DRIVER}" require WINDOWS_PWSH_BIN="${_WORK}/absent")"
t_assert_contains "${_missing}" 'RC=1'
t_assert_contains "${_missing}" 'Windows PowerShell 7 (pwsh.exe) is missing'
_missing="$(_fixture "${_DRIVER}" require PATH="${_WORK}/empty")"
t_assert_contains "${_missing}" 'RC=1'
t_assert_contains "${_missing}" 'wslpath is missing'

t_case "setup rejects an executable that is not native Windows PowerShell 7"
_failed="$(_fixture "${_DRIVER}" ensure TEST_NATIVE_VERSION_RC=9)"
t_assert_contains "${_failed}" 'RC=1'
t_assert_contains "${_failed}" 'pwsh.exe must be native Windows PowerShell 7 or newer'

t_case "setup reuses an installed Windows Pester and installs a missing one with the shared bootstrap"
: > "${_WORK}/pester-installed"
: > "${_WORK}/native-commands"
t_assert_contains "$(_fixture "${_DRIVER}" ensure)" 'RC=0'
t_assert_no_grep "${_WORK}/native-commands" 'Install-PinnedPowerShellModule'
rm -f -- "${_WORK}/pester-installed"
: > "${_WORK}/native-commands"
t_assert_contains "$(_fixture "${_DRIVER}" ensure)" 'RC=0'
t_assert_ok test -f "${_WORK}/pester-installed"
t_assert_contains "$(cat "${_WORK}/native-commands")" "Install-PinnedPowerShellModule -Name Pester -Version '6.2' -Minimum"
t_assert_contains "$(cat "${_WORK}/native-commands")" "C:\repo ''space''\windows\scripts\modules\WindowsCi.ModuleBootstrap.psm1"

t_case "fixture defaults isolate setup and tests from inherited failure settings"
_inherited="$(
  export TEST_BOOTSTRAP_NO_INSTALL=1 TEST_BOOTSTRAP_RC=7 TEST_NATIVE_EXIT=7 TEST_NATIVE_VERSION_RC=7 TEST_WSLPATH_EMPTY=1 TEST_WSLPATH_RC=7
  rm -f -- "${_WORK}/pester-installed"
  _fixture "${_DRIVER}" ensure
  _fixture "${_DRIVER}" run
)"
t_assert_eq 2 "$(printf '%s\n' "${_inherited}" | grep -c '^RC=0$')" "both operations ignore inherited failure settings"

t_case "a failed or ineffective Windows Pester install fails setup"
rm -f -- "${_WORK}/pester-installed"
_failed="$(_fixture "${_DRIVER}" ensure TEST_BOOTSTRAP_RC=7)"
t_assert_contains "${_failed}" 'RC=1'
t_assert_contains "${_failed}" 'Windows Pester installation failed'
_failed="$(_fixture "${_DRIVER}" ensure TEST_BOOTSTRAP_NO_INSTALL=1)"
t_assert_contains "${_failed}" 'RC=1'
t_assert_contains "${_failed}" 'Windows Pester >= 6.2 is still missing'
_failed="$(_fixture "${_DRIVER}" ensure TEST_WSLPATH_EMPTY=1)"
t_assert_contains "${_failed}" 'RC=1'
t_assert_contains "${_failed}" 'cannot map the Windows Pester bootstrap path'

t_case "check requires the native Windows Pester version without installing it"
: > "${_WORK}/pester-installed"
t_assert_contains "$(_fixture "${_DRIVER}" verify)" 'RC=0'
rm -f -- "${_WORK}/pester-installed"
: > "${_WORK}/native-commands"
_failed="$(_fixture "${_DRIVER}" verify)"
t_assert_contains "${_failed}" 'RC=1'
t_assert_contains "${_failed}" 'Windows Pester >= 6.2 is missing'
t_assert_no_grep "${_WORK}/native-commands" 'Install-PinnedPowerShellModule'

_missing_pester_is_fatal() {
  local outcome
  outcome="$(_fixture "$1" verify)"
  if [[ "${outcome}" == *'RC=1'* && "${outcome}" == *'Windows Pester >= 6.2 is missing'* ]]; then return 0; fi
  return 1
}

_failure_is_fatal() {
  local outcome
  rm -f -- "${_LOG}/windows-tests.log" "${_WORK}/native-argv"
  outcome="$(_fixture "$1" run TEST_NATIVE_EXIT=7)"
  if [[ "${outcome}" == *'RC=7'* ]] && grep -qF 'native Windows tests fixture' "${_LOG}/windows-tests.log"; then return 0; fi
  return 1
}

_mutation_detected() {
  local expression="$1" check="$2" mode="$3" outcome mutant="${_WORK}/mutant.sh"
  sed "${expression}" "${_DRIVER}" > "${mutant}" || return 1
  [ -s "${mutant}" ] && ! cmp -s "${_DRIVER}" "${mutant}" || return 1
  "${check}" "${_DRIVER}" || return 1
  if "${check}" "${mutant}"; then return 1; fi
  if [ "${mode}" = verify ]; then : > "${_WORK}/pester-installed"; fi
  outcome="$(_fixture "${mutant}" "${mode}")"
  if [ "${mode}" = verify ]; then rm -f -- "${_WORK}/pester-installed"; fi
  if [[ "${outcome}" == *'RC=0'* ]]; then return 0; fi
  return 1
}

t_case "removing the Windows Pester check fails the fixture (mutation)"
t_assert_ok _mutation_detected '\@windows_pester_ready || die "Windows Pester >= .* is missing; run bash linux/scripts/wsl-quality.sh setup"@d' \
  _missing_pester_is_fatal verify

t_case "Linux lint remains on Linux pwsh and Windows tests use one translated path argument"
: > "${_WORK}/linux-calls"
_run="$(_fixture "${_DRIVER}" run)"
t_assert_contains "${_run}" 'RC=0'
t_assert_grep "${_WORK}/linux-calls" 'Invoke-Lint.ps1'
t_assert_grep "${_WORK}/linux-calls" 'Invoke-CodeComplexity.ps1'
t_assert_no_grep "${_WORK}/linux-calls" 'Invoke-Tests.ps1'
t_assert_contains "$(cat "${_WORK}/native-argv")" 'C:\repo space\windows\scripts\tests\Invoke-Tests.ps1'
t_assert_contains "$(cat "${_WORK}/native-argv")" "$(printf '%s\n' '-ExecutionPolicy' 'Bypass')"
t_assert_contains "$(cat "${_WORK}/native-argv")" "$(printf '%s\n' '-Jobs' '3')"
t_assert_contains "$(cat "${_LOG}/windows-tests.log")" 'native Windows tests fixture'

t_case "Windows test failure reaches the caller and a swallowed-status mutant is rejected"
t_assert_ok _mutation_detected 's/-Jobs "\$1"$/-Jobs "$1" || true/' _failure_is_fatal run

t_case "an unmappable Windows path fails before starting tests"
rm -f -- "${_WORK}/native-argv"
_failed="$(_fixture "${_DRIVER}" run TEST_WSLPATH_RC=12)"
t_assert_contains "${_failed}" 'RC=1'
t_assert_contains "${_failed}" 'cannot map the Windows test runner path'
t_assert_fails test -e "${_WORK}/native-argv"
_failed="$(_fixture "${_DRIVER}" run TEST_WSLPATH_EMPTY=1)"
t_assert_contains "${_failed}" 'RC=1'
t_assert_contains "${_failed}" 'cannot map the Windows test runner path'
t_assert_fails test -e "${_WORK}/native-argv"

t_summary
