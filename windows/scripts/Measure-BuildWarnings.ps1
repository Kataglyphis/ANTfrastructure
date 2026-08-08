# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Count compiler warnings in a build log, grouped by diagnostic family.

.DESCRIPTION
    Written because 16 % of one chain's build log (72 864 of 459 061 lines) was
    upstream compiler warnings, and four families accounted for nearly all of
    it. That is not merely untidy: buildkitd clips each RUN step's log at 2 MiB
    and then DEADLOCKS the step (see docs/windows-builds.md, § BuildKit lane),
    which is why BUILDKIT_STEP_LOG_MAX_SIZE=-1 is a required host setting. A
    real failure signal also hides badly among ~73 000 warnings.

    Targeted -Wno- suppressions were added for those four families. This script
    exists so the next run can PROVE each one still earns its place, instead of
    the suppressions becoming folklore nobody dares remove. Run it against a
    build log and compare with -Baseline.

.PARAMETER LogPath
    Build log to analyse. Accepts the raw buildctl/nerdctl output.

.PARAMETER Top
    How many families to list (default 15). 0 lists all.

.PARAMETER Baseline
    Also print the four known floods with their pre-suppression counts and a
    verdict per family. This is the mode to use after a chain rebuild.

.EXAMPLE
    .\Measure-BuildWarnings.ps1 -LogPath .\logs\chain.log -Baseline
#>

param(
    [Parameter(Mandatory)][string]$LogPath,
    [int]$Top = 15,
    [switch]$Baseline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WarningFamily {
    <#
    Reduce one log line to a diagnostic-family key, or $null when the line is
    not a warning.

    Two shapes matter here:
      clang-cl  ...: warning: <text> [-Wunused-value]
      MSVC STL  ...: warning STL4037: <text>
      MSVC      ...: warning C4996: <text>

    The clang form is keyed by its bracketed group because that is exactly what
    a -Wno- flag switches off -- keying by message text would split one family
    across every distinct wording. Bracket-less clang warnings fall back to a
    normalised message, so they are not silently dropped from the totals.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    if ($Line -match 'warning\s+(STL\d+|C\d{4,5})\s*:') { return $Matches[1] }
    if ($Line -notmatch 'warning:') { return $null }
    if ($Line -match '\[(-W[a-z0-9-]+)\]\s*$') { return $Matches[1] }

    # No group: normalise the message so near-identical texts collapse. Quoted
    # identifiers and numbers are the parts that vary between otherwise
    # identical diagnostics.
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
# Stream the file: chain logs run to hundreds of MB and Get-Content -Raw on one
# would be a needless several-GB allocation.
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
    # Measured on the 2026-08-07 from-base chain, BEFORE the suppressions landed
    # on 2026-08-08. A family at or near its baseline means its suppression did
    # not take -- most likely the flag reached the compiler but was overridden
    # by a later -W flag from the project's own warning machinery, or the
    # upstream construct moved to a different diagnostic group.
    $known = [ordered]@{
        '-Wdeprecated-copy'                = @{ Was = 7700; Where = 'OpenCV core/matx.hpp'; Flag = '-Wno-deprecated-copy (build-opencv-from-source.ps1)' }
        '-Wunused-value'                   = @{ Was = 2460; Where = 'ONNX stream_handles.h / execution_provider.h'; Flag = '/clang:-Wno-unused-value (build-onnx-from-source.ps1)' }
        '-Wdocumentation-unknown-command'  = @{ Was = 900; Where = 'TVM tvm/ffi/reflection/accessor.h'; Flag = '-Wno-documentation-unknown-command (build-tvm-from-source.ps1)' }
        'STL4037'                          = @{ Was = 657; Where = 'IREE/MLIR BuiltinAttributes.h'; Flag = '_SILENCE_NONFLOATING_COMPLEX_DEPRECATION_WARNING (patches/iree/enable-ehsc.cmake)' }
    }
    Write-Host ""
    Write-Host "== known floods (baseline: 2026-08-07 chain, pre-suppression) ==" -ForegroundColor Cyan
    foreach ($name in $known.Keys) {
        $info = $known[$name]
        $now = if ($families.ContainsKey($name)) { $families[$name] } else { 0 }
        # -Wdeprecated-copy is a parent group; clang reports the narrower
        # subgroup in the bracket, so count that toward the same family.
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
