#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: Pester's instrumentation internals or nonselected suites; these fixtures mutate a measured result and its report.

function Write-CoberturaFixture {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ClassPath)
    $content = "<!DOCTYPE coverage SYSTEM 'coverage-loose.dtd'[]><coverage><packages><package><classes><class filename='$ClassPath'><lines><line number='1' hits='1'/></lines></class></classes></package></packages></coverage>"
    Set-Content -LiteralPath $Path -Value $content
}

function Invoke-CoverageFixture {
    param([Parameter(Mandatory)][scriptblock]$Body)
    Invoke-InTestDir { param($dir)
        $report = Join-Path $dir 'coverage.xml'
        $measured = [pscustomobject]@{
            FilesAnalyzedCount = 1; CommandsAnalyzedCount = 39; CommandsExecutedCount = 35; CoveragePercent = 89.74
        }
        $expectedClass = 'windows/scripts/modules/WindowsAppRunner.Common.psm1'
        Write-CoberturaFixture -Path $report -ClassPath $expectedClass
        & $Body $report $measured $expectedClass
    }
}

function Assert-CoverageRejected {
    param([Parameter(Mandatory)][object]$Measured, [Parameter(Mandatory)][string]$Report,
        [Parameter(Mandatory)][string]$ExpectedClass, [Parameter(Mandatory)][string]$Pattern)
    $reason = Get-CoverageFailure -Coverage $Measured -ReportPath $Report -ExpectedClass $ExpectedClass -MinimumPercent 85
    Assert-Match $Pattern $reason
}

Describe 'Invoke-Tests coverage gate' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/tests/Invoke-Tests.ps1' `
        -FunctionName Get-CoberturaModuleFailure, Get-CoverageFailure, Get-CoverageTargets)

    It 'keeps every measured suite and its floor armed' {
        $expected = @(
            'WindowsAppRunner.Common.Tests.ps1=WindowsAppRunner.Common.psm1:85'
            'WindowsBuildSweep.Common.Tests.ps1=WindowsBuildSweep.Common.psm1:90'
            'WindowsAgenticLoop.Common.Tests.ps1=WindowsAgenticLoop.Common.psm1:60'
            'WindowsConfig.Common.Tests.ps1=WindowsConfig.Common.psm1:90'
            'WindowsOnnx.Common.Tests.ps1=WindowsOnnx.Common.psm1:100'
            'WindowsRepoHygiene.Common.Tests.ps1=WindowsRepoHygiene.Common.psm1:85'
            'WindowsPerfBaseline.Common.Tests.ps1=WindowsPerfBaseline.Common.psm1:90'
            'WindowsClang.Common.Tests.ps1=WindowsClang.Common.psm1:80'
            'WindowsMsix.Common.Tests.ps1=WindowsMsix.Common.psm1:80'
            'WindowsSlang.Common.Tests.ps1=WindowsSlang.Common.psm1:65'
            'WindowsWasmOpt.Common.Tests.ps1=WindowsWasmOpt.Common.psm1:80'
        ) | Sort-Object
        $targets = Get-CoverageTargets
        $actual = @($targets.Keys | ForEach-Object { "$_=$($targets[$_].Module):$($targets[$_].MinimumPercent)" } | Sort-Object)
        Assert-Equal ($expected -join '|') ($actual -join '|')
    }

    It 'detects a removed target or a relaxed floor in the target inventory' {
        foreach ($target in @(
            @{ Suite = 'WindowsOnnx.Common.Tests.ps1'; Module = 'WindowsOnnx.Common.psm1'; Floor = 100 }
            @{ Suite = 'WindowsWasmOpt.Common.Tests.ps1'; Module = 'WindowsWasmOpt.Common.psm1'; Floor = 80 }
        )) {
            $row = "'$($target.Suite)' = @{ Module = '$($target.Module)'; MinimumPercent = $($target.Floor) }"
            Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/tests/Invoke-Tests.ps1' `
                -FunctionName Get-CoverageTargets -BodyArgumentList @($target.Suite, "$($target.Module):$($target.Floor)") `
                -IncludeControl -Case @(
                    @{ Find = $row; Replace = ''; Expected = 'Assert-Equal: expected' }
                    @{ Find = $row; Replace = ($row -replace "MinimumPercent = $($target.Floor)", 'MinimumPercent = 0'); Expected = 'Assert-Equal: expected' }
                ) -Body {
                param($suite, $expected)
                $targets = Get-MutCoverageTargets
                $entry = $targets[$suite]
                $actual = if ($null -eq $entry) { '' } else { "$($entry.Module):$($entry.MinimumPercent)" }
                Assert-Equal $expected $actual
            }
        }
    }

    It 'accepts a measured module above its floor' {
        Invoke-CoverageFixture { param($report, $measured, $expectedClass)
            Assert-Equal '' (Get-CoverageFailure -Coverage $measured -ReportPath $report `
                -ExpectedClass $expectedClass -MinimumPercent 85)
        }
    }

    It 'rejects a missing or empty report even when command counts look good' {
        Invoke-CoverageFixture { param($report, $measured, $expectedClass)
            Remove-Item -LiteralPath $report
            Assert-CoverageRejected -Measured $measured -Report $report -ExpectedClass $expectedClass -Pattern 'report is missing'
            Set-Content -LiteralPath $report -Value '' -NoNewline
            Assert-CoverageRejected -Measured $measured -Report $report -ExpectedClass $expectedClass -Pattern 'report is empty'
        }
    }

    It 'rejects a zero-file scan and a result below the measured floor' {
        Invoke-CoverageFixture { param($report, $mutated, $expectedClass)
            $mutated.FilesAnalyzedCount = 0
            Assert-CoverageRejected -Measured $mutated -Report $report -ExpectedClass $expectedClass -Pattern 'expected one measured module'
            $mutated.FilesAnalyzedCount = 1
            $mutated.CommandsExecutedCount = 30
            $mutated.CoveragePercent = 76.92
            Assert-CoverageRejected -Measured $mutated -Report $report -ExpectedClass $expectedClass -Pattern 'below 85%'
        }
    }

    It 'rejects malformed XML and a report for the wrong module' {
        Invoke-CoverageFixture { param($report, $measured, $expectedClass)
            Set-Content -LiteralPath $report '<coverage><broken>'
            Assert-CoverageRejected -Measured $measured -Report $report -ExpectedClass $expectedClass -Pattern 'invalid Cobertura XML'
            Write-CoberturaFixture -Path $report -ClassPath 'windows/scripts/modules/Wrong.Common.psm1'
            Assert-CoverageRejected -Measured $measured -Report $report -ExpectedClass $expectedClass -Pattern 'Cobertura class is'
        }
    }
}
