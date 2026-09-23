# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    rocm image: the app venv runs AMD's ROCm torch/torchvision for ROCM_WINDOWS_RELEASE.
.DESCRIPTION
    Writes one finding per gap; nothing means pass. It imports torch and reads versions and
    dist metadata only, so no GPU is needed. NOT covered: that a HIP kernel runs, and
    torch.cuda.is_available() (False without a device). docs/windows-builds.md § ROCm layer.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The probe prints one JSON line; an import error is reported in it, never raised.
# "venv" is read before any import: Install-TorchRocm.ps1 checks the pins against it.
function Get-TorchRocmProbeSource {
    return @'
import contextlib, importlib.metadata as md, io, json, sys, sysconfig
def version(dist):
    try:
        return md.version(dist)
    except md.PackageNotFoundError:
        return ""
gil = "t" if sysconfig.get_config_var("Py_GIL_DISABLED") else ""
report = {"venv": {"tag": "cp%d%d%s" % (sys.version_info[0], sys.version_info[1], gil),
                   "torch": version("torch"), "torchvision": version("torchvision"),
                   "setuptools": version("setuptools")}}
err = io.StringIO()
try:
    with contextlib.redirect_stderr(err):
        import torch, torchvision, rocm_sdk
    report.update(torch=torch.__version__, hip=torch.version.hip, rocm=torch.version.rocm,
                  torchvision=torchvision.__version__, rocm_sdk=rocm_sdk.__version__)
except Exception as exc:
    report["error"] = "%s: %s" % (type(exc).__name__, exc)
report["dists"] = {(d.metadata["Name"] or "").lower(): d.version for d in md.distributions()
                   if (d.metadata["Name"] or "").lower().startswith(("amd-torch", "rocm"))}
report["stderr"] = err.getvalue()[-2000:]
print(json.dumps(report))
'@
}

# $Report is the probe's JSON as a hashtable (ConvertFrom-Json -AsHashtable).
function Get-TorchRocmFinding {
    param([AllowNull()][hashtable]$Report, [AllowEmptyString()][string]$Release)
    if (-not $Release) { return 'Torch: ROCM_WINDOWS_RELEASE is not set - cannot tell which ROCm torch to expect' }
    if ($null -eq $Report) { return 'Torch: the app venv python printed no report' }
    if ($Report['error']) { return "Torch: importing torch/torchvision/rocm_sdk failed: $($Report['error'])" }
    $suffix = "+rocm$Release"
    foreach ($pkg in 'torch', 'torchvision') {
        if (-not "$($Report[$pkg])".EndsWith($suffix)) { "Torch: $pkg is '$($Report[$pkg])', expected a '$suffix' build" }
    }
    if (-not $Report['hip']) { 'Torch: torch.version.hip is empty - this is not a HIP build of torch' }
    if ("$($Report['rocm'])" -ne $Release) { "Torch: torch.version.rocm is '$($Report['rocm'])', ROCM_WINDOWS_RELEASE is '$Release'" }
    if ("$($Report['rocm_sdk'])" -ne $Release) { "Torch: rocm_sdk is '$($Report['rocm_sdk'])', ROCM_WINDOWS_RELEASE is '$Release'" }
    $dists = if ($Report['dists'] -is [System.Collections.IDictionary]) { $Report['dists'] } else { @{} }
    foreach ($dist in 'rocm', 'rocm-sdk-core', 'rocm-sdk-libraries') {
        if ("$($dists[$dist])" -ne $Release) { "Torch: dist $dist is '$($dists[$dist])', expected $Release" }
    }
    if (-not $dists.Contains('rocm-bootstrap')) { 'Torch: dist rocm-bootstrap is missing (torch requires it)' }
    # Device wheels carry the GPU kernels; each family must match the package it extends.
    $want = @(
        @{ Prefix = 'rocm-sdk-device-'; Version = $Release }
        @{ Prefix = 'amd-torch-device-'; Version = "$($Report['torch'])" }
        @{ Prefix = 'amd-torchvision-device-'; Version = "$($Report['torchvision'])" }
    )
    foreach ($w in $want) {
        $found = @($dists.Keys | Where-Object { $_.StartsWith($w.Prefix) })
        if ($found.Count -eq 0) { "Torch: no $($w.Prefix)* dist: the venv carries no GPU kernels" }
        foreach ($name in $found) {
            if ("$($dists[$name])" -ne $w.Version) { "Torch: dist $name is '$($dists[$name])', expected '$($w.Version)'" }
        }
    }
}

# The one runner of the probe (Install-TorchRocm.ps1 dot-sources this file for it); throws without a report.
function Get-TorchRocmVenvReport {
    param([Parameter(Mandatory)][string]$Python)
    $probe = Join-Path ([System.IO.Path]::GetTempPath()) "rocm-check-torch-$([guid]::NewGuid().ToString('N')).py"
    try {
        [System.IO.File]::WriteAllText($probe, (Get-TorchRocmProbeSource))
        $lines = @(& $Python $probe 2>$null)
        $rc = $LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    }
    $json = $lines | Where-Object { "$_".StartsWith('{') } | Select-Object -Last 1
    if ($rc -ne 0 -or -not $json) { throw "the venv probe exited $rc without a report" }
    return ($json | ConvertFrom-Json -AsHashtable)
}

# Dot-sourced = definitions only; Test-RocmImage.ps1 runs it with &.
if ($MyInvocation.InvocationName -eq '.') { return }

$appDir = if ($env:TORCH_APP_DIR) { $env:TORCH_APP_DIR } else { 'C:\opt\OrchestrANT' }
$python = Join-Path $appDir '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    "Torch: app venv python not found at $python"
    return
}
try {
    $report = Get-TorchRocmVenvReport -Python $python
} catch {
    "Torch: $($_.Exception.Message)"
    return
}
Write-Host "  torch $($report['torch']) hip $($report['hip']) torchvision $($report['torchvision']) ($(if ($report['venv']) { $report['venv']['tag'] }))"
Get-TorchRocmFinding -Report $report -Release "$env:ROCM_WINDOWS_RELEASE"
