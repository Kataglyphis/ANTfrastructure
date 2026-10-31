#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# A benchmark present in only one run must never be fatal.

Describe 'WindowsPerfBaseline.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsPerfBaseline.Common.psm1'
    Import-Module $modulePath -Force

    $script:root = New-TestDir -Prefix 'perfbaseline-'

    function New-BenchmarkDocument {
      param([string]$Name, [array]$Benchmarks)
      $path = Join-Path $script:root $Name
      (@{ benchmarks = $Benchmarks } | ConvertTo-Json -Depth 5) | Set-Content -Path $path
      $path
    }

    # Every fixture document is written once, so each test only names the one it reads.
    $script:doc = @{
      units = New-BenchmarkDocument -Name 'units.json' -Benchmarks @(
        @{ name = 'BM_Ns'; real_time = 1000.0; cpu_time = 900.0; time_unit = 'ns' },
        @{ name = 'BM_Us'; real_time = 1.0; cpu_time = 2.0; time_unit = 'us' }
      )
      metric = New-BenchmarkDocument -Name 'metric.json' -Benchmarks @(@{ name = 'BM_A'; real_time = 10.0; cpu_time = 7.0; time_unit = 'us' })
      base = New-BenchmarkDocument -Name 'e2e-base.json' -Benchmarks @(@{ name = 'BM_A'; real_time = 1000.0; time_unit = 'ns' })
      # 1 us == the 1000 ns baseline: the units differ, the timing does not.
      good = New-BenchmarkDocument -Name 'e2e-good.json' -Benchmarks @(@{ name = 'BM_A'; real_time = 1.0; time_unit = 'us' })
      bad = New-BenchmarkDocument -Name 'e2e-bad.json' -Benchmarks @(@{ name = 'BM_A'; real_time = 2000.0; time_unit = 'ns' })
    }
  }

  AfterAll {
    Remove-TestDir -Path $script:root
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
      $map = Get-BenchmarkTimeMap -Path $script:doc.units
      $map['BM_Ns'] | Should -Be 1000
      $map['BM_Us'] | Should -Be 1000
    }

    It 'can compare cpu_time instead of real_time' {
      (Get-BenchmarkTimeMap -Path $script:doc.metric -Metric 'cpu_time')['BM_A'] | Should -Be 7000
    }
  }

  Context 'Compare-BenchmarkTimeMap' {
    BeforeAll {
      # Each map pair is compared once, so each test only reads its result.
      $script:compared = @{
        identical = Compare-BenchmarkTimeMap -BaselineMap @{ 'BM_A' = 100.0 } -CandidateMap @{ 'BM_A' = 100.0 }
        atTolerance = Compare-BenchmarkTimeMap -BaselineMap @{ 'BM_A' = 100.0 } -CandidateMap @{ 'BM_A' = 125.0 }
        oneSided = Compare-BenchmarkTimeMap -BaselineMap @{ 'BM_Old' = 1.0 } -CandidateMap @{ 'BM_New' = 999999.0 }
        zeroBaseline = Compare-BenchmarkTimeMap -BaselineMap @{ 'BM_A' = 0.0 } -CandidateMap @{ 'BM_A' = 500.0 }
        ordering = Compare-BenchmarkTimeMap -BaselineMap @{ 'BM_C' = 1.0; 'BM_A' = 1.0 } -CandidateMap @{ 'BM_B' = 1.0 }
      }
    }

    It 'reports no regression for identical runs' {
      $result = $script:compared.identical
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
      $script:compared.atTolerance.HasRegression | Should -Be $false
    }

    It 'reports one-sided benchmarks without ever making them fatal' {
      $result = $script:compared.oneSided
      $result.HasRegression | Should -Be $false
      $result.OnlyInBaseline | Should -Be 'BM_Old'
      $result.OnlyInCandidate | Should -Be 'BM_New'
      ($result.Rows | Where-Object { $_.Name -eq 'BM_New' }).Status | Should -Be 'only-cand'
      ($result.Rows | Where-Object { $_.Name -eq 'BM_Old' }).Status | Should -Be 'only-base'
    }

    It 'reports 0% rather than dividing by a zero baseline' {
      $result = $script:compared.zeroBaseline
      $result.Rows[0].Delta | Should -Be 0
      $result.HasRegression | Should -Be $false
    }

    It 'orders rows by name so the report never reshuffles itself' {
      $result = $script:compared.ordering
      ($result.Rows | ForEach-Object { $_.Name }) -join ',' | Should -Be 'BM_A,BM_B,BM_C'
    }
  }

  Context 'Format-BenchmarkRow' {
    It '<Name>' -ForEach @(
      @{ Name = 'right-aligns the two timing columns with thousands separators'; Pattern = '^BM_A\s+1,234\.5\s+2,000\.0\s+\+62%$'
        Row = [pscustomobject]@{ Name = 'BM_A'; Baseline = 1234.5; Candidate = 2000.0; Delta = 0.62; Status = 'compared'; IsRegression = $true } }
      @{ Name = 'renders a dash for the missing side of a one-sided row'; Pattern = '^BM_A\s+-\s+10\.0\s+only-cand$'
        Row = [pscustomobject]@{ Name = 'BM_A'; Baseline = $null; Candidate = 10.0; Delta = $null; Status = 'only-cand'; IsRegression = $false } }
    ) {
      Format-BenchmarkRow -Row $Row | Should -Match $Pattern
    }
  }

  Context 'Invoke-BenchmarkBaselineComparison' {
    It 'returns 0 when nothing regressed and 1 when something did' {
      (Invoke-BenchmarkBaselineComparison -BaselinePath $script:doc.base -CandidatePath $script:doc.good 6>$null) | Should -Be 0
      (Invoke-BenchmarkBaselineComparison -BaselinePath $script:doc.base -CandidatePath $script:doc.bad 6>$null) | Should -Be 1
    }

    It 'throws when either document is missing' {
      $basePath = $script:doc.base
      $threwBaseline = $false
      $threwCandidate = $false
      try { Invoke-BenchmarkBaselineComparison -BaselinePath (Join-Path $script:root 'nope.json') -CandidatePath $basePath 6>$null } catch { $threwBaseline = $true }
      try { Invoke-BenchmarkBaselineComparison -BaselinePath $basePath -CandidatePath (Join-Path $script:root 'nope.json') 6>$null } catch { $threwCandidate = $true }
      $threwBaseline | Should -Be $true
      $threwCandidate | Should -Be $true
    }
  }
}
