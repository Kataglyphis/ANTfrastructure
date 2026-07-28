# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

<#
.SYNOPSIS
    Host resource sampler + analyzer for the Windows container build
    (started/stopped by windows/build.ps1; can also run standalone).

.DESCRIPTION
    SAMPLING (default): appends one CSV row every -IntervalSeconds with host CPU,
    RAM, commit charge, and the Hyper-V container VM footprint (vmmem*), tagged
    with the current BUILD PHASE read from -PhaseFile (build.ps1 rewrites that file
    at every docker build / run+commit / commit step). Runs until killed -- the
    orchestrator owns the lifecycle. Locale-independent (CIM, no perf-counter
    names -- Get-Counter paths are localized and break on non-English hosts).

    ANALYSIS (-Summarize): groups an existing CSV by phase and prints which steps
    exhausted the machine the most (sorted by lowest free RAM, i.e. peak memory
    pressure first), plus CPU utilisation per phase.

    Columns: ts, phase, cpuPct, freeGB, usedGB, committedGB, vmmemGB
      cpuPct      -- average Win32_Processor LoadPercentage (instantaneous)
      freeGB      -- FreePhysicalMemory (true free+zero pages; standby cache NOT counted)
      committedGB -- system commit charge (grows when the build forces paging)
      vmmemGB     -- working set of vmmem* (the Hyper-V VM hosting the build container)

.EXAMPLE
    # sample every 20s into a CSV, phase-tagged (how build.ps1 invokes it)
    pwsh -File build-resource-sampler.ps1 -CsvPath out\windows-build-logs\resources-x.csv -PhaseFile out\windows-build-logs\current-phase.txt

.EXAMPLE
    # analyze afterwards: which phases exhausted the machine the most?
    pwsh -File build-resource-sampler.ps1 -Summarize -CsvPath out\windows-build-logs\resources-x.csv
#>
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [string]$PhaseFile = '',
    [int]$IntervalSeconds = 20,
    [switch]$Summarize
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Summarize) {
    if (-not (Test-Path $CsvPath)) { Write-Warning "no resource CSV at $CsvPath"; return }
    $rows = @(Import-Csv $CsvPath | Where-Object { $_.cpuPct -match '^\d' })
    if ($rows.Count -eq 0) { Write-Warning "resource CSV has no samples: $CsvPath"; return }

    Write-Host ''
    Write-Host "=== RESOURCE SUMMARY by build phase (peak-memory-pressure first; full series: $CsvPath) ===" -ForegroundColor Cyan
    $summary = $rows | Group-Object phase | ForEach-Object {
        $g = $_.Group
        $first = [datetime]::ParseExact($g[0].ts, 'yyyy-MM-dd HH:mm:ss', $null)
        $last = [datetime]::ParseExact($g[-1].ts, 'yyyy-MM-dd HH:mm:ss', $null)
        [pscustomobject]@{
            Phase        = $_.Name
            Minutes      = [math]::Round(($last - $first).TotalMinutes, 1)
            AvgCpuPct    = [int](($g | Measure-Object -Property cpuPct -Average).Average)
            MaxCpuPct    = [int](($g | Measure-Object -Property cpuPct -Maximum).Maximum)
            MinFreeGB    = [math]::Round(($g | Measure-Object -Property freeGB -Minimum).Minimum, 1)
            MaxVmmemGB   = [math]::Round(($g | Measure-Object -Property vmmemGB -Maximum).Maximum, 1)
            MaxCommitGB  = [math]::Round(($g | Measure-Object -Property committedGB -Maximum).Maximum, 1)
        }
    } | Sort-Object MinFreeGB
    $summary | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "  MinFreeGB = lowest host free RAM during the phase (the 'exhaustion' metric)." -ForegroundColor DarkGray
    Write-Host "  AvgCpuPct persistently far below 100 during a compile phase = memory-bound (jobs = min(cores, MEMORY_LIMIT_GB/perJob))." -ForegroundColor DarkGray
    return
}

# ---- sampling loop (runs until the parent kills this process) ----
$csvDir = Split-Path -Parent $CsvPath
if ($csvDir -and -not (Test-Path $csvDir)) { New-Item -ItemType Directory -Force $csvDir | Out-Null }
if (-not (Test-Path $CsvPath)) {
    'ts,phase,cpuPct,freeGB,usedGB,committedGB,vmmemGB' | Set-Content -Path $CsvPath
}
while ($true) {
    try {
        $phase = if ($PhaseFile -and (Test-Path $PhaseFile)) { (Get-Content $PhaseFile -First 1 -ErrorAction SilentlyContinue) } else { '' }
        if ([string]::IsNullOrWhiteSpace($phase)) { $phase = '-' }
        $cpu = [int](Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        $os = Get-CimInstance Win32_OperatingSystem
        $freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $usedGB = [math]::Round($totalGB - $freeGB, 1)
        $committedGB = [math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB, 1)
        $vmmem = (Get-Process -Name 'vmmem*' -ErrorAction SilentlyContinue | Measure-Object -Property WorkingSet64 -Sum).Sum
        $vmmemGB = if ($vmmem) { [math]::Round($vmmem / 1GB, 1) } else { 0 }
        # phase strings come from build.ps1 labels (no commas), but sanitize anyway
        $phase = $phase -replace ',', ';'
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$phase,$cpu,$freeGB,$usedGB,$committedGB,$vmmemGB" | Add-Content -Path $CsvPath
    } catch {
        # never let a transient CIM hiccup kill the series mid-build
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),sample-error,,,,," | Add-Content -Path $CsvPath -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds $IntervalSeconds
}

