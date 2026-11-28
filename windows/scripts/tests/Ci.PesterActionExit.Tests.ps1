#requires -Version 7.0
# The action's script against stubbed Pester of both dialects; real Pester, the install and GitHub's shell flags are out of scope.

$script:actionDir = Join-Path (Get-RepoRoot) '.github/actions/run-pester-suite'
$script:suiteScript = Join-Path $script:actionDir 'Invoke-PesterSuite.ps1'

# Invoke-ActionSuite: runs the script in a child pwsh whose Invoke-Pester returns $Result; legacy or modern by $Version.
function Invoke-ActionSuite {
    param([Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Result)
    $prelude = @(
        'function Import-Module { param($Name, $RequiredVersion, $ErrorAction) }'
        'function Install-PinnedPowerShellModule { param($Name, $Version, [switch]$SkipPublisherCheck) }'
        'function New-PesterConfiguration { [pscustomobject]@{ Run = [pscustomobject]@{ Path = $null; PassThru = $null; Exit = $null }; Output = [pscustomobject]@{ Verbosity = $null } } }'
        'function Invoke-Pester { param($Path, [switch]$PassThru, [switch]$Quiet, $Configuration)'
        '    if ($Configuration) { Write-Host "MODERN path=$($Configuration.Run.Path) exit=$($Configuration.Run.Exit) passthru=$($Configuration.Run.PassThru) verbosity=$($Configuration.Output.Verbosity)" } else { Write-Host "LEGACY path=$Path quiet=$Quiet" }'
        '    $global:LASTEXITCODE = 1'
        "    $Result }"
    ) -join "`n"
    $call = "& $(ConvertTo-TestPwshLiteral -Value $script:suiteScript) -Path 'fixture.Tests.ps1' -Version '$Version'; exit `$LASTEXITCODE"
    return Invoke-TestPwshProbe -Source ($prelude + "`n" + $call)
}

# Assert-ActionCase: the script's exit code, and the lines its output must and must not hold, for one stubbed result.
function Assert-ActionCase {
    param([Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Result, [int]$Exit, [string[]]$Pattern = @(), [string[]]$Absent = @())
    $probe = Invoke-ActionSuite -Version $Version -Result $Result
    Assert-Equal $Exit $probe.ExitCode $probe.Output
    foreach ($line in $Pattern) { Assert-Match $line $probe.Output }
    foreach ($line in $Absent) { Assert-False ($probe.Output -match $line) $probe.Output }
}

function New-LegacyResult {
    param([int]$Total, [int]$Passed, [int]$Failed = 0, [string]$Items = '')
    return "[pscustomobject]@{ TotalCount = $Total; PassedCount = $Passed; FailedCount = $Failed; TestResult = @($Items) }"
}

function New-ModernResult {
    param([int]$Total, [int]$Passed, [int]$Failed = 0, [int]$BrokenFiles = 0, [string]$Items = '', [string]$Files = '')
    return "[pscustomobject]@{ TotalCount = $Total; PassedCount = $Passed; FailedCount = $Failed; FailedContainersCount = $BrokenFiles; Failed = @($Items); Containers = @($Files) }"
}

$script:legacyFailure = '[pscustomobject]@{ Passed = $false; Describe = "d"; Name = "wrong"; FailureMessage = "Expected: {2}"; StackTrace = "at line: 1" }'
$script:modernFailure = '[pscustomobject]@{ ExpandedPath = "d.wrong"; ErrorRecord = @([pscustomobject]@{ Exception = [pscustomobject]@{ Message = "Expected 2, but got 1." }; ScriptStackTrace = "at line 3" }) }'
$script:brokenFile = '[pscustomobject]@{ Result = "Failed"; Item = "broken.Tests.ps1"; ErrorRecord = @([pscustomobject]@{ Exception = [pscustomobject]@{ Message = "top level broke" }; ScriptStackTrace = "at broken.Tests.ps1: line 1" }) }'

# One row per case: the dialect group, the stubbed version and result, the exit code, and what the output must and must not hold.
$script:ActionCases = @(
    @{ Group = 'Pester 3 and 4'; It = 'ignores an exit code a passing suite leaked from its own native calls'; Version = '3.4.0'
        Result = (New-LegacyResult 2 2); Exit = 0; Pattern = @('LEGACY path=fixture.Tests.ps1 quiet=True', 'TOTAL=2 PASSED=2 FAILED=0') }
    @{ Group = 'Pester 3 and 4'; It = 'fails a failed test and names it with its message and stack'; Version = '4.10.1'
        Result = (New-LegacyResult 2 1 1 $script:legacyFailure); Exit = 1; Pattern = @('FAIL: d / wrong', 'Expected: \{2\}', 'at line: 1') }
    @{ Group = 'Pester 3 and 4'; It = 'fails a path that matched no test'; Version = '3.4.0'
        Result = (New-LegacyResult 0 0); Exit = 1; Pattern = @('matched no Pester test') }
    @{ Group = 'Pester 5 and later'; It = 'runs through a configuration that keeps Pester from ending the process'; Version = '6.2.0'
        Result = (New-ModernResult 3 3); Exit = 0; Pattern = @('MODERN path=fixture.Tests.ps1 exit=False passthru=True verbosity=Normal', 'TOTAL=3 PASSED=3 FAILED=0 FAILED_CONTAINERS=0') }
    @{ Group = 'Pester 5 and later'; It = 'takes 5.0.0 as the first modern version'; Version = '5.0.0'
        Result = (New-ModernResult 1 1); Exit = 0; Pattern = @('MODERN path=') }
    @{ Group = 'Pester 5 and later'; It = 'fails a failed test and prints its path, message and stack'; Version = '6.2.0'
        Result = (New-ModernResult 2 1 1 -Items $script:modernFailure); Exit = 1; Pattern = @('FAIL: d\.wrong', 'Expected 2, but got 1\.', 'at line 3') }
    @{ Group = 'Pester 5 and later'; It = 'fails a file that broke before any test ran, and says why instead of reporting no test'; Version = '6.2.0'
        Result = (New-ModernResult 0 0 -BrokenFiles 1 -Files $script:brokenFile); Exit = 1; Pattern = @('FAIL: container broken\.Tests\.ps1', 'top level broke'); Absent = @('matched no Pester test') }
    @{ Group = 'Pester 5 and later'; It = 'fails a path that matched no test'; Version = '6.2.0'
        Result = (New-ModernResult 0 0); Exit = 1; Pattern = @('matched no Pester test') }
    @{ Group = 'Pester 5 and later'; It = 'fails a run whose tests were all skipped'; Version = '6.2.0'
        Result = (New-ModernResult 1 0); Exit = 1; Pattern = @('had no passing test') }
)

foreach ($group in @($script:ActionCases | ForEach-Object { $_.Group } | Select-Object -Unique)) {
    Describe "Reusable Pester action: $group" {
        foreach ($case in @($script:ActionCases | Where-Object { $_.Group -eq $group })) {
            It $case.It {
                # Invoke-Tests runs under StrictMode Latest, where a row without Absent has no such property.
                Assert-ActionCase -Version $case.Version -Result $case.Result -Exit $case.Exit -Pattern $case.Pattern -Absent @($case['Absent'] | Where-Object { $_ })
            }
        }
    }
}

Describe 'Reusable Pester action wiring' {
    It 'hands the inputs to the script through the environment, never into the script text' {
        $yaml = Get-Content -Raw -LiteralPath (Join-Path $script:actionDir 'action.yml')
        $run = [regex]::Match($yaml, '(?ms)^      run: \|\r?\n(.*?)(?=^\S|\z)').Groups[1].Value
        Assert-Match 'Invoke-PesterSuite\.ps1.*-Path \$env:PESTER_SUITE_PATH -Version \$env:PESTER_SUITE_VERSION' $run
        Assert-False ($run -match '\$\{\{') $run
        Assert-Match 'PESTER_SUITE_PATH: \$\{\{ inputs\.path \}\}' $yaml
    }
}
