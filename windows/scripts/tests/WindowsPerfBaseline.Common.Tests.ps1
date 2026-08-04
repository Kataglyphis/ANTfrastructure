# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Covers the pure parts of WindowsPerfBaseline.Common: time_unit normalisation,
# the comparison over two name->ns maps (including the "present in only one
# run" cases, which must never be fatal), the invariant number formatting, and
# the end-to-end exit-code contract of Invoke-BenchmarkBaselineComparison
# against small fixture documents.

Describe 'WindowsPerfBaseline.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsPerfBaseline.Common.psm1'
    Import-Module $modulePath -Force

    $script:root = (New-Item -ItemType Directory -Path (Join-Path $env:TEMP ('perfbaseline-' + (Get-Random))) -Force).FullName

    function New-BenchmarkDocument {
      param([string]$Path, [array]$Benchmarks)
      (@{ benchmarks = $Benchmarks } | ConvertTo-Json -Depth 5) | Set-Content -Path $Path
    }
  }

  AfterAll {
    Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
  }

  Context 'ConvertTo-Nanoseconds' {
    It 'passes nanoseconds through unchanged' {
      ConvertTo-Nanoseconds -Value 42.5 -Unit 'ns' | Should -Be 42.5
    }

    It 'scales us, ms and s to nanoseconds' {
      ConvertTo-Nanoseconds -Value 1 -Unit 'us' | Should -Be 1000
      ConvertTo-Nanoseconds -Value 1 -Unit 'ms' | Should -Be 1000000
      ConvertTo-Nanoseconds -Value 1 -Unit 's' | Should -Be 1000000000
    }

    It 'throws on a time_unit Google Benchmark never emits' {
      $threw = $false
      try { ConvertTo-Nanoseconds -Value 1 -Unit 'min' } catch { $threw = $true }
      $threw | Should -Be $true
    }
  }

  Context 'Format-BenchmarkDelta' {
    It 'signs a slowdown and leaves a speedup negative' {
      Format-BenchmarkDelta -Delta 0.6 | Should -Be '+60%'
      Format-BenchmarkDelta -Delta -0.5 | Should -Be '-50%'
      Format-BenchmarkDelta -Delta 0 | Should -Be '+0%'
    }

    It 'rounds to one decimal' {
      Format-BenchmarkDelta -Delta 0.12345 | Should -Be '+12.3%'
    }

    It 'uses a dot decimal separator on a comma-decimal host' {
      $saved = [System.Threading.Thread]::CurrentThread.CurrentCulture
      try {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('de-DE')
        Format-BenchmarkDelta -Delta 0.125 | Should -Be '+12.5%'
        Format-BenchmarkTolerance -ToleranceFraction 0.155 | Should -Be '15.5'
      } finally {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $saved
      }
    }
  }

  Context 'Get-BenchmarkTimeMap' {
    It 'normalises every entry to nanoseconds regardless of its own time_unit' {
      $path = Join-Path $script:root 'units.json'
      New-BenchmarkDocument -Path $path -Benchmarks @(
        @{ name = 'BM_Ns'; real_time = 1000.0; cpu_time = 900.0; time_unit = 'ns' },
        @{ name = 'BM_Us'; real_time = 1.0; cpu_time = 2.0; time_unit = 'us' }
      )

      $map = Get-BenchmarkTimeMap -Path $path
      $map['BM_Ns'] | Should -Be 1000
      $map['BM_Us'] | Should -Be 1000
    }

    It 'can compare cpu_time instead of real_time' {
      $path = Join-Path $script:root 'metric.json'
      New-BenchmarkDocument -Path $path -Benchmarks @(
        @{ name = 'BM_A'; real_time = 10.0; cpu_time = 7.0; time_unit = 'us' }
      )

      (Get-BenchmarkTimeMap -Path $path -Metric 'cpu_time')['BM_A'] | Should -Be 7000
    }
  }

  Context 'Compare-BenchmarkTimeMap' {
    It 'reports no regression for identical runs' {
      $result = Compare-BenchmarkTimeMap -BaselineMap @{ 'BM_A' = 100.0 } -CandidateMap @{ 'BM_A' = 100.0 }
      $result.HasRegression | Should -Be $false
      $result.Rows[0].Status | Should -Be 'compared'
      $result.Rows[0].Delta | Should -Be 0
    }

    It 'flags a 50% slowdown at the default tolerance and clears it at 1.0' {
      $baseline = @{ 'BM_A' = 100.0 }
      $candidate = @{ 'BM_A' = 150.0 }
      (Compare-BenchmarkTimeMap -BaselineMap $baseline -CandidateMap $candidate).HasRegression | Should -Be $true
      (Compare-BenchmarkTimeMap -BaselineMap $baseline -CandidateMap $candidate -ToleranceFraction 1.0).HasRegression | Should -Be $false
    }

    It 'treats exactly-at-tolerance as passing' {
      (Compare-BenchmarkTimeMap -BaselineMap @{ 'BM_A' = 100.0 } -CandidateMap @{ 'BM_A' = 125.0 }).HasRegression | Should -Be $false
    }

    It 'reports one-sided benchmarks without ever making them fatal' {
      $result = Compare-BenchmarkTimeMap -BaselineMap @{ 'BM_Old' = 1.0 } -CandidateMap @{ 'BM_New' = 999999.0 }
      $result.HasRegression | Should -Be $false
      $result.OnlyInBaseline | Should -Be 'BM_Old'
      $result.OnlyInCandidate | Should -Be 'BM_New'
      ($result.Rows | Where-Object { $_.Name -eq 'BM_New' }).Status | Should -Be 'only-cand'
      ($result.Rows | Where-Object { $_.Name -eq 'BM_Old' }).Status | Should -Be 'only-base'
    }

    It 'reports 0% rather than dividing by a zero baseline' {
      $result = Compare-BenchmarkTimeMap -BaselineMap @{ 'BM_A' = 0.0 } -CandidateMap @{ 'BM_A' = 500.0 }
      $result.Rows[0].Delta | Should -Be 0
      $result.HasRegression | Should -Be $false
    }

    It 'orders rows by name so the report never reshuffles itself' {
      $result = Compare-BenchmarkTimeMap -BaselineMap @{ 'BM_C' = 1.0; 'BM_A' = 1.0 } -CandidateMap @{ 'BM_B' = 1.0 }
      ($result.Rows | ForEach-Object { $_.Name }) -join ',' | Should -Be 'BM_A,BM_B,BM_C'
    }
  }

  Context 'Format-BenchmarkRow' {
    It 'right-aligns the two timing columns with thousands separators' {
      $row = [pscustomobject]@{ Name = 'BM_A'; Baseline = 1234.5; Candidate = 2000.0; Delta = 0.62; Status = 'compared'; IsRegression = $true }
      Format-BenchmarkRow -Row $row | Should -Match '^BM_A\s+1,234\.5\s+2,000\.0\s+\+62%$'
    }

    It 'renders a dash for the missing side of a one-sided row' {
      $row = [pscustomobject]@{ Name = 'BM_A'; Baseline = $null; Candidate = 10.0; Delta = $null; Status = 'only-cand'; IsRegression = $false }
      Format-BenchmarkRow -Row $row | Should -Match '^BM_A\s+-\s+10\.0\s+only-cand$'
    }
  }

  Context 'Invoke-BenchmarkBaselineComparison' {
    It 'returns 0 when nothing regressed and 1 when something did' {
      $basePath = Join-Path $script:root 'e2e-base.json'
      $goodPath = Join-Path $script:root 'e2e-good.json'
      $badPath = Join-Path $script:root 'e2e-bad.json'
      New-BenchmarkDocument -Path $basePath -Benchmarks @(@{ name = 'BM_A'; real_time = 1000.0; time_unit = 'ns' })
      # 1 us == the 1000 ns baseline: the units differ, the timing does not.
      New-BenchmarkDocument -Path $goodPath -Benchmarks @(@{ name = 'BM_A'; real_time = 1.0; time_unit = 'us' })
      New-BenchmarkDocument -Path $badPath -Benchmarks @(@{ name = 'BM_A'; real_time = 2000.0; time_unit = 'ns' })

      (Invoke-BenchmarkBaselineComparison -BaselinePath $basePath -CandidatePath $goodPath 6>$null) | Should -Be 0
      (Invoke-BenchmarkBaselineComparison -BaselinePath $basePath -CandidatePath $badPath 6>$null) | Should -Be 1
    }

    It 'throws when either document is missing' {
      $basePath = Join-Path $script:root 'e2e-base.json'
      $threwBaseline = $false
      $threwCandidate = $false
      try { Invoke-BenchmarkBaselineComparison -BaselinePath (Join-Path $script:root 'nope.json') -CandidatePath $basePath 6>$null } catch { $threwBaseline = $true }
      try { Invoke-BenchmarkBaselineComparison -BaselinePath $basePath -CandidatePath (Join-Path $script:root 'nope.json') 6>$null } catch { $threwCandidate = $true }
      $threwBaseline | Should -Be $true
      $threwCandidate | Should -Be $true
    }
  }
}
