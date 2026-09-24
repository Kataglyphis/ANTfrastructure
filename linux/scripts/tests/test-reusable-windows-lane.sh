#!/usr/bin/env bash
# The CONTRACT of python-ci-windows.yml's PowerShell-lint half, which exists
# because OrchestrANT and OxidANT hand-wrote the same job within a week and
# differed only in the directory they pointed the gate at.
#
# Each assertion is a thing a green run cannot show: the switch defaults OFF,
# the job does not `needs:` the build, -FailOnAnalyzer is passed, and the
# analyzer install is version-pinned. Why each one, and the caller-side shape:
# docs/python-ci.md#turning-the-windows-powershell-lint-on
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
ROOT="$(cd "${TESTS_DIR}/../../.." && pwd)"
LANE_REL=".github/workflows/python-ci-windows.yml"
LANE="${ROOT}/${LANE_REL}"

t_case "the lane file is where preflight and every consumer expect it"
t_assert_ok test -f "${LANE}"

# _q <python-expression> -- prints one line, evaluated against the parsed lane.
# `lane`, `jobs`, `inputs` and `job` are in scope; V.value unwraps the loader's
# (value, line) pairs. Python runs in ROOT and gets RELATIVE paths: a Git Bash
# path (/c/...) means nothing to a native Windows python3, so it failed there.
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

# _raw_has <literal> -- True when the lane's TEXT contains it. The lint step's
# command is a block scalar the loader does not fold, so the command assertions
# read the file. Each needle below is the WHOLE command fragment it is about,
# never a bare flag name: the prose above the step names those flags too, and a
# needle that matches the comment would survive their removal from the command.
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
# A syntax error in the build scripts is exactly when this gate is worth
# having; chaining it behind the build would hide it behind the failure it
# explains, and behind an image pull it does not need.
t_assert_eq "None" "$(_q "V.value(job,'needs')")"

t_case "it runs on the lane's pinned Windows runner, never a moving alias"
t_assert_contains "$(_q "V.value(job,'runs-on')")" "inputs.runs-on"
t_assert_eq "False" "$(_q "'windows-latest' in str(V.value(job,'runs-on'))")"

t_case "the checkout takes submodules: the gate and its ruleset live in one"
t_assert_eq "True" "$(_q "any(str(V.value(V.value(s,'with'),'submodules')) == 'true' for s in steps if V.value(s,'uses'))")"

t_case "every action the job uses is SHA-pinned"
t_assert_eq "True" "$(_q "all('@' in str(V.value(s,'uses')) and len(str(V.value(s,'uses')).split('@')[1]) == 40 for s in steps if V.value(s,'uses'))")"

t_case "PSScriptAnalyzer is installed at a pinned version"
# Unpinned, a new analyzer release adds a rule and the lane fails with no
# commit to blame -- the argument every other pin in this repo makes.
t_assert_eq "True" "$(_q "'-RequiredVersion' in run_text()")"
t_assert_eq "False" "$(_q "'Install-Module PSScriptAnalyzer -Force' in run_text()")"

t_case "the gate is the HUB's script, pointed at the CALLER's tree"
t_assert_eq "True" "$(_raw_has '$gate = '"'"'third_party/ANTfrastructure/windows/scripts/Invoke-Lint.ps1'"'"'')"

t_case "the gate is invoked with -Path <lint-path> AND -FailOnAnalyzer"
# Without -FailOnAnalyzer the analyzer pass prints its findings and the script
# still exits 0, which is a check that cannot fail. Both consumers that
# hand-wrote this job reached the same conclusion on their own.
t_assert_eq "True" "$(_raw_has "pwsh -NoProfile -File \$gate -Path '\${{ inputs.lint-path }}' -FailOnAnalyzer")"

# THE BUILD HALF, for the same reason the lint half is here: until the build job
# took an `if:` the lint could not be had without it, so OxidANT -- a Rust crate
# with no Python package, whose Windows container build is a different workflow
# -- kept its own copy of a job it had measured as byte-for-byte identical.
t_case "build-python-package is a boolean that DEFAULTS ON"
# The whole caller-compatibility argument: a lane whose build job can be turned
# off must still build for every caller written before the switch existed.
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
# A required secret is refused at call time, which would have made the lint
# unreachable for exactly the callers `build-python-package: false` is for.
t_assert_eq "True" "$(_q "'GHCR_PAT' in secrets")"
t_assert_eq "false" "$(_q "V.value(V.value(secrets,'GHCR_PAT'),'required')")"

t_case "the build job asserts the token it does need, and names the way out"
# Optional at the lane boundary must not mean silent in the job that needs it:
# without this the empty secret surfaces as a ghcr `docker login` failure.
t_assert_eq "True" "$(_raw_has 'if (-not $env:GHCR_PAT) {')"
t_assert_eq "True" "$(_raw_has 'build-python-package: false to take the PowerShell lint alone')"

t_case "a missing submodule fails with a message that names the fix"
# `pwsh -File <absent>` reports its own error about a path, which reads as a
# broken lane rather than an un-checked-out submodule.
t_assert_eq "True" "$(_raw_has 'Test-Path -LiteralPath $gate')"

t_summary
