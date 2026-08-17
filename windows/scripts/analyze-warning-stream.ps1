#requires -Version 7.0
<#
.SYNOPSIS
    Classify a build log's compiler-warning stream: separate the five known
    noise classes from the signal classes they bury (backlog #80).

.DESCRIPTION
    Corpus measurement behind this tool (49 runs): 96 % of all warnings were
    five noise classes (-Wunused-parameter alone: 68,502), hiding 1,055 genuine
    signals — vtable/ABI breaks (-Winconsistent-missing-override), ODR/link
    hazards (-Wundefined-var-template), Windows linkage
    (-Winconsistent-dllimport), runaway recursion (-Winfinite-recursion) and
    C4715 (undefined behaviour: falling off a value-returning function).

    This is the OBSERVABILITY half of #80: it makes any existing log readable
    in seconds. The other half — suppressing the noise classes at build-script
    level so the volume never exists — touches the bind-mounted build scripts
    and lands separately.

    Diagnostic: exits 0 unless the log is missing; its output is the product.

.PARAMETER LogPath
    A build log (driver stage log or Tee'd run log). Anything with clang-cl /
    MSVC warning lines works.

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

# The classes worth acting on, with WHY. Kept as data so the next class costs
# one line, and so the summary can explain itself.
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
