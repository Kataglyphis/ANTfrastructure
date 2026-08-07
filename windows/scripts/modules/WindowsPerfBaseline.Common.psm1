# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# WindowsPerfBaseline.Common - Google Benchmark baseline comparator.
#
# Google Benchmark emits the same JSON document for every project that uses it
# (`--benchmark_out=x.json --benchmark_out_format=json`), so "diff a fresh run
# against a checked-in baseline and fail on a regression" is the same code
# everywhere:
#   1. read both documents and normalise every timing to nanoseconds, because
#      Google Benchmark picks `time_unit` per benchmark (ns/us/ms/s) and the two
#      runs are free to disagree about it
#   2. match benchmarks by name - a benchmark present in only one document is
#      reported but never fatal, since suites grow and shrink over time
#   3. flag anything slower than baseline * (1 + tolerance)
#   4. print the table + the regression summary
#
# This module is project-agnostic: the baseline path, the tolerance, and the
# policy around refreshing a baseline stay in the consuming script.
#
# Everything here formats numbers with the invariant culture EXPLICITLY rather
# than mutating the thread's culture, so a comma-decimal host prints
# "1,234.5 ns"/"+12.5%" like everyone else without the module reaching into
# global state. Benchmark names are sorted ordinally for the same reason: the
# report must not reorder itself depending on who runs it.

Set-StrictMode -Version Latest

$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture

# Google Benchmark's `time_unit` values. Anything else is a format change we
# would rather hear about than silently mis-scale by 10^3.
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

# "+12.5%" / "-3%" - the sign is explicit so a table column of deltas reads
# without a legend.
function Format-BenchmarkDelta {
    param(
        [Parameter(Mandatory)]
        [double]$Delta
    )

    $pct = [math]::Round($Delta * 100.0, 1)
    $sign = if ($pct -ge 0) { '+' } else { '' }
    return $sign + $pct.ToString($script:Invariant) + '%'
}

# name -> nanoseconds map for one Google Benchmark JSON document.
# -Metric selects the field ('real_time' by default, 'cpu_time' being the other
# one worth comparing); the per-entry `time_unit` applies to both.
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

# Pure comparison over two name->nanoseconds maps. No I/O, no formatting - the
# report and the exit code are derived from what this returns.
#
# Rows are ordered by name (ordinal) and carry a Status of 'compared',
# 'only-base' or 'only-cand'. Only 'compared' rows can regress.
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
            # A zero baseline cannot express a relative change; report 0% rather
            # than dividing by it.
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

# Percent shown in the header/summary lines ("+25%"), invariant like the rest.
function Format-BenchmarkTolerance {
    param(
        [Parameter(Mandatory)]
        [double]$ToleranceFraction
    )

    return [math]::Round($ToleranceFraction * 100, 1).ToString($script:Invariant)
}

# One table line for a comparison row. Pure, so the column layout is unit-
# testable without capturing host output.
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

# Prints the whole report: header, table, the two "only in ..." lines, the
# regression summary and the PASSED/FAILED banner.
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

# Full pipeline: read both documents, compare, print, and return the process
# exit code (0 = no regression, 1 = at least one benchmark beyond tolerance).
# A benchmark present in only one document never contributes to the exit code.
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
