#requires -Version 7.0
<#
.SYNOPSIS
    Removes the dead trees from the sccache cache mount, keeping v2 and the inheritance fixtures.
.DESCRIPTION
    Runs inside Dockerfile.cache-mount-clean to see the real mount, and prints each entry's size before deleting it.
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
    # Bound first: Measure-Object emits nothing for an empty dir, and .Sum then throws under StrictMode.
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
