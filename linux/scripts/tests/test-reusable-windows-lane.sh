#!/usr/bin/env bash
# Local workflow queries cover lane contracts, not Windows job execution; see docs/python-ci.md#turning-the-windows-powershell-lint-on
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/workflow-lane-fixture.sh
source "${TESTS_DIR}/workflow-lane-fixture.sh"
workflow_lane_fixture_init .github/workflows/python-ci-windows.yml build-test-python-package-on-windows lint-powershell python3 || exit 1

t_case "the lane file is where preflight and every consumer expect it"
t_assert_ok test -f "${LANE}"

t_case "the optional build job requires an artifact when it runs, including after failure"
upload_step="next(s for s in V.value(build,'steps') if V.value(s,'name') == 'Upload files, logs & Zip')"
t_assert_contains "$(_q "V.value(${upload_step},'if')")" 'always()'
t_assert_contains "$(_q "V.value(V.value(${upload_step},'with'),'path')")" 'inputs.artifact-paths'
upload_findings="[r[2] for r in V.check_artifact_error('', lane) if r[2] == 'Upload files, logs & Zip']"
_artifact_gate() {
  if [ "$(LANE="$1" _q "${upload_findings}")" = '[]' ]; then
    return 0
  fi
  return 1
}
t_assert_ok _artifact_gate "${LANE}"
mkdir -p "${ROOT}/logs/test-results"
faulted="$(mktemp "${ROOT}/logs/test-results/windows-upload.XXXXXXXX")"
trap 'rm -f -- "${faulted}"' EXIT
sed 's/if-no-files-found: error/if-no-files-found: warn/g' "${LANE}" > "${faulted}"
t_assert_fails _artifact_gate "${faulted}"
t_assert_contains "$(LANE="${faulted}" _q "${upload_findings}")" 'Upload files, logs & Zip'

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

t_case "complexity-strict defaults off while existing consumer scripts are refactored"
workflow_assert_input_fields complexity-strict type 'boolean' default 'false' required 'false'

t_case "the lint job exists and is gated on the input"
t_assert_eq "True" "$(_q "job is not None")"
t_assert_contains "$(_q "V.value(job,'if')")" "inputs.lint-powershell" \
  "without the gate every existing caller would suddenly run a Windows lint job"

t_case "the lint job does NOT wait for the build job"
# Chained behind the build, the lint would hide behind the very failure it explains.
t_assert_eq "None" "$(_q "V.value(job,'needs')")"

t_case "the optional Python job delegates to the shared PowerShell quality workflow"
t_assert_eq "./.github/workflows/powershell-quality.yml" "$(_q "V.value(job,'uses')")"
t_assert_contains "$(_q "V.value(V.value(job,'with'),'runs-on')")" 'inputs.runs-on'
t_assert_contains "$(_q "V.value(V.value(job,'with'),'lint-path')")" 'inputs.lint-path'
t_assert_contains "$(_q "V.value(V.value(job,'with'),'strict')")" 'inputs.complexity-strict'

workflow_lane_fixture_init .github/workflows/powershell-quality.yml lint-powershell lint-powershell python3 || exit 1
t_case "the standalone lane serves PowerShell-only consumers and pins its runner"
workflow_assert_input_fields lint-path type 'string' default 'scripts'
workflow_assert_input_fields strict type 'boolean' default 'false'
workflow_assert_input_fields analyzer-strict type 'boolean' default 'true'
workflow_assert_input_fields hub-checkout type 'boolean' default 'false'
t_assert_contains "$(_q "V.value(job,'runs-on')")" 'inputs.runs-on'
t_assert_eq "False" "$(_q "'windows-latest' in str(V.value(job,'runs-on'))")"
t_assert_eq "True" "$(_q "any(str(V.value(V.value(s,'with'),'submodules')) == 'true' for s in steps if V.value(s,'uses'))")"
t_assert_eq "True" "$(_q "all('@' in str(V.value(s,'uses')) and len(str(V.value(s,'uses')).split('@')[1]) == 40 for s in steps if V.value(s,'uses'))")"
t_assert_eq "True" "$(_q "any(V.value(s,'name') == 'Get ANTfrastructure tooling' and 'inputs.hub-checkout' in str(V.value(s,'if')) for s in steps)")"

t_case "the standalone lane pins PSScriptAnalyzer and grades the caller path"
t_assert_eq "True" "$(_q "'PSSCRIPTANALYZER_VERSION' in run_blocks('lint-powershell')")"
t_assert_eq "True" "$(_q "'-RequiredVersion \$pin' in run_blocks('lint-powershell')")"
t_assert_eq "True" "$(_raw_has "\$gate = Join-Path \$hub 'windows/scripts/Invoke-Lint.ps1'")"
t_assert_eq "True" "$(_raw_has 'if ($env:LINT_ANALYZER_STRICT -eq '\''true'\'') { $lintArgs += '\''-FailOnAnalyzer'\'' }')"
t_assert_eq "True" "$(_raw_has 'pwsh @lintArgs')"
t_assert_eq "True" "$(_raw_has 'if ($LASTEXITCODE -ne 0) { throw')"
t_assert_eq "True" "$(_raw_has 'if (-not (Test-Path -LiteralPath $gate -PathType Leaf))')"

t_case "the standalone lane reports complexity and gates only when strict is selected"
t_assert_eq "True" "$(_q "len([s for s in steps if V.value(s,'name') == 'Report PowerShell complexity' and V.value(s,'if') is None]) == 1")"
t_assert_eq "True" "$(_raw_has "\$gate = Join-Path \$hub 'windows/scripts/Invoke-CodeComplexity.ps1'")"
t_assert_eq "True" "$(_raw_has "\$strict = \$env:LINT_STRICT -eq 'true'")"
t_assert_eq "True" "$(_raw_has "& \$gate -Path \$env:LINT_PATH -Root \$env:GITHUB_WORKSPACE -Strict:\$strict -JsonPath 'logs/code-quality/complexity/windows-consumer.json'")"
workflow_assert_artifact_step 'Save PowerShell complexity report' 'logs/code-quality/complexity/windows-consumer.json'

workflow_lane_fixture_init .github/workflows/python-ci-windows.yml build-test-python-package-on-windows lint-powershell python3 || exit 1

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
