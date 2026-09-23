#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# rocm image, OpenCV: the OpenCL T-API is compiled in and dynamically loaded, a usable OpenCL.dll
# resolves, and no build path reaches into the ROCm tree. No GPU needed. docs/windows-builds.md § ROCm layer

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Exit codes are read explicitly below; a non-zero one must become a finding (or info), never a throw.
$PSNativeCommandUseErrorActionPreference = $false

# Findings from cv2.getBuildInformation(): OpenCL YES, loaded dynamically, and no line naming the ROCm tree.
function Get-OcvRocmBuildInfoFinding {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$BuildInformation, [string]$RocmRoot = '')
    $lines = @($BuildInformation -split '\r?\n')
    $head = [Array]::FindIndex([string[]]$lines, [Predicate[string]] { param($l) $l -match '^\s*OpenCL:\s' })
    if ($head -lt 0 -or $lines[$head] -notmatch 'OpenCL:\s+YES\b') {
        'OpenCV: cv2.getBuildInformation() does not report "OpenCL: YES" - the OpenCL T-API is not compiled in'
    } else {
        # The OpenCL block's sub-items are the 4-space-indented lines right below it.
        $link = ''
        for ($i = $head + 1; $i -lt $lines.Count -and $lines[$i] -match '^\s{4,}\S'; $i++) {
            if ($lines[$i] -match '^\s*Link libraries:\s*(.*?)\s*$') { $link = $Matches[1] }
        }
        if ($link -ne 'Dynamic load') {
            "OpenCV: OpenCL links '$link' instead of 'Dynamic load' - an import library (TheRock's amdocl64.lib?) was bound at build time"
        }
    }
    if ($RocmRoot) {
        $pattern = '*' + [WildcardPattern]::Escape($RocmRoot.TrimEnd('\', '/').Replace('\', '/')) + '*'
        $lines | Where-Object { $_.Replace('\', '/') -like $pattern } |
            ForEach-Object { "OpenCV: a build-information line points into the ROCm tree: $($_.Trim())" }
    }
}

# Finding for the OpenCL.dll probe: OpenCV loads it by bare name and requires clEnqueueReadBufferRect.
function Get-OcvRocmOpenClLoaderFinding {
    param([int]$ExitCode, [AllowEmptyString()][string]$Output)
    $marker = @($Output -split '\r?\n' | Where-Object { $_ -match '^opencl-loader\|' }) | Select-Object -Last 1
    if ($ExitCode -ne 0 -or -not $marker) {
        $tail = @($Output -split '\r?\n' | Where-Object { $_.Trim() }) | Select-Object -Last 2
        return "OpenCV: no OpenCL.dll loads through the standard DLL search (exit $ExitCode): $($tail -join ' | ')"
    }
    $fields = @($marker.Split('|')) + @('', '')
    if ($fields[2] -ne 'True') { return "OpenCV: '$($fields[1])' lacks clEnqueueReadBufferRect (OpenCL 1.1+), so OpenCV rejects it" }
}

$python = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $python) {
    'OpenCV: python is not on PATH - cv2 cannot be checked'
    return
}
$rocmRoot = "$(@($env:ROCM_PATH, $env:HIP_PATH) | Where-Object { $_ } | Select-Object -First 1)"

$info = @(& $python.Source -c 'import cv2; print(cv2.getBuildInformation())' 2>&1 | ForEach-Object { "$_" })
if ($LASTEXITCODE -ne 0) {
    "OpenCV: import cv2 failed (exit $LASTEXITCODE): $(@($info | Select-Object -Last 2) -join ' | ')"
} else {
    Get-OcvRocmBuildInfoFinding -BuildInformation ($info -join "`n") -RocmRoot $rocmRoot
}

# winmode=0 is LoadLibrary's standard search order, the one OpenCV's LoadLibraryA("OpenCL.dll") uses.
$probe = @(& $python.Source -c "import ctypes; h = ctypes.WinDLL('OpenCL.dll', winmode=0); b = ctypes.create_unicode_buffer(32768); ctypes.windll.kernel32.GetModuleFileNameW(ctypes.c_void_p(h._handle), b, 32768); print('opencl-loader|' + b.value + '|' + str(hasattr(h, 'clEnqueueReadBufferRect')))" 2>&1 | ForEach-Object { "$_" })
$loaderExit = $LASTEXITCODE
$loaderFinding = Get-OcvRocmOpenClLoaderFinding -ExitCode $loaderExit -Output ($probe -join "`n")
if ($loaderFinding) { $loaderFinding } else { Write-Host "  [info] OpenCV OpenCL loader: $(@($probe | Where-Object { $_ -match '^opencl-loader\|' })[-1])" }

# Warn-only: the smoke container has no GPU, so no platform is the expected answer here.
$ocl = @(& $python.Source -c "import cv2; ok = cv2.ocl.haveOpenCL(); print('ocl|' + str(ok) + '|' + (cv2.ocl.Device.getDefault().name() if ok else 'no platform'))" 2>&1 | ForEach-Object { "$_" })
Write-Host "  [info] cv2.ocl (warn-only, exit $LASTEXITCODE): $(@($ocl | Select-Object -Last 1) -join '')"
