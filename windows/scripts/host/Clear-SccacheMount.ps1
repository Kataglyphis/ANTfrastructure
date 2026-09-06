#requires -Version 7.0
<#
.SYNOPSIS
    Remove the dead weight from the sccache cache mount (backlog #104).

.DESCRIPTION
    The mount accumulated ~200 MiB no build will ever read again:
      * the ORIGINAL root tree (buckets 0..f + preprocessor at the mount root) —
        the #99 corpse: path-dependently damaged by BuildKit's WCOW
        inherited-write defect, abandoned when SCCACHE_DIR moved to \v2;
      * v3 (empty; experiment A/B leftover) and v4 (experiment B, ~63 MiB);
      * assorted probe temp dirs.
    KEPT deliberately:
      * v2 — the referenced SCCACHE_DIR (dormant under WebDAV-only, but it is
        the live target the day the disk tier returns);
      * probe-persist and bulk-inherit — the #99 inheritance fixtures, held
        until the BuildKit upstream report is filed (they ARE the repro).
    Prints per-entry sizes BEFORE deleting: never discard evidence silently.

    Runs INSIDE a probe container (see Dockerfile.cache-mount-clean) so it sees
    the real mount. Exits non-zero on unexpected layout — a cleanup that
    guesses is how the probe once deleted its own experiment.

.PARAMETER Nonce
    Layer-cache buster from the Dockerfile ARG; echoed only.
#>
[CmdletBinding()]
param(
    [string]$CacheDir = 'C:\sccache',
    [string]$Nonce = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Write-Host "=== sccache mount cleanup (#104) nonce=$Nonce ==="

if (-not (Test-Path $CacheDir)) { throw "cache mount not present at $CacheDir - wrong invocation (needs the probe Dockerfile's mount)" }

$keep = @('v2', 'probe-persist', 'bulk-inherit')
$entries = @(Get-ChildItem $CacheDir -Force -ErrorAction Stop)
Write-Host "mount root holds $($entries.Count) entr(y|ies); keeping: $($keep -join ', ')"

$totalFreed = 0L
foreach ($e in $entries) {
    # Bound first: Measure-Object with -Property emits NOTHING for empty input, so
    # the inline .Sum throws under StrictMode on an empty dir (v3 is exactly that).
    $size = if ($e.PSIsContainer) {
        $m = Get-ChildItem $e.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum
        if ($m) { $m.Sum } else { 0 }
    } else { $e.Length }
    if ($null -eq $size) { $size = 0 }
    if ($keep -contains $e.Name) {
        Write-Host ("  KEEP   {0,-16} {1,12:N0} bytes" -f $e.Name, $size)
        continue
    }
    Write-Host ("  DELETE {0,-16} {1,12:N0} bytes" -f $e.Name, $size)
    Remove-Item -LiteralPath $e.FullName -Recurse -Force -ErrorAction Stop
    $totalFreed += $size
}

Write-Host ("freed {0:N1} MiB from the shared tier-0 budget" -f ($totalFreed / 1MB))
Write-Host "remaining:"
Get-ChildItem $CacheDir -Force | ForEach-Object { Write-Host "  $($_.Name)" }
Write-Host "=== cleanup complete ==="
