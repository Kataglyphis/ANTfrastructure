#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# The part of a staged TensorRT tree the image ships; see docs/windows-builds.md § TensorRT setup.
[CmdletBinding()]
param(
    # Set-TensorrtTree.ps1's root, holding current\.
    [string]$SdkRoot = 'C:\tensorrt',
    [string]$Destination = 'C:\tensorrt-runtime'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The SLA's distributable "runtime files .dll" that ORT's TensorRT EP links (nvinfer, nvonnxparser) or LoadLibrary()s (the rest).
$runtimeNames = @('^nvinfer_{0}\.dll$', '^nvinfer_plugin_{0}\.dll$', '^nvonnxparser_{0}\.dll$', '^nvinfer_builder_resource.*_{0}\.dll$')
# The notices travel with the DLLs; every other document stays behind with the SDK.
$licenseName = '(?i)(licen[cs]e|sla|acknowledg|notice|copyright)'

$null = New-Item -ItemType Directory -Force -Path $Destination
$sdk = Join-Path $SdkRoot 'current'
$dlls = @(foreach ($dir in 'bin', 'lib') {
        Get-ChildItem -LiteralPath (Join-Path $sdk $dir) -Filter '*.dll' -File -ErrorAction SilentlyContinue
    })
if ($dlls.Count -eq 0) {
    Write-Host "TensorRT: no runtime DLLs under '$sdk' -> nothing ships (no zip staged)."
    return
}
$major = @($dlls | ForEach-Object { if ($_.Name -match '^nvinfer_(\d+)\.dll$') { [int]$Matches[1] } } | Sort-Object -Descending)
if ($major.Count -eq 0) { throw "TensorRT tree '$sdk' has no nvinfer_<major>.dll; ORT's TensorRT EP cannot load it." }
$patterns = $runtimeNames | ForEach-Object { $_ -f $major[0] }
$keep = @($dlls | Where-Object { $n = $_.Name; @($patterns | Where-Object { $n -match $_ }).Count -gt 0 })
foreach ($p in $patterns) {
    if (-not @($keep | Where-Object Name -Match $p)) { throw "TensorRT tree '$sdk' has no DLL matching $p, which ORT's TensorRT EP loads." }
}

$bin = Join-Path $Destination 'current\bin'
$null = New-Item -ItemType Directory -Force -Path $bin
foreach ($f in $keep) { Copy-Item -LiteralPath $f.FullName -Destination $bin -Force }
$notices = @(Get-ChildItem -LiteralPath $sdk -File | Where-Object Name -Match $licenseName) +
    @(Get-ChildItem -LiteralPath (Join-Path $sdk 'doc') -Recurse -File -ErrorAction SilentlyContinue | Where-Object Name -Match $licenseName)
if ($notices.Count -gt 0) {
    $licenses = Join-Path $Destination 'current\licenses'
    $null = New-Item -ItemType Directory -Force -Path $licenses
    foreach ($f in $notices) { Copy-Item -LiteralPath $f.FullName -Destination $licenses -Force }
}

$left = @(Get-ChildItem -LiteralPath $sdk -Recurse -File).Count - $keep.Count - $notices.Count
Write-Host ("TensorRT {0}: ships {1} runtime DLLs ({2:N1} MB) and {3} licence texts; {4} SDK files stay in the build stage." -f
    $major[0], $keep.Count, (($keep | Measure-Object Length -Sum).Sum / 1MB), $notices.Count, $left)
$keep | ForEach-Object { Write-Host "  $($_.Name)" }
