#requires -Version 7.0
# The portable verdict fixtures do not execute GitHub Actions; native Pester 3.4 cases run on Windows.

$script:PesterActionDir = Join-Path (Get-RepoRoot) '.github/actions/run-pester-suite'

function Get-PesterActionSource {
    $lines = [IO.File]::ReadAllLines((Join-Path $script:PesterActionDir 'action.yml'))
    $start = [Array]::IndexOf($lines, '      run: |')
    if ($start -lt 0) { throw 'Pester action has no run block' }
    $body = [Collections.Generic.List[string]]::new()
    for ($i = $start + 1; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if ($line.StartsWith('        ')) { $body.Add($line.Substring(8)); continue }
        if ([string]::IsNullOrWhiteSpace($line)) { $body.Add(''); continue }
        break
    }
    $source = $body -join "`n"
    if (-not $source.Contains('Invoke-Pester')) { throw 'Pester action run block is incomplete' }
    $source = $source.Replace('${{ inputs.version }}', '3.4.0')
    return $source.Replace('''${{ inputs.path }}''', '$env:PESTER_ACTION_FIXTURE_SUITE')
}

function Invoke-PesterActionFixture {
    param([string]$Suite, [string]$Prelude = '', [switch]$RemovePassedGuard)
    $source = Get-PesterActionSource
    if ($RemovePassedGuard) {
        $source = Update-TestLiteralText -Text $source -Find 'if ($r.PassedCount -lt 1) {' `
            -Replace 'if ($false) {' -ErrorLabel 'Pester action fixture'
    }
    $actionDir = ConvertTo-TestPwshLiteral -Value $script:PesterActionDir
    $suitePath = ConvertTo-TestPwshLiteral -Value $Suite
    $command = @"
`$ErrorActionPreference = 'Stop'
`$env:GITHUB_ACTION_PATH = $actionDir
`$env:PESTER_ACTION_FIXTURE_SUITE = $suitePath
$Prelude
$source
exit 0
"@
    Invoke-TestPwshProbe -Source $command
}

function New-PesterResultPrelude {
    param([int]$Total, [int]$Passed, [int]$Failed)
    return @"
function Import-Module { param(`$Name, `$RequiredVersion, `$ErrorAction) }
function Install-PinnedPowerShellModule { param(`$Name, `$Version, [switch]`$SkipPublisherCheck) }
function Invoke-Pester {
    param(`$Path, [switch]`$PassThru, [switch]`$Quiet)
    [pscustomobject]@{ TotalCount = $Total; PassedCount = $Passed; FailedCount = $Failed; TestResult = @(
        [pscustomobject]@{ Passed = `$false; Describe = 'fixture'; Name = 'failure'; FailureMessage = 'planted assertion'; StackTrace = 'fixture stack' }
    ) }
}
"@
}

function Assert-PesterActionResult {
    param([int]$Total, [int]$Passed, [int]$Failed, [int]$Expected, [string]$Pattern = '')
    $result = Invoke-PesterActionFixture -Suite 'fixture.Tests.ps1' -Prelude (New-PesterResultPrelude $Total $Passed $Failed)
    Assert-Equal $Expected $result.ExitCode $result.Output
    if ($Pattern) { Assert-Match $Pattern $result.Output }
}

Describe 'Reusable Pester action verdict' {
    It 'preserves quoted paths in child PowerShell' {
        $literal = ConvertTo-TestPwshLiteral -Value "a'b"
        $probe = Invoke-TestPwshProbe -Source "Write-Output $literal"
        Assert-Equal 0 $probe.ExitCode $probe.Output
        Assert-Equal "a'b" $probe.Output
    }

    It 'requires mutation anchors and permits an empty replacement' {
        Assert-Equal 'ac' (Update-TestLiteralText -Text 'abc' -Find 'b' -Replace '')
        Assert-Throws { Update-TestLiteralText -Text 'abc' -Find 'missing' -Replace '' } -MessagePattern 'find text is gone: missing'
    }

    It 'accepts a passing suite with optional skipped tests' {
        Assert-PesterActionResult -Total 3 -Passed 1 -Failed 0 -Expected 0 -Pattern 'TOTAL=3 PASSED=1 FAILED=0'
    }

    It 'rejects an empty suite and a failed assertion' {
        Assert-PesterActionResult -Total 0 -Passed 0 -Failed 0 -Expected 1 -Pattern 'matched no Pester test'
        Assert-PesterActionResult -Total 2 -Passed 1 -Failed 1 -Expected 1 -Pattern 'planted assertion'
    }

    It 'rejects a suite in which no test passed' {
        Assert-PesterActionResult -Total 3 -Passed 0 -Failed 0 -Expected 1 -Pattern 'no passing test'
    }

    It 'detects removing the no-passing-test guard (mutation)' {
        $prelude = New-PesterResultPrelude -Total 3 -Passed 0 -Failed 0
        $result = Invoke-PesterActionFixture -Suite 'fixture.Tests.ps1' -Prelude $prelude -RemovePassedGuard
        Assert-Equal 0 $result.ExitCode $result.Output
    }

    if ($IsWindows) {
        It 'runs genuine Pester 3.4 pass, skip, pending, failure and empty suites' {
            Invoke-InTestDir { param($dir)
                foreach ($case in @(
                        @{ Name = 'pass'; Body = "It 'pass' { 1 | Should Be 1 }"; Exit = 0; Pattern = 'PASSED=1' }
                        @{ Name = 'mixed'; Body = "It 'pass' { 1 | Should Be 1 }; It 'skip' -Skip { throw 'not run' }"; Exit = 0; Pattern = 'PASSED=1' }
                        @{ Name = 'skip'; Body = "It 'skip' -Skip { throw 'not run' }"; Exit = 1; Pattern = 'no passing test' }
                        @{ Name = 'pending'; Body = "It 'pending' -Pending {}"; Exit = 1; Pattern = 'no passing test' }
                        @{ Name = 'failure'; Body = "It 'fail' { 1 | Should Be 2 }"; Exit = 1; Pattern = 'FAIL:' }
                        @{ Name = 'empty'; Body = ''; Exit = 1; Pattern = 'matched no Pester test' }
                    )) {
                    $file = Join-Path $dir "$($case.Name).Tests.ps1"
                    [IO.File]::WriteAllText($file, "Describe 'fixture' { $($case.Body) }`n")
                    $result = Invoke-PesterActionFixture -Suite $file
                    Assert-Equal $case.Exit $result.ExitCode "$($case.Name): $($result.Output)"
                    Assert-Match $case.Pattern $result.Output
                }
            }
        }
    }
}
