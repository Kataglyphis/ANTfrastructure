# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# Invariant culture per call and ordinal sorting, so the report is identical on every host without touching global state.

Set-StrictMode -Version Latest

$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture

# An unknown time_unit throws: a format change beats a silent 10^3 mis-scale.
function ConvertTo-Nanoseconds {
    param(
        [Parameter(Mandatory)]
        [double]$Value,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Unit
    )

    switch ($Unit) {
        'ns' { $Value }
        'us' { $Value * 1000.0 }
        'ms' { $Value * 1000000.0 }
        's' { $Value * 1000000000.0 }
        default { throw "Unknown time_unit '$Unit' - Google Benchmark only emits ns/us/ms/s." }
    }
}

# The sign is explicit ("+12.5%") so a column of deltas reads without a legend.
function Format-BenchmarkDelta {
    param(
        [Parameter(Mandatory)]
        [double]$Delta
    )

    $pct = [math]::Round($Delta * 100.0, 1)
    $sign = if ($pct -ge 0) { '+' } else { '' }
    return $sign + $pct.ToString($script:Invariant) + '%'
}

# name -> nanoseconds; each entry's time_unit applies to both real_time and cpu_time.
function Get-BenchmarkTimeMap {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$Metric = 'real_time'
    )

    $document = Get-Content $Path -Raw | ConvertFrom-Json
    $map = @{}
    foreach ($benchmark in $document.benchmarks) {
        $map[$benchmark.name] = ConvertTo-Nanoseconds -Value $benchmark.$Metric -Unit $benchmark.time_unit
    }
    return $map
}

# Pure; only 'compared' rows can regress, since suites grow and shrink ('only-base', 'only-cand').
function Compare-BenchmarkTimeMap {
    param(
        [Parameter(Mandatory)]
        [hashtable]$BaselineMap,
        [Parameter(Mandatory)]
        [hashtable]$CandidateMap,
        [double]$ToleranceFraction = 0.25
    )

    $names = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($name in $BaselineMap.Keys) { [void]$names.Add($name) }
    foreach ($name in $CandidateMap.Keys) { [void]$names.Add($name) }

    $rows = @()
    $regressions = @()
    $onlyInBaseline = @()
    $onlyInCandidate = @()

    foreach ($name in $names) {
        $hasBase = $BaselineMap.ContainsKey($name)
        $hasCandidate = $CandidateMap.ContainsKey($name)

        if ($hasBase -and $hasCandidate) {
            $base = [double]$BaselineMap[$name]
            $candidate = [double]$CandidateMap[$name]
            # A zero baseline cannot express a relative change.
            $delta = if ($base -ne 0) { ($candidate - $base) / $base } else { 0.0 }
            $isRegression = $delta -gt $ToleranceFraction
            $row = [pscustomobject]@{
                Name         = $name
                Baseline     = $base
                Candidate    = $candidate
                Delta        = $delta
                Status       = 'compared'
                IsRegression = $isRegression
            }
            $rows += $row
            if ($isRegression) { $regressions += $row }
        } elseif ($hasBase) {
            $rows += [pscustomobject]@{
                Name         = $name
                Baseline     = [double]$BaselineMap[$name]
                Candidate    = $null
                Delta        = $null
                Status       = 'only-base'
                IsRegression = $false
            }
            $onlyInBaseline += $name
        } else {
            $rows += [pscustomobject]@{
                Name         = $name
                Baseline     = $null
                Candidate    = [double]$CandidateMap[$name]
                Delta        = $null
                Status       = 'only-cand'
                IsRegression = $false
            }
            $onlyInCandidate += $name
        }
    }

    return [pscustomobject]@{
        Rows            = @($rows)
        Regressions     = @($regressions)
        OnlyInBaseline  = @($onlyInBaseline)
        OnlyInCandidate = @($onlyInCandidate)
        HasRegression   = ($regressions.Count -gt 0)
    }
}

function Format-BenchmarkTolerance {
    param(
        [Parameter(Mandatory)]
        [double]$ToleranceFraction
    )

    return [math]::Round($ToleranceFraction * 100, 1).ToString($script:Invariant)
}

# Pure, so the column layout is testable without capturing host output.
function Format-BenchmarkRow {
    param(
        [Parameter(Mandatory)]
        [psobject]$Row
    )

    switch ($Row.Status) {
        'compared' {
            [string]::Format($script:Invariant, '{0,-42} {1,14:N1} {2,14:N1} {3,10}',
                $Row.Name, $Row.Baseline, $Row.Candidate, (Format-BenchmarkDelta -Delta $Row.Delta))
        }
        'only-base' {
            [string]::Format($script:Invariant, '{0,-42} {1,14:N1} {2,14} {3,10}',
                $Row.Name, $Row.Baseline, '-', 'only-base')
        }
        default {
            [string]::Format($script:Invariant, '{0,-42} {1,14} {2,14:N1} {3,10}',
                $Row.Name, '-', $Row.Candidate, 'only-cand')
        }
    }
}

function Write-BenchmarkComparisonReport {
    param(
        [Parameter(Mandatory)]
        [psobject]$Comparison,
        [Parameter(Mandatory)]
        [string]$BaselinePath,
        [Parameter(Mandatory)]
        [string]$CandidatePath,
        [double]$ToleranceFraction = 0.25,
        [string]$PassBanner = '=== PERF BASELINE COMPARISON PASSED ===',
        [string]$FailBanner = '=== PERF BASELINE COMPARISON FAILED (regression detected) ==='
    )

    $tolerance = Format-BenchmarkTolerance -ToleranceFraction $ToleranceFraction

    Write-Host "Baseline:  $BaselinePath" -ForegroundColor Cyan
    Write-Host "Candidate: $CandidatePath" -ForegroundColor Cyan
    Write-Host "Tolerance: +$tolerance%" -ForegroundColor Cyan
    Write-Host ''
    Write-Host ("{0,-42} {1,14} {2,14} {3,10}" -f 'Benchmark', 'baseline ns', 'candidate ns', 'delta')
    Write-Host ('-' * 84)

    foreach ($row in $Comparison.Rows) {
        $color = if ($row.Status -ne 'compared') { 'Yellow' }
                 elseif ($row.IsRegression) { 'Red' }
                 else { 'Gray' }
        Write-Host (Format-BenchmarkRow -Row $row) -ForegroundColor $color
    }

    Write-Host ''
    if ($Comparison.OnlyInBaseline.Count -gt 0) {
        Write-Host "Only in baseline (removed or renamed?): $($Comparison.OnlyInBaseline -join ', ')" -ForegroundColor Yellow
    }
    if ($Comparison.OnlyInCandidate.Count -gt 0) {
        Write-Host "Only in candidate (new benchmark, no baseline yet): $($Comparison.OnlyInCandidate -join ', ')" -ForegroundColor Yellow
    }

    if ($Comparison.Regressions.Count -gt 0) {
        Write-Host ''
        Write-Host "REGRESSIONS (beyond +$tolerance%):" -ForegroundColor Red
        foreach ($regression in $Comparison.Regressions) {
            Write-Host ([string]::Format($script:Invariant, '  {0}: {1:N1} ns -> {2:N1} ns ({3})',
                $regression.Name, $regression.Baseline, $regression.Candidate,
                (Format-BenchmarkDelta -Delta $regression.Delta))) -ForegroundColor Red
        }
    }

    Write-Host ''
    if ($Comparison.HasRegression) {
        Write-Host $FailBanner -ForegroundColor Red
    } else {
        Write-Host $PassBanner -ForegroundColor Green
    }
}

# Returns the exit code: 1 when any compared benchmark exceeds the tolerance.
function Invoke-BenchmarkBaselineComparison {
    param(
        [Parameter(Mandatory)]
        [string]$BaselinePath,
        [Parameter(Mandatory)]
        [string]$CandidatePath,
        [double]$ToleranceFraction = 0.25,
        [string]$Metric = 'real_time',
        [string]$PassBanner = '=== PERF BASELINE COMPARISON PASSED ===',
        [string]$FailBanner = '=== PERF BASELINE COMPARISON FAILED (regression detected) ==='
    )

    if (-not (Test-Path $BaselinePath)) { throw "Baseline not found at $BaselinePath" }
    if (-not (Test-Path $CandidatePath)) { throw "Candidate not found at $CandidatePath" }

    $comparison = Compare-BenchmarkTimeMap `
        -BaselineMap (Get-BenchmarkTimeMap -Path $BaselinePath -Metric $Metric) `
        -CandidateMap (Get-BenchmarkTimeMap -Path $CandidatePath -Metric $Metric) `
        -ToleranceFraction $ToleranceFraction

    Write-BenchmarkComparisonReport -Comparison $comparison -BaselinePath $BaselinePath `
        -CandidatePath $CandidatePath -ToleranceFraction $ToleranceFraction `
        -PassBanner $PassBanner -FailBanner $FailBanner

    if ($comparison.HasRegression) { return 1 }
    return 0
}

Export-ModuleMember -Function ConvertTo-Nanoseconds, Format-BenchmarkDelta, Get-BenchmarkTimeMap,
    Compare-BenchmarkTimeMap, Format-BenchmarkTolerance, Format-BenchmarkRow,
    Write-BenchmarkComparisonReport, Invoke-BenchmarkBaselineComparison
