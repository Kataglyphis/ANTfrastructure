#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Harness-style, so the Linux mutation shards run it without Pester; the comparison's other cases stay in WindowsPerfBaseline.Common.Tests.ps1.

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsPerfBaseline.Common.psm1') -Force

function New-NotRunDocument {
    param([string]$Dir, [string]$Name, [hashtable]$Benchmark)
    $path = Join-Path $Dir $Name
    (@{ benchmarks = @($Benchmark) } | ConvertTo-Json -Depth 5) | Set-Content -Path $path
    $path
}

Describe 'WindowsPerfBaseline.Common: a benchmark that did not run' {
    It 'refuses an errored and a skipped benchmark, each named with its own message' {
        Invoke-InTestDir { param($dir)
            $errored = New-NotRunDocument $dir 'errored.json' @{ name = 'BM_A'; error_occurred = $true; error_message = 'model missing'
                iterations = 0; real_time = 0.0; cpu_time = 0.0; time_unit = 'ns' }
            $skipped = New-NotRunDocument $dir 'skipped.json' @{ name = 'BM_A'; skipped = $true; skip_message = 'no display'
                iterations = 0; real_time = 0.0; time_unit = 'ns' }
            Assert-Throws -MessagePattern '1 benchmark\(s\) that did not run.*BM_A \(error_occurred: model missing\)' -Body {
                Get-BenchmarkTimeMap -Path $errored
            }
            Assert-Throws -MessagePattern 'BM_A \(skipped: no display\)' -Body { Get-BenchmarkTimeMap -Path $skipped }
        }
    }
}
