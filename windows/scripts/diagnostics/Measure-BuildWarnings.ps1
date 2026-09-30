# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Count compiler warnings in a build log, grouped by diagnostic family.

.DESCRIPTION
    Proves each targeted -Wno- suppression still earns its place: warning floods bury real failures.
.PARAMETER LogPath
    Build log to analyse, raw buildctl/nerdctl output included.
.PARAMETER Top
    How many families to list (default 15); 0 lists all.
.PARAMETER Baseline
    Also compare the four known floods with their pre-suppression counts, after a chain rebuild.
#>

param(
    [Parameter(Mandatory)][string]$LogPath,
    [int]$Top = 15,
    [switch]$Baseline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WarningFamily {
    # A warning line's family, else $null; clang keys on its -W group, which is what a -Wno- flag switches off.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    if ($Line -match 'warning\s+(STL\d+|C\d{4,5})\s*:') { return $Matches[1] }
    if ($Line -notmatch 'warning:') { return $null }
    if ($Line -match '\[(-W[a-z0-9-]+)\]\s*$') { return $Matches[1] }

    # No group: normalise quoted identifiers and numbers so near-identical texts collapse.
    $msg = ($Line -replace '^.*?warning:\s*', '').Trim()
    $msg = $msg -replace "'[^']*'", "'?'" -replace '\d+', 'N'
    if ($msg.Length -gt 80) { $msg = $msg.Substring(0, 80) }
    return "(ungrouped) $msg"
}

if (-not (Test-Path $LogPath -PathType Leaf)) {
    throw "Build log not found: $LogPath"
}

$total = 0
$warnings = 0
$families = @{}
# Streamed: chain logs run to hundreds of MB.
foreach ($line in [System.IO.File]::ReadLines((Resolve-Path $LogPath))) {
    $total++
    $family = Get-WarningFamily -Line $line
    if (-not $family) { continue }
    $warnings++
    if ($families.ContainsKey($family)) { $families[$family]++ } else { $families[$family] = 1 }
}

$pct = if ($total -gt 0) { [math]::Round(100.0 * $warnings / $total, 1) } else { 0 }
Write-Host ""
Write-Host "== $LogPath ==" -ForegroundColor Cyan
Write-Host ("{0,10:N0} lines total" -f $total)
Write-Host ("{0,10:N0} warning lines ({1} %) across {2:N0} famil{3}" -f `
        $warnings, $pct, $families.Count, $(if ($families.Count -eq 1) { 'y' } else { 'ies' }))

$ranked = $families.GetEnumerator() | Sort-Object -Property Value -Descending
if ($Top -gt 0) { $ranked = $ranked | Select-Object -First $Top }
Write-Host ""
foreach ($entry in $ranked) {
    Write-Host ("{0,8:N0}  {1}" -f $entry.Value, $entry.Key)
}

if ($Baseline) {
    # Pre-suppression counts; near-baseline means a later -W flag overrode the suppression or the group moved.
    $known = [ordered]@{
        '-Wdeprecated-copy'                = @{ Was = 7700; Where = 'OpenCV core/matx.hpp'; Flag = '-Wno-deprecated-copy (Build-OpencvFromSource.ps1)' }
        '-Wunused-value'                   = @{ Was = 2460; Where = 'ONNX stream_handles.h / execution_provider.h'; Flag = '/clang:-Wno-unused-value (Build-OnnxFromSource.ps1)' }
        '-Wdocumentation-unknown-command'  = @{ Was = 900; Where = 'TVM tvm/ffi/reflection/accessor.h'; Flag = '-Wno-documentation-unknown-command (Build-TvmFromSource.ps1)' }
        'STL4037'                          = @{ Was = 657; Where = 'IREE/MLIR BuiltinAttributes.h'; Flag = '_SILENCE_NONFLOATING_COMPLEX_DEPRECATION_WARNING (patches/iree/enable-ehsc.cmake)' }
    }
    Write-Host ""
    Write-Host "== known floods (baseline: 2026-08-07 chain, pre-suppression) ==" -ForegroundColor Cyan
    foreach ($name in $known.Keys) {
        $info = $known[$name]
        $now = if ($families.ContainsKey($name)) { $families[$name] } else { 0 }
        # clang reports the narrower subgroup, so it counts toward -Wdeprecated-copy.
        if ($name -eq '-Wdeprecated-copy' -and $families.ContainsKey('-Wdeprecated-copy-with-user-provided-copy')) {
            $now += $families['-Wdeprecated-copy-with-user-provided-copy']
        }
        $verdict, $colour = if ($now -eq 0) {
            'SILENCED', 'Green'
        } elseif ($now -lt [int]($info.Was * 0.1)) {
            'mostly silenced', 'Green'
        } else {
            'STILL FLOODING -- suppression did not take', 'Red'
        }
        Write-Host ("  {0,-34} {1,7:N0} -> {2,7:N0}  {3}" -f $name, $info.Was, $now, $verdict) -ForegroundColor $colour
        Write-Host ("  {0,-34} {1}" -f '', "$($info.Where); $($info.Flag)") -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host 'A family that is still flooding is a bug in the suppression, not a reason to reach for a blanket -w.' -ForegroundColor DarkGray
}
