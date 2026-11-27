#requires -Version 7.0
# Genuine Pester runs of the action's script: the versions.env pin everywhere Invoke-Tests runs, 3.4.0 only on Windows.

$script:PesterActionScript = Join-Path (Get-RepoRoot) '.github/actions/run-pester-suite/Invoke-PesterSuite.ps1'

function Invoke-PesterActionFixture {
    param([Parameter(Mandatory)][string]$Suite, [Parameter(Mandatory)][string]$Version)
    $script = ConvertTo-TestPwshLiteral -Value $script:PesterActionScript
    $suitePath = ConvertTo-TestPwshLiteral -Value $Suite
    Invoke-TestPwshProbe -Source "& $script -Path $suitePath -Version '$Version'; exit `$LASTEXITCODE"
}

# Each case is a whole suite file, or $null for an empty directory; its exit code and one output line are asserted.
function Assert-PesterActionCases {
    param([Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][object[]]$Cases)
    Invoke-InTestDir -FixtureArgumentList @($Version, $Cases) {
        param($dir, $version, $cases)
        foreach ($case in $cases) {
            $target = Join-Path $dir $case.Name
            $null = New-Item -ItemType Directory -Path $target
            if ($case.Body) { [IO.File]::WriteAllText((Join-Path $target "$($case.Name).Tests.ps1"), $case.Body + "`n") }
            $result = Invoke-PesterActionFixture -Suite $target -Version $version
            Assert-Equal $case.Exit $result.ExitCode "$version $($case.Name): $($result.Output)"
            Assert-Match $case.Pattern $result.Output
        }
    }
}

# One row per case: the dialects it runs in, its suite with SHOULD for the dialect's equality assertion, the exit code and an output line.
$script:ActionCases = @(
    @{ Name = 'pass'; In = 'modern', 'legacy'; Body = "Describe 'fixture' { It 'pass' { 1 | SHOULD 1 } }"; Exit = 0; Pattern = 'PASSED=1' }
    @{ Name = 'mixed'; In = 'modern', 'legacy'; Body = "Describe 'fixture' { It 'pass' { 1 | SHOULD 1 }; It 'skip' -Skip { throw 'not run' } }"; Exit = 0; Pattern = 'PASSED=1' }
    @{ Name = 'skip'; In = 'modern', 'legacy'; Body = "Describe 'fixture' { It 'skip' -Skip { throw 'not run' } }"; Exit = 1; Pattern = 'no passing test' }
    @{ Name = 'failure'; In = 'modern', 'legacy'; Body = "Describe 'fixture' { It 'fail' { 1 | SHOULD 2 } }"; Exit = 1; Pattern = 'FAIL: fixture(\.| / )fail' }
    @{ Name = 'empty'; In = 'modern', 'legacy'; Body = $null; Exit = 1; Pattern = 'matched no Pester test' }
    @{ Name = 'pending'; In = 'legacy'; Body = "Describe 'fixture' { It 'pending' -Pending {} }"; Exit = 1; Pattern = 'no passing test' }
    @{ Name = 'setup-pass'; In = 'modern'; Body = "Describe 'fixture' { BeforeAll { `$x = 1 }; It 'pass' { `$x | SHOULD 1 } }"; Exit = 0; Pattern = 'PASSED=1' }
    @{ Name = 'setup'; In = 'modern'; Body = "Describe 'fixture' { BeforeAll { throw 'setup broke' }; It 'a' { 1 | SHOULD 1 } }"; Exit = 1; Pattern = 'setup broke' }
    @{ Name = 'discovery'; In = 'modern'; Body = "throw 'discovery broke'`nDescribe 'fixture' { It 'a' { 1 | SHOULD 1 } }"; Exit = 1; Pattern = '(?s)FAIL: container .*discovery broke' }
    @{ Name = 'other-dialect'; In = 'modern'; Body = "Describe 'fixture' { It 'old' { 1 | Should Be 1 } }"; Exit = 1; Pattern = 'FAIL: fixture\.old' }
)

# Get-DialectCases: the rows that run in one dialect, their bodies written with its equality assertion.
function Get-DialectCases {
    param([Parameter(Mandatory)][string]$Dialect, [Parameter(Mandatory)][string]$Should)
    return @($script:ActionCases | Where-Object { $_.In -contains $Dialect } | ForEach-Object {
            $row = $_.Clone()
            if ($row.Body) { $row.Body = $row.Body.Replace('SHOULD', $Should) }
            $row
        })
}

Describe 'Reusable Pester action on genuine Pester' {
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

    It 'runs each case through the action at the pinned Pester and, on Windows, at 3.4.0' {
        $pin = [regex]::Match((Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'linux/scripts/01-core/versions.env')), '(?m)^PESTER_VERSION=(\S+)').Groups[1].Value
        Assert-Match '^[5-9]\.' $pin 'the pin is a Pester 5-or-later version'
        $dialects = @(@{ Name = 'modern'; Version = $pin; Should = 'Should -Be' })
        # Pester 3.4.0 is a Windows PowerShell-era module that only the Windows hosts carry.
        if ($IsWindows) { $dialects += @{ Name = 'legacy'; Version = '3.4.0'; Should = 'Should Be' } }
        foreach ($dialect in $dialects) {
            Assert-PesterActionCases -Version $dialect.Version -Cases (Get-DialectCases -Dialect $dialect.Name -Should $dialect.Should)
        }
    }
}
