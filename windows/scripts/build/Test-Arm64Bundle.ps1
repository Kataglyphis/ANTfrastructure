#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Runs the shipped Windows arm64 bundle's tools and Python on an arm64 device.
.DESCRIPTION
    The cross lane proves the bundle statically (PE machine, import walk); this is the device
    half and the only check that says the bundle EXECUTES. Every step checks its exit code and
    the run must pass -MinPassed, so a device that ran nothing cannot look green.
    See docs/windows-cross-builds.md § Verification.
.PARAMETER BundleRoot
    The bundle root whose BUNDLE-ENV.ps1 is sourced. Defaults to C:\runtime.
.PARAMETER ZipPath
    Optional bundle zip; extracted into the root when it has no python.exe yet.
.PARAMETER MinPassed
    Minimum passing steps for the run to count; 0 needs -AllowEmptyRun.
.PARAMETER AllowEmptyRun
    Permits -MinPassed 0, for probing a partial tree.
.EXAMPLE
    .\Test-Arm64Bundle.ps1 -ZipPath C:\temp\winarm64-bundle.zip -MinPassed 9
#>
[CmdletBinding()]
param(
    [string]$BundleRoot = 'C:\runtime',
    [string]$ZipPath = '',
    [int]$MinPassed = 9,
    [switch]$AllowEmptyRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

function Get-BundleVerdict {
    # The floor and the failures decide together; printed output never does.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results,
        [Parameter(Mandatory)][int]$MinPassed,
        [switch]$AllowEmptyRun
    )
    $passed = @($Results | Where-Object { $_.Ok }).Count
    $failed = @($Results | Where-Object { -not $_.Ok }).Count
    if ($MinPassed -le 0 -and -not $AllowEmptyRun) { throw 'MinPassed 0 needs -AllowEmptyRun' }
    if ($failed -gt 0) { return @{ Ok = $false; Passed = $passed; Failed = $failed; Reason = "$failed step(s) failed" } }
    if ($passed -lt $MinPassed) { return @{ Ok = $false; Passed = $passed; Failed = $failed; Reason = "passed $passed, floor $MinPassed" } }
    return @{ Ok = $true; Passed = $passed; Failed = $failed; Reason = '' }
}

function Invoke-BundleStep {
    # Records one step by exit code; a throw is a failure too, never a crash of the run.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body,
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Results
    )
    Write-Host "`n== $Name"
    $global:LASTEXITCODE = 0
    $detail = ''
    try { & $Body } catch { $detail = $_.Exception.Message }
    if (-not $detail -and $LASTEXITCODE -ne 0) { $detail = "exit $LASTEXITCODE" }
    $ok = -not $detail
    Write-Host ("   {0}{1}" -f $(if ($ok) { 'ok' } else { 'FAIL' }), $(if ($detail) { ": $detail" } else { '' }))
    $Results.Add([pscustomobject]@{ Name = $Name; Ok = $ok; Detail = $detail })
}

if ($MyInvocation.InvocationName -eq '.') { return }

if ($ZipPath -and -not (Test-Path (Join-Path $BundleRoot 'python\python.exe'))) {
    Write-Host "== extracting $ZipPath"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('arm64bundle-' + [guid]::NewGuid().ToString('N'))
    Expand-Archive -Path $ZipPath -DestinationPath $tmp -Force
    New-Item -ItemType Directory -Force -Path $BundleRoot | Out-Null
    $children = @(Get-ChildItem $tmp)
    if ($children.Count -eq 1 -and $children[0].PSIsContainer) { Move-Item $children[0].FullName $BundleRoot -Force }
    else { Move-Item (Join-Path $tmp '*') $BundleRoot -Force }
    Remove-Item $tmp -Recurse -Force
}

$py = Join-Path $BundleRoot 'python\python.exe'
if (-not (Test-Path $py)) { throw "no bundle python at $py - pass -ZipPath or point -BundleRoot at the bundle" }
. (Join-Path $BundleRoot 'BUNDLE-ENV.ps1')

$results = [System.Collections.Generic.List[object]]::new()
Invoke-BundleStep 'gio-querymodules (GIO module cache)' { & (Join-Path $BundleRoot 'bin\gio-querymodules.exe') (Join-Path $BundleRoot 'lib\gio\modules') } $results
Invoke-BundleStep 'hailortcli --version' { & (Join-Path $BundleRoot 'hailo\bin\hailortcli.exe') --version } $results
Invoke-BundleStep 'gst-inspect-1.0 --version' { & (Join-Path $BundleRoot 'bin\gst-inspect-1.0.exe') --version } $results
Invoke-BundleStep 'gst-launch pipeline (videotestsrc -> fakesink)' { & (Join-Path $BundleRoot 'bin\gst-launch-1.0.exe') -q videotestsrc num-buffers=1 '!' fakesink } $results
Invoke-BundleStep 'iree-run-module --help' { & (Join-Path $BundleRoot 'iree\bin\iree-run-module.exe') --help | Out-Null } $results
Invoke-BundleStep 'python ensurepip' { & $py -m ensurepip | Out-Null } $results
Invoke-BundleStep 'pip install from the wheel store (offline)' { & $py -m pip install --quiet --disable-pip-version-check --no-index --find-links (Join-Path $BundleRoot 'wheels') onnxruntime onnxruntime-genai-directml av } $results
Invoke-BundleStep 'python imports + ORT providers' {
    & $py -c "import sys, numpy, onnxruntime, av; print('PY', sys.version.split()[0], '| numpy', numpy.__version__, '| ort', onnxruntime.__version__, '| av', av.__version__); print('providers:', onnxruntime.get_available_providers()); assert 'CPUExecutionProvider' in onnxruntime.get_available_providers()"
} $results
Invoke-BundleStep 'cv2 import' { & $py -c "import cv2; print('cv2', cv2.__version__)" } $results

$verdict = Get-BundleVerdict -Results $results -MinPassed $MinPassed -AllowEmptyRun:$AllowEmptyRun
Write-Host "`n==== SUMMARY ===="
$results | ForEach-Object { Write-Host ("  {0} {1}" -f $(if ($_.Ok) { 'PASS' } else { 'FAIL' }), $_.Name) }
Write-Host ("  {0} passed, {1} failed (floor {2})" -f $verdict.Passed, $verdict.Failed, $MinPassed)
if (-not $verdict.Ok) { Write-Host "ARM64 BUNDLE SMOKE FAIL: $($verdict.Reason)"; exit 1 }
Write-Host 'ARM64 BUNDLE SMOKE PASS'
