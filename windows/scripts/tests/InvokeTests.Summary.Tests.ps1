#requires -Version 7.0
# The writer fixture does not launch parallel children or exercise Pester discovery.

function Invoke-SummaryWriterFixture {
    param([Parameter(Mandatory)][scriptblock]$Body)
    Invoke-InTestDir { param($dir)
        Set-Variable -Name here -Value (Join-Path $dir 'windows\scripts\tests')
        Set-Variable -Name minTests -Value 3
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/tests/Invoke-Tests.ps1' `
            -FunctionName Get-CoverageTargets, New-TestTally, Get-CoverageInventoryFailures, Get-TestExitCode,
                Write-CoverageDetails, Write-TestFailure, Write-TallyDetails, Write-TestSummary)
        $baseline = New-TestTally -Total 3 -Passed 3 -PesterFailures 0
        & $Body $dir $baseline
    }
}

function Assert-CoverageInventoryFailure {
    param([Parameter(Mandatory)][Collections.IDictionary]$Tally, [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Pattern)
    Assert-Equal 1 (Write-TestSummary -Tally $Tally -SummaryFile $Path -RequireCoverageTargets 6>$null)
    $saved = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    Assert-Match $Pattern ($saved.CoverageFailures -join '|')
}

Describe 'Invoke-Tests run summary' {
    It 'persists the parent verdict under logs and honors an explicit summary path' {
        Invoke-SummaryWriterFixture { param($dir, $baseline)
            Assert-Equal 0 (Write-TestSummary -Tally $baseline 6>$null)
            $reports = @(Get-ChildItem -LiteralPath (Join-Path $dir 'logs\windows-tests') -Filter 'summary-*.json')
            Assert-Equal 1 $reports.Count
            $good = Get-Content -LiteralPath $reports[0].FullName -Raw | ConvertFrom-Json
            Assert-Equal 3 $good.Total
            Assert-Equal 3 $good.Passed
            Assert-Equal 0 $good.FailedCount
            Assert-True $good.FloorMet
            Assert-Equal 0 $good.ExitCode

            $custom = Join-Path $dir 'custom\summary.json'
            $failed = @([pscustomobject]@{ Group = 'group'; Name = 'case'; Err = 'failure' })
            $failingTally = New-TestTally -Total 2 -Passed 1 -PesterFailures 0 -Failed $failed -Skipped @('skipped')
            Assert-Equal 1 (Write-TestSummary -Tally $failingTally -Broken @('broken') -SummaryFile $custom 6>$null)
            $bad = Get-Content -LiteralPath $custom -Raw | ConvertFrom-Json
            Assert-Equal 1 $bad.FailedCount
            Assert-Equal 'case' $bad.Failed[0].Name
            Assert-Equal 'skipped' $bad.Skipped[0]
            Assert-Equal 'broken' $bad.Broken[0]
            Assert-False $bad.FloorMet
            Assert-Equal 1 $bad.ExitCode
            Assert-Equal 1 @(Get-ChildItem -LiteralPath (Join-Path $dir 'logs\windows-tests') -Filter 'summary-*.json').Count 'the custom path does not create a second default report'
        }
    }

    It 'fails loudly when the summary cannot be saved' {
        Invoke-SummaryWriterFixture { param($dir, $baseline)
            $ErrorActionPreference = 'Continue'
            Assert-Throws { Write-TestSummary -Tally $baseline -SummaryFile $dir 6>$null }
        }
    }

    It 'fails the parent verdict when all tests pass but coverage falls' {
        Invoke-SummaryWriterFixture { param($dir, $baseline)
            $baseline['CoverageFailures'] = @('module: below floor')
            $summary = Join-Path $dir 'logs/windows-tests/summary.json'
            Assert-Equal 1 (Write-TestSummary -Tally $baseline -SummaryFile $summary 6>$null)
            $saved = Get-Content -LiteralPath $summary -Raw | ConvertFrom-Json
            Assert-False $saved.CoverageFloorMet
            Assert-Equal 1 $saved.ExitCode
        }
    }

    It 'rejects a missing target and a duplicate target in a full run' {
        Invoke-SummaryWriterFixture { param($dir, $baseline)
            $targets = Get-CoverageTargets
            $rows = @($targets.Keys | ForEach-Object {
                [pscustomobject]@{ Suite = $_; Module = $targets[$_].Module; Percent = 100;
                    MinimumPercent = $targets[$_].MinimumPercent; Analyzed = 1; Executed = 1; ReportPath = 'fixture.xml' }
            })
            $baseline['Coverage'] = @($rows | Select-Object -First 2)
            Assert-CoverageInventoryFailure -Tally $baseline -Path (Join-Path $dir 'logs/windows-tests/missing.json') `
                -Pattern 'expected one .* report, got 0'

            $baseline['Coverage'] = @($rows) + @($rows[0])
            $baseline['CoverageFailures'] = @()
            Assert-CoverageInventoryFailure -Tally $baseline -Path (Join-Path $dir 'logs/windows-tests/duplicate.json') `
                -Pattern 'expected one .* report, got 2'
        }
    }
}
