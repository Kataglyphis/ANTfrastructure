#!/usr/bin/env bash
# Local workflow queries cover lane contracts, not Windows job execution; see docs/python-ci.md#turning-the-windows-powershell-lint-on
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/workflow-lane-fixture.sh
source "${TESTS_DIR}/workflow-lane-fixture.sh"
workflow_lane_fixture_init .github/workflows/python-ci-windows.yml build-test-python-package-on-windows lint-powershell python3 || exit 1

t_case "the lane file is where preflight and every consumer expect it"
t_assert_ok test -f "${LANE}"

# Needles are whole command fragments, never bare flags, which the lane's comments also name.
_raw_has() { grep -qF -- "$1" "${LANE}" && echo True || echo False; }

t_case "the two inputs exist, so a consumer configures instead of copying a job"
t_assert_eq "True" "$(_q "'lint-powershell' in inputs")"
t_assert_eq "True" "$(_q "'lint-path' in inputs")"

t_case "lint-powershell is a boolean that DEFAULTS OFF"
# Every caller that predates the input must be byte-for-byte unaffected.
workflow_assert_input_fields lint-powershell type 'boolean' default 'false' required 'false'

t_case "lint-path is a string defaulting to the family layout's scripts tree"
workflow_assert_input_fields lint-path type 'string' default 'scripts'

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
t_assert_eq "True" "$(_q "'PSSCRIPTANALYZER_VERSION' in run_blocks('lint-powershell')")"
t_assert_eq "True" "$(_q "'-RequiredVersion \$pin' in run_blocks('lint-powershell')")"
t_assert_eq "False" "$(_q "'Install-Module PSScriptAnalyzer -Force' in run_blocks('lint-powershell')")"

t_case "the gate is the HUB's script, pointed at the CALLER's tree"
t_assert_eq "True" "$(_raw_has '$gate = '"'"'third_party/ANTfrastructure/windows/scripts/Invoke-Lint.ps1'"'"'')"

t_case "the gate is invoked with -Path <lint-path> AND -FailOnAnalyzer"
# Without -FailOnAnalyzer, analyzer findings print and the script still exits 0.
t_assert_eq "True" "$(_raw_has "pwsh -NoProfile -File \$gate -Path '\${{ inputs.lint-path }}' -FailOnAnalyzer")"

# Build half: a caller without a Python package must be able to take the lint alone
t_case "build-python-package is a boolean that DEFAULTS ON"
# Callers written before the switch existed must still build.
t_assert_eq "True" "$(_q "'build-python-package' in inputs")"
workflow_assert_input_fields build-python-package type 'boolean' default 'true' required 'false'

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

t_case "arm64-tests is a boolean that DEFAULTS OFF, and both arm64 jobs are gated on it"
# Defaulting on would hand every existing caller a windows-11-arm job its lock was never checked for.
workflow_assert_input_fields arm64-tests type 'boolean' default 'false'
for arm64_job in stage-python-for-windows-arm64 test-python-on-windows-arm64; do
  t_assert_contains "$(_q "V.value(V.value(jobs,'${arm64_job}'),'if')")" "inputs.arm64-tests" \
    "an ungated job runs on every caller"
done
t_assert_eq "windows-11-arm" "$(_q "V.value(V.value(jobs,'test-python-on-windows-arm64'),'runs-on')")"
t_assert_eq "stage-python-for-windows-arm64" "$(_q "V.value(V.value(jobs,'test-python-on-windows-arm64'),'needs')")"

t_case "the stage runs in :winarm64 and hands its inputs over as container env, never interpolated into a script"
stage_steps="V.value(V.value(jobs,'stage-python-for-windows-arm64'),'steps')"
t_assert_eq "True" "$(_q "'GetEnvironmentVariable' in run_blocks('stage-python-for-windows-arm64')")"
t_assert_eq "False" "$(_q "'\${{' in run_blocks('stage-python-for-windows-arm64')")"
t_assert_eq "True" "$(_q "all(str(V.value(V.value(s,'with'),'target-arch')) == 'arm64' for s in ${stage_steps} if 'windows-container' in str(V.value(s,'uses')))")"
t_assert_eq "True" "$(_raw_has 'file: C:\ws\third_party\ANTfrastructure\windows\scripts\python\New-Arm64PythonTestStage.ps1')"
t_assert_eq "True" "$(_raw_has "foreach (\$name in 'PY_VERSIONS', 'PY_EXTRAS', 'FT_EXTRAS', 'TEST_PATHS', 'TEST_FILES', 'TEST_ENV') { '--env';")"

t_case "the device job installs nothing: no checkout, no uv, no download but the stage"
device_steps="V.value(V.value(jobs,'test-python-on-windows-arm64'),'steps')"
t_assert_eq "False" "$(_q "any('checkout' in str(V.value(s,'uses')) for s in ${device_steps})")"
t_assert_eq "True" "$(_q "'Invoke-StagedTests.ps1' in run_blocks('test-python-on-windows-arm64')")"
t_assert_eq "False" "$(_q "any(w in run_blocks('test-python-on-windows-arm64') for w in ('uv ', 'pip ', 'Invoke-WebRequest', 'python install'))")"
t_assert_eq "True" "$(_raw_has 'name: python-windows-arm64-stage')"
t_assert_eq "True" "$(_raw_has "if (\$failed -gt 0) { throw \"\$failed arm64 test(s) or wheel proof(s) failed\" }")"

t_case "build-script defaults to empty: the repo's own Build-Windows.ps1 first, else the hub driver"
# A caller that relies on the default keeps running its own script until it deletes it.
workflow_assert_input_fields build-script default ''
t_assert_eq "True" "$(_raw_has "if (-not \$file -and (Test-Path -LiteralPath 'scripts/windows/Build-Windows.ps1' -PathType Leaf)) {")"
t_assert_eq "True" "$(_raw_has 'third_party/ANTfrastructure/windows/scripts/python/Invoke-PythonCiBuild.ps1')"
t_assert_eq "True" "$(_raw_has 'file: ${{ steps.build-script.outputs.file }}')"
t_assert_eq "False" "$(_q "'\${{' in str(V.value([s for s in V.value(build,'steps') if V.value(s,'id') == 'build-script'][0],'run'))")"

t_summary
