#!/usr/bin/env bash
# python-ci-windows.yml's PowerShell-lint contract, which a green run cannot show; see docs/python-ci.md#turning-the-windows-powershell-lint-on
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
ROOT="$(cd "${TESTS_DIR}/../../.." && pwd)"
LANE_REL=".github/workflows/python-ci-windows.yml"
LANE="${ROOT}/${LANE_REL}"

t_case "the lane file is where preflight and every consumer expect it"
t_assert_ok test -f "${LANE}"

# _q <python-expression>: relative paths from ROOT, since a Git Bash /c/... path means nothing to native Windows python3.
_q() {
  (cd "${ROOT}" && python3 -c "
import sys, pathlib
sys.path.insert(0, 'linux/scripts')
import verify_workflow_conventions as V
lane = V.load_yaml(pathlib.Path('${LANE_REL}'))
jobs = V.value(lane, 'jobs') or {}
call = V.value(V.value(lane, 'on'), 'workflow_call')
inputs = V.value(call, 'inputs') or {}
secrets = V.value(call, 'secrets') or {}
job = V.value(jobs, 'lint-powershell')
build = V.value(jobs, 'build-test-python-package-on-windows')
steps = V.value(job, 'steps') if job else []
raw = pathlib.Path('${LANE_REL}').read_text(encoding='utf-8')
def run_text():
    return '\n'.join(str(V.value(s, 'run') or '') for s in (steps or []))
print($1)
" 2>&1)
}

# Needles are whole command fragments, never bare flags, which the lane's comments also name.
_raw_has() { grep -qF -- "$1" "${LANE}" && echo True || echo False; }

t_case "the two inputs exist, so a consumer configures instead of copying a job"
t_assert_eq "True" "$(_q "'lint-powershell' in inputs")"
t_assert_eq "True" "$(_q "'lint-path' in inputs")"

t_case "lint-powershell is a boolean that DEFAULTS OFF"
# Every caller that predates the input must be byte-for-byte unaffected.
t_assert_eq "boolean" "$(_q "V.value(V.value(inputs,'lint-powershell'),'type')")"
t_assert_eq "false" "$(_q "V.value(V.value(inputs,'lint-powershell'),'default')")"
t_assert_eq "false" "$(_q "V.value(V.value(inputs,'lint-powershell'),'required')")"

t_case "lint-path is a string defaulting to the family layout's scripts tree"
t_assert_eq "string" "$(_q "V.value(V.value(inputs,'lint-path'),'type')")"
t_assert_eq "scripts" "$(_q "V.value(V.value(inputs,'lint-path'),'default')")"

t_case "the lint job exists and is gated on the input"
t_assert_eq "True" "$(_q "job is not None")"
t_assert_contains "$(_q "V.value(job,'if')")" "inputs.lint-powershell" \
  "without the gate every existing caller would suddenly run a Windows lint job"

t_case "the lint job does NOT wait for the build job"
# Chained behind the build, the lint would hide behind the very failure it explains.
t_assert_eq "None" "$(_q "V.value(job,'needs')")"

t_case "it runs on the lane's pinned Windows runner, never a moving alias"
t_assert_contains "$(_q "V.value(job,'runs-on')")" "inputs.runs-on"
t_assert_eq "False" "$(_q "'windows-latest' in str(V.value(job,'runs-on'))")"

t_case "the checkout takes submodules: the gate and its ruleset live in one"
t_assert_eq "True" "$(_q "any(str(V.value(V.value(s,'with'),'submodules')) == 'true' for s in steps if V.value(s,'uses'))")"

t_case "every action the job uses is SHA-pinned"
t_assert_eq "True" "$(_q "all('@' in str(V.value(s,'uses')) and len(str(V.value(s,'uses')).split('@')[1]) == 40 for s in steps if V.value(s,'uses'))")"

t_case "PSScriptAnalyzer is installed at a pinned version"
# Unpinned, a new analyzer rule fails the lane with no commit to blame.
t_assert_eq "True" "$(_q "'-RequiredVersion' in run_text()")"
t_assert_eq "False" "$(_q "'Install-Module PSScriptAnalyzer -Force' in run_text()")"

t_case "the gate is the HUB's script, pointed at the CALLER's tree"
t_assert_eq "True" "$(_raw_has '$gate = '"'"'third_party/ANTfrastructure/windows/scripts/Invoke-Lint.ps1'"'"'')"

t_case "the gate is invoked with -Path <lint-path> AND -FailOnAnalyzer"
# Without -FailOnAnalyzer, analyzer findings print and the script still exits 0.
t_assert_eq "True" "$(_raw_has "pwsh -NoProfile -File \$gate -Path '\${{ inputs.lint-path }}' -FailOnAnalyzer")"

# Build half: a caller without a Python package must be able to take the lint alone
t_case "build-python-package is a boolean that DEFAULTS ON"
# Callers written before the switch existed must still build.
t_assert_eq "True" "$(_q "'build-python-package' in inputs")"
t_assert_eq "boolean" "$(_q "V.value(V.value(inputs,'build-python-package'),'type')")"
t_assert_eq "true" "$(_q "V.value(V.value(inputs,'build-python-package'),'default')")"
t_assert_eq "false" "$(_q "V.value(V.value(inputs,'build-python-package'),'required')")"

t_case "the build job is GATED on it, which is what makes the lint takeable alone"
t_assert_eq "True" "$(_q "build is not None")"
t_assert_contains "$(_q "V.value(build,'if')")" "inputs.build-python-package"   "with no if: a caller that wants only the lint also buys an image pull, a package build and a ./dist/ upload"

t_case "neither job waits for the other: both switches are independent"
t_assert_eq "None" "$(_q "V.value(build,'needs')")"
t_assert_eq "None" "$(_q "V.value(job,'needs')")"

t_case "GHCR_PAT is NOT required, so a lint-only caller need not own a token"
# A required secret is refused at call time, locking out the `build-python-package: false` callers.
t_assert_eq "True" "$(_q "'GHCR_PAT' in secrets")"
t_assert_eq "false" "$(_q "V.value(V.value(secrets,'GHCR_PAT'),'required')")"

t_case "the build job asserts the token it does need, and names the way out"
# Otherwise the empty secret surfaces as an opaque ghcr `docker login` failure.
t_assert_eq "True" "$(_raw_has 'if (-not $env:GHCR_PAT) {')"
t_assert_eq "True" "$(_raw_has 'build-python-package: false to take the PowerShell lint alone')"

t_case "a missing submodule fails with a message that names the fix"
# `pwsh -File <absent>` reads as a broken lane, not an un-checked-out submodule.
t_assert_eq "True" "$(_raw_has 'Test-Path -LiteralPath $gate')"

t_summary
