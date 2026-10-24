#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

if (-not (Get-Module -Name 'WindowsBuild.Common')) {
    Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsBuild.Common.psm1') -DisableNameChecking
}

Describe 'Write-BuildSummary' {
    It 'keeps allowed failures in the headline without counting them as fatal failures' {
        Invoke-InTestDir { param($dir)
            $context = New-BuildContext -Workspace $dir -LogDir $dir
            $context.Results.Succeeded.Add('compile')
            $context.Results.AllowedFailures.Add('lint')
            $context.Results.Errors['lint'] = 'advisory result'
            $context.Results.Durations['compile'] = 1.25
            Open-BuildLog -Context $context
            try {
                Write-BuildSummary -Context $context
            } finally {
                Close-BuildLog -Context $context
            }

            $log = Get-Content -LiteralPath $context.LogPath -Raw
            Assert-Match 'ALLOWED FAILURES \(1\).*non-gating' $log
            Assert-Match 'Total: 2 steps, 1 succeeded, 0 failed, 1 failed but allowed \(50% success rate\)' $log
            Assert-Match 'Pipeline completed successfully!' $log
            $summary = Get-Content -LiteralPath $context.SummaryPath -Raw | ConvertFrom-Json
            Assert-Equal 2 $summary.totals.total
            Assert-Equal 0 $summary.totals.failed
            Assert-Equal 50 $summary.totals.successRate
        }
    }

    It 'closes the log and reports only fatal failures after writing the summary' {
        Invoke-InTestDir { param($dir)
            $context = New-BuildContext -Workspace $dir -LogDir $dir
            $context.Results.AllowedFailures.Add('optional lint')
            Open-BuildLog -Context $context
            Assert-False (Complete-CiBuildSession -Context $context) 'allowed failures do not fail CI'
            Assert-True ($null -eq $context.LogWriter) 'the log writer is closed'
            Assert-True (Test-Path -LiteralPath $context.SummaryPath) 'the summary is written before closing'

            $failed = New-BuildContext -Workspace $dir -LogDir $dir
            $failed.Results.Failed.Add('build')
            $failed.Results.Errors['build'] = 'tool exited 1'
            Open-BuildLog -Context $failed
            Assert-True (Complete-CiBuildSession -Context $failed) 'fatal failures fail CI'
            Assert-True ($null -eq $failed.LogWriter) 'the failed log writer is closed'
            $summary = Get-Content -LiteralPath $failed.SummaryPath -Raw | ConvertFrom-Json
            Assert-Equal 'build' (@($summary.failedSteps) -join ',')
        }
    }

    It 'detects a reversed fatal-step verdict in the shared finisher' {
        $stubs = @'
function Write-BuildSummary { param($Context) $Context.Order.Add('summary') }
function Close-BuildLog { param($Context) $Context.Order.Add('close') }
'@
        Invoke-TestFunctionMutations -ModuleArguments @{
            ScriptPath = 'windows/scripts/modules/WindowsBuild.Common.psm1'
            FunctionName = 'Complete-CiBuildSession'
            Prelude = $stubs
        } -Find 'return ($Context.Results.Failed.Count -gt 0)' -Replace 'return ($Context.Results.Failed.Count -lt 0)' `
            -Expected 'Assert-True failed' -IncludeControl -Body {
            $context = [pscustomobject]@{ Results = @{ Failed = [System.Collections.Generic.List[string]]::new() }
                Order = [System.Collections.Generic.List[string]]::new() }
            $context.Results.Failed.Add('build')
            Assert-True (Complete-MutCiBuildSession -Context $context) 'one fatal step must fail CI'
            Assert-Equal 'summary|close' ($context.Order -join '|')
        }
    }
}
