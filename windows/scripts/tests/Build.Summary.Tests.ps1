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
}
