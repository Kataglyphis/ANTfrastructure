#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    #54 (re-scoped): which staged CUDA/cuDNN runtime DLLs does the merge
    image ACTUALLY need? The flatten copies every *.dll under CUDA bin +
    CUDNN_ROOT; the consumers (gst opencv plugin, cv2, opencv_* CUDA DLLs,
    onnxruntime) may need only a subset - report the unused tail + sizes.

.DESCRIPTION
    Recursive dumpbin walk (GStreamer plugin-LOAD gate recipe) from every
    consumer DLL, collecting the transitive closure of names resolvable in
    C:\runtime\cuda-runtime\bin; everything staged but NOT in the closure is
    trim candidate, listed largest-first. Fail-open reporting only - no
    image change here.
#>
[CmdletBinding()]
param(
    [string]$Nonce = ''
)
$ErrorActionPreference = 'Stop'
Write-Host "=== cuda-runtime closure probe nonce=$Nonce ==="

$rtBin = 'C:\runtime\cuda-runtime\bin'
if (-not (Test-Path $rtBin)) { throw "$rtBin missing - wrong base image?" }
$staged = @{}
Get-ChildItem $rtBin -Filter '*.dll' -File | ForEach-Object { $staged[$_.Name.ToLower()] = $_.Length }
Write-Host ("staged: {0} DLLs, {1:N0} MB total" -f $staged.Count, ((($staged.Values | Measure-Object -Sum).Sum) / 1MB))

# Consumers: everything plausibly loading CUDA at runtime in this image.
$consumers = @()
$consumers += Get-ChildItem 'C:\runtime\lib\opencv5' -Recurse -Include 'opencv_*.dll', '*.pyd' -File -ErrorAction SilentlyContinue
$consumers += Get-ChildItem 'C:\runtime\lib\gstreamer' -Recurse -Filter 'gst*.dll' -File -ErrorAction SilentlyContinue
$consumers += Get-ChildItem 'C:\runtime\gstreamer' -Recurse -Filter '*.dll' -File -ErrorAction SilentlyContinue
$consumers += Get-ChildItem 'C:\runtime\lib\onnxruntime-source' -Recurse -Filter 'onnxruntime*.dll' -File -ErrorAction SilentlyContinue
$consumers += Get-ChildItem 'C:\temp\cpython\Lib\site-packages' -Recurse -Include 'cv2*.pyd', 'onnxruntime*.dll', '*providers*.dll' -File -ErrorAction SilentlyContinue
$consumers = @($consumers | Where-Object { $_ })
Write-Host ("consumers found: {0}" -f $consumers.Count)
if ($consumers.Count -eq 0) { throw 'no consumer DLLs found - path assumptions wrong' }

$dumpbin = (Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
if (-not $dumpbin) { throw 'dumpbin.exe not found' }

$needed = New-Object 'System.Collections.Generic.HashSet[string]'
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
$queue = [System.Collections.Queue]::new()
$consumers | ForEach-Object { $queue.Enqueue($_.FullName) }
while ($queue.Count -gt 0) {
    $item = $queue.Dequeue()
    if (-not $seen.Add([IO.Path]::GetFileName($item).ToLower())) { continue }
    $deps = @(& $dumpbin /dependents $item 2>&1 | Select-String '^\s{4,}(\S+\.dll)' | ForEach-Object { $_.Matches.Groups[1].Value.ToLower() })
    foreach ($dep in $deps) {
        if ($staged.ContainsKey($dep)) {
            if ($needed.Add($dep)) { $queue.Enqueue((Join-Path $rtBin $dep)) }
        }
    }
}

Write-Host ("closure: {0} of {1} staged DLLs are actually imported (transitively)" -f $needed.Count, $staged.Count)
$needed | Sort-Object | ForEach-Object { Write-Host ("  need| {0} ({1:N0} MB)" -f $_, ($staged[$_] / 1MB)) }
$unused = @($staged.Keys | Where-Object { -not $needed.Contains($_) } | Sort-Object { - $staged[$_] })
$unusedMb = (($unused | ForEach-Object { $staged[$_] }) | Measure-Object -Sum).Sum / 1MB
Write-Host ("TRIM CANDIDATES: {0} DLLs, {1:N0} MB reclaimable" -f $unused.Count, $unusedMb)
$unused | Select-Object -First 20 | ForEach-Object { Write-Host ("  trim| {0} ({1:N0} MB)" -f $_, ($staged[$_] / 1MB)) }
# CAVEAT for the consumer of this report: dumpbin sees STATIC imports only.
# Delay-loaded / LoadLibrary'd DLLs (nvrtc is a known dynamic load from
# opencv cudev; nvcuda.dll comes from the driver) do NOT show - cross-check
# trim candidates against known dynamic-load patterns before removing.
Write-Host 'probe complete'
