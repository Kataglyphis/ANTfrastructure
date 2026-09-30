#requires -Version 7.0
<#
.SYNOPSIS
    Separates a build log's five known noise warning classes from the signal classes they bury.
.DESCRIPTION
    Exits 0 unless the log is missing; the output is the product.
.PARAMETER LogPath
    A build log with clang-cl or MSVC warning lines.
.PARAMETER Top
    How many warning classes to list in the frequency table.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LogPath,
    [int]$Top = 15
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $LogPath)) { throw "analyze-warning-stream: log not found: $LogPath" }

# Data, so a new class costs one line and the summary can explain itself.
$signalClasses = [ordered]@{
    '-Winconsistent-missing-override' = 'vtable/ABI: override without the keyword — breaks when the base changes'
    '-Wundefined-var-template'        = 'ODR/link hazard: instantiation without a definition'
    '-Winconsistent-dllimport'        = 'Windows linkage: dllimport/dllexport mismatch'
    '-Winfinite-recursion'            = 'runaway recursion (see backlog #73)'
    'C4715'                           = 'UB: not all control paths return a value'
    '-Wunused-command-line-argument'  = 'config smell: a flag the compiler ignores (e.g. /Zc:preprocessor under clang-cl)'
}
$noiseClasses = @(
    '-Wunused-parameter', '-Wdocumentation-unknown-command', '-Wdeprecated-copy',
    '-Wundef', '-Wmissing-field-initializers'
)

$counts = @{}
$signalHits = [System.Collections.Generic.List[string]]::new()
$totalWarnings = 0

# Stream, do not slurp: run logs reach 34 MB.
Get-Content -LiteralPath $LogPath -ReadCount 2000 | ForEach-Object {
    foreach ($line in $_) {
        # clang-cl: `... warning: ... [-Wclass]`   MSVC: `... warning C4715: ...`
        if ($line -match 'warning:.*\[(-W[a-z0-9-]+)\]') {
            $cls = $Matches[1]
        } elseif ($line -match 'warning (C\d{4}):') {
            $cls = $Matches[1]
        } else { continue }
        $totalWarnings++
        $counts[$cls] = 1 + $(if ($counts.ContainsKey($cls)) { $counts[$cls] } else { 0 })
        if ($signalClasses.Contains($cls) -and $signalHits.Count -lt 400) {
            # Strip the BuildKit `#N t.t ` prefix so file:line survives compactly.
            $signalHits.Add(($line -replace '^#\d+\s+[\d.]+\s*', '').Trim())
        }
    }
}

Write-Host "=== warning stream: $LogPath ==="
Write-Host ("total warnings: {0}  distinct classes: {1}" -f $totalWarnings, $counts.Count)
if ($totalWarnings -eq 0) { Write-Host '(no compiler warnings recognized — wrong log?)'; exit 0 }

$noiseTotal = 0
foreach ($n in $noiseClasses) { foreach ($k in @($counts.Keys)) { if ($k -like "$n*") { $noiseTotal += $counts[$k] } } }
Write-Host ("noise (top-5 classes): {0} = {1:P1} of the stream" -f $noiseTotal, ($noiseTotal / $totalWarnings))

Write-Host "`n--- frequency (top $Top) ---"
$counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Top | ForEach-Object {
    $tag = if ($signalClasses.Contains($_.Key)) { ' <-- SIGNAL' }
    elseif ($noiseClasses | Where-Object { $_.Key -like "$_*" }) { '' } else { '' }
    Write-Host ("  {0,8:N0}  {1}{2}" -f $_.Value, $_.Key, $tag)
}

Write-Host "`n--- signal classes ---"
foreach ($cls in $signalClasses.Keys) {
    $c = if ($counts.ContainsKey($cls)) { $counts[$cls] } else { 0 }
    Write-Host ("  {0,8:N0}  {1,-34} {2}" -f $c, $cls, $signalClasses[$cls])
}

if ($signalHits.Count -gt 0) {
    Write-Host "`n--- first signal occurrences (deduped by file:line, up to 40) ---"
    $signalHits | ForEach-Object { ($_ -split ' ')[0] } | Select-Object -Unique -First 40 | ForEach-Object { Write-Host "  $_" }
}
exit 0
