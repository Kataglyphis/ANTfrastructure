#requires -Version 7.0
# This exercises real Pester suite verdicts, not coverage instrumentation.

. (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/tests/Runner.Parallel.Tests.ps1' -FunctionName New-RunnerCopy)
. (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/tests/Runner.Parallel.Tests.ps1' -FunctionName Update-RunnerCopy)

$script:SkippedPesterFixture = @(
    "Describe 'skipped' {"
    '    BeforeAll { }'
    '    It ''skips'' -Skip { throw ''not executed'' }'
    '}'
) -join "`n"

function New-PesterOutcomeRunner {
    param([string]$Dir, [string]$Candidate)
    $tests = New-RunnerCopy -Dir $Dir -Suites @{
        'A.Tests.ps1' = $Candidate
        'B.Tests.ps1' = "Describe 'other' {`n BeforeAll { }`n It 'passes' { `$true | Should -BeTrue }`n}"
    }
    $runner = Join-Path $tests 'Invoke-Tests.ps1'
    $source = [IO.File]::ReadAllText($runner)
    foreach ($change in @(
            @{ Find = '$minTests = 2702'; Replace = '$minTests = 1' }
            @{ Find = ' -SummaryFile $SummaryFile -RequireCoverageTargets)'; Replace = ' -SummaryFile $SummaryFile)' }
            @{ Find = ' -SummaryFile $SummaryFile -RequireCoverageTargets:(-not [bool]$Only))'; Replace = ' -SummaryFile $SummaryFile)' }
        )) {
        $source = Update-TestLiteralText -Text $source -Find $change.Find -Replace $change.Replace -ErrorLabel 'Pester runner fixture'
    }
    [IO.File]::WriteAllText($runner, $source)
    return $tests
}

function Invoke-PesterOutcomeRunner {
    param([string]$Tests, [int]$Jobs, [string]$Only = '')
    $summary = Join-Path (Split-Path $Tests) "logs/windows-tests/outcome-$Jobs.json"
    $arguments = @('-Jobs', "$Jobs", '-SummaryFile', $summary)
    if ($Only) { $arguments += @('-Only', $Only) }
    $output = @(& pwsh -NoProfile -NonInteractive -File (Join-Path $Tests 'Invoke-Tests.ps1') @arguments 2>&1 | ForEach-Object { "$_" })
    $exit = $LASTEXITCODE
    if (-not (Test-Path -LiteralPath $summary -PathType Leaf)) { throw "runner wrote no summary: $($output -join ' | ')" }
    return [pscustomobject]@{ Exit = $exit; Summary = (Get-Content -LiteralPath $summary -Raw | ConvertFrom-Json);
        Text = ($output -join "`n") }
}

function Assert-PesterOutcomeFailure {
    param($Result, [int]$ExpectedPassed)
    Assert-Equal 1 $Result.Exit $Result.Text
    Assert-Equal $ExpectedPassed $Result.Summary.Passed
    Assert-True ($Result.Summary.PesterFailures -gt 0) $Result.Text
    Assert-Match 'no tests passed' $Result.Text
}

function Assert-PesterNoPassingFixture {
    param([string]$Fixture, [switch]$CheckSelected)
    Invoke-InTestDir { param($dir)
        $tests = New-PesterOutcomeRunner -Dir $dir -Candidate $Fixture
        foreach ($jobs in 1, 2) {
            Assert-PesterOutcomeFailure -Result (Invoke-PesterOutcomeRunner -Tests $tests -Jobs $jobs) -ExpectedPassed 1
        }
        if ($CheckSelected) {
            $selected = Invoke-PesterOutcomeRunner -Tests $tests -Jobs 1 -Only 'A.Tests.ps1'
            Assert-PesterOutcomeFailure -Result $selected -ExpectedPassed 0
        }
    }.GetNewClosure()
}

Describe 'Invoke-Tests Pester suite verdicts' {
    It 'accepts a passing suite even when another test in it is skipped' {
        Invoke-InTestDir { param($dir)
            $fixture = @("Describe 'partial' {", '    BeforeAll { }',
                '    It ''passes'' { $true | Should -BeTrue }', '    It ''skips'' -Skip { throw ''not executed'' }', '}') -join "`n"
            $tests = New-PesterOutcomeRunner -Dir $dir -Candidate $fixture
            foreach ($jobs in 1, 2) {
                $result = Invoke-PesterOutcomeRunner -Tests $tests -Jobs $jobs
                Assert-Equal 0 $result.Exit $result.Text
                Assert-Equal 2 $result.Summary.Passed
            }
            $selected = Invoke-PesterOutcomeRunner -Tests $tests -Jobs 1 -Only 'A.Tests.ps1'
            Assert-Equal 0 $selected.Exit $selected.Text
            Assert-Equal 1 $selected.Summary.Passed
        }
    }

    It 'fails an entirely skipped suite even when another suite passes' {
        Assert-PesterNoPassingFixture -Fixture $script:SkippedPesterFixture -CheckSelected
    }

    It 'fails a discovered Pester suite with no tests' {
        $fixture = @("Describe 'empty' {", '    BeforeAll { }', '}') -join "`n"
        Assert-PesterNoPassingFixture -Fixture $fixture
    }

    It 'rejects a runner that stops counting a suite with no passing tests (mutation)' {
        Invoke-InTestDir { param($dir)
            $tests = New-PesterOutcomeRunner -Dir $dir -Candidate $script:SkippedPesterFixture
            $control = Invoke-PesterOutcomeRunner -Tests $tests -Jobs 2
            Assert-Equal 1 $control.Exit $control.Text
            $anchor = 'if ([int]$run.FailedCount -eq 0) { $failures += 1 }'
            Update-RunnerCopy -Tests $tests -Find $anchor `
                -Replace 'if ([int]$run.FailedCount -eq 0) { $failures += 0 }' -ErrorLabel 'Pester runner mutant'
            $mutant = Invoke-PesterOutcomeRunner -Tests $tests -Jobs 2
            Assert-Throws { Assert-Equal 1 $mutant.Exit } -MessagePattern 'expected \[1\] but got \[0\]'
        }
    }
}
