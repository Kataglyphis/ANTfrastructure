# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    rocm image: the app venv runs AMD's ROCm torch/torchvision (kernels for every rocBLAS GPU) and ai-edge-litert.
.DESCRIPTION
    One finding per gap, GPU-less (imports, dist metadata, the LiteRT accelerator load); NOT covered: a kernel
    running. The chain ORT's WebGPU EP is OrtWebGpu.ps1's. docs/windows-rocm.md § PyTorch on the rocm lane.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The probe prints one JSON line; an import error is reported in it, never raised.
# "venv" is read before any import: Install-TorchRocm.ps1 checks the pins against it.
function Get-TorchRocmProbeSource {
    return @'
import contextlib, ctypes, hashlib, importlib.metadata as md, io, json, os, re, sys, sysconfig
def version(dist):
    try:
        return md.version(dist)
    except md.PackageNotFoundError:
        return ""
def record_digest(dist):
    try:
        text = md.distribution(dist).read_text("RECORD") or ""
    except md.PackageNotFoundError:
        return ""
    return hashlib.sha256(text.encode()).hexdigest() if text else ""
def unmet(dist):
    names = [re.match(r"\s*([A-Za-z0-9._-]+)", r).group(1) for r in (md.requires(dist) or []) if ";" not in r]
    return [n for n in names if not version(n)]
gil = "t" if sysconfig.get_config_var("Py_GIL_DISABLED") else ""
report = {"venv": {"tag": "cp%d%d%s" % (sys.version_info[0], sys.version_info[1], gil),
                   "torch": version("torch"), "torchvision": version("torchvision"),
                   "setuptools": version("setuptools"), "onnxruntime": version("onnxruntime"),
                   "onnxruntime_record": record_digest("onnxruntime")}}
err = io.StringIO()
try:
    with contextlib.redirect_stderr(err):
        import torch, torchvision, rocm_sdk
    report.update(torch=torch.__version__, hip=torch.version.hip, rocm=torch.version.rocm,
                  torchvision=torchvision.__version__, rocm_sdk=rocm_sdk.__version__)
except Exception as exc:
    report["error"] = "%s: %s" % (type(exc).__name__, exc)
ort_facts = {}
try:
    with contextlib.redirect_stderr(err):
        import onnxruntime as ort
        ort_facts["dml"] = "DmlExecutionProvider" in ort.get_available_providers()
except Exception as exc:
    ort_facts["error"] = "import onnxruntime: %s: %s" % (type(exc).__name__, exc)
report["ort"] = ort_facts
lite, step = {}, "import ai_edge_litert.interpreter"
try:
    with contextlib.redirect_stderr(err):
        import ai_edge_litert, ai_edge_litert.interpreter as tfl
        lite.update(version=version("ai-edge-litert"), unmet=unmet("ai-edge-litert"), interpreter=hasattr(tfl, "Interpreter"))
        step = "load libLiteRtWebGpuAccelerator.dll"
        path = os.path.join(os.path.dirname(ai_edge_litert.__file__), "libLiteRtWebGpuAccelerator.dll")
        lite["accelerator"] = path if os.path.isfile(path) else ""
        if lite["accelerator"]:
            lite["accelerator_entry"] = hasattr(ctypes.WinDLL(path), "LiteRtAcceleratorImpl")
except Exception as exc:
    lite["error"] = "%s: %s: %s" % (step, type(exc).__name__, exc)
report["litert"] = lite
report["dists"] = {(d.metadata["Name"] or "").lower(): d.version for d in md.distributions()
                   if (d.metadata["Name"] or "").lower().startswith(("amd-torch", "rocm"))}
report["stderr"] = err.getvalue()[-2000:]
print(json.dumps(report))
'@
}

# The GPUs ROCm's rocBLAS ships kernels for; rocm-checks\LlamaCpp.ps1 grades ggml-hip against the same files.
function Get-TorchRocmRocblasGpu {
    param([Parameter(Mandatory)][string]$RocblasLibraryDir)
    try { $paths = [System.IO.Directory]::GetFiles($RocblasLibraryDir, 'TensileLibrary_lazy_*') }
    catch [System.IO.DirectoryNotFoundException] { return @() }
    $gpu = foreach ($path in $paths) {
        $lazy = [regex]::Match([System.IO.Path]::GetFileName($path), '^TensileLibrary_lazy_(gfx[0-9a-z]+)\.dat$')
        if ($lazy.Success) { $lazy.Groups[1].Value }
    }
    return @($gpu | Sort-Object -Unique)
}

# One section of the probe's report; a missing or malformed one reads as empty.
function Get-TorchRocmReportSection {
    param([Parameter(Mandatory)][hashtable]$Report, [Parameter(Mandatory)][string]$Name)
    $section = $Report[$Name]
    if ($section -is [System.Collections.IDictionary]) { return $section }
    return @{}
}

# The venv's extras: the chain ORT (its DML EP is what PyPI's wheels lack) and the --no-deps ai-edge-litert.
function Get-TorchRocmExtraFinding {
    param([Parameter(Mandatory)][hashtable]$Report)
    $ort = Get-TorchRocmReportSection -Report $Report -Name 'ort'
    $lite = Get-TorchRocmReportSection -Report $Report -Name 'litert'
    if ($ort['error']) { "Torch: the venv's onnxruntime: $($ort['error'])" }
    elseif (-not $ort['dml']) { "Torch: the venv's onnxruntime lists no DmlExecutionProvider: it is not the chain's CPU+DML wheel" }
    if ($lite['error']) { "Torch: ai-edge-litert: $($lite['error'])" }
    elseif (-not $lite['interpreter']) { 'Torch: ai-edge-litert: ai_edge_litert.interpreter has no Interpreter' }
    elseif (-not $lite['accelerator']) { 'Torch: ai-edge-litert ships no libLiteRtWebGpuAccelerator.dll: its WebGPU path is gone' }
    elseif (-not $lite['accelerator_entry']) { 'Torch: libLiteRtWebGpuAccelerator.dll loaded without its LiteRtAcceleratorImpl export' }
    foreach ($name in @($lite['unmet'] | Where-Object { $_ })) { "Torch: ai-edge-litert is installed --no-deps and the venv lacks its requirement $name" }
}

# $Report is the probe's JSON as a hashtable (ConvertFrom-Json -AsHashtable).
function Get-TorchRocmFinding {
    param(
        [AllowNull()][hashtable]$Report,
        [AllowEmptyString()][string]$Release,
        # Get-TorchRocmRocblasGpu's set: each GPU needs its rocm-sdk, torch and torchvision device dists.
        [AllowEmptyCollection()][string[]]$RocmGpu = @()
    )
    if (-not $Release) { return 'Torch: ROCM_WINDOWS_RELEASE is not set - cannot tell which ROCm torch to expect' }
    if ($null -eq $Report) { return 'Torch: the app venv python printed no report' }
    Get-TorchRocmExtraFinding -Report $Report
    if ($Report['error']) { return "Torch: importing torch/torchvision/rocm_sdk failed: $($Report['error'])" }
    $suffix = "+rocm$Release"
    foreach ($pkg in 'torch', 'torchvision') {
        if (-not "$($Report[$pkg])".EndsWith($suffix)) { "Torch: $pkg is '$($Report[$pkg])', expected a '$suffix' build" }
    }
    if (-not $Report['hip']) { 'Torch: torch.version.hip is empty - this is not a HIP build of torch' }
    if ("$($Report['rocm'])" -ne $Release) { "Torch: torch.version.rocm is '$($Report['rocm'])', ROCM_WINDOWS_RELEASE is '$Release'" }
    if ("$($Report['rocm_sdk'])" -ne $Release) { "Torch: rocm_sdk is '$($Report['rocm_sdk'])', ROCM_WINDOWS_RELEASE is '$Release'" }
    $dists = Get-TorchRocmReportSection -Report $Report -Name 'dists'
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
        foreach ($gfx in $RocmGpu) {
            if (-not $dists.Contains("$($w.Prefix)$gfx")) { "Torch: no $($w.Prefix)$gfx dist: ROCm's rocBLAS serves $gfx, the venv has no kernels for it" }
        }
    }
    # Not .Count: an empty set that an `if` unwrapped binds as $null, and StrictMode throws on $null.Count.
    if (-not $RocmGpu) { "Torch: ROCm's rocBLAS names no GPU (no TensileLibrary_lazy_gfx*.dat): cannot tell which device wheels the venv needs" }
}

# The check past the probe: the rocBLAS GPU set under $RocmRoot (none when unset or missing), then the findings.
function Get-TorchRocmImageFinding {
    param([Parameter(Mandatory)][hashtable]$Report, [AllowEmptyString()][string]$Release, [AllowEmptyString()][string]$RocmRoot)
    $rocmGpu = @(if ($RocmRoot) { Get-TorchRocmRocblasGpu -RocblasLibraryDir (Join-Path $RocmRoot 'bin\rocblas\library') })
    Write-Host "  torch $($Report['torch']) hip $($Report['hip']) torchvision $($Report['torchvision']) ($(if ($Report['venv']) { $Report['venv']['tag'] })); rocBLAS GPUs: $($rocmGpu -join ', ')"
    Get-TorchRocmFinding -Report $Report -Release $Release -RocmGpu $rocmGpu
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
$rocmRoot = if ($env:HIP_PATH) { $env:HIP_PATH } else { "$env:ROCM_PATH" }
Get-TorchRocmImageFinding -Report $report -Release "$env:ROCM_WINDOWS_RELEASE" -RocmRoot $rocmRoot
