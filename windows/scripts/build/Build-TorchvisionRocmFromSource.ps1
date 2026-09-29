# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Builds the torchvision wheel for Windows ROCm against the torch Build-TorchRocmFromSource.ps1 built (rocm lane only).
.DESCRIPTION
    The second RUN of Dockerfile.torch's torch-rocm-wheels stage. It builds in the venv the torch RUN leaves in
    -WorkDir (torch installed), so a torchvision failure or edit never re-runs the torch compile.
    Upstream vision at TORCH_ROCM_WINDOWS_TORCHVISION_COMMIT (TORCHVISION_VERSION), HIP ops for the
    ROCM_WINDOWS_GFX_FAMILY targets; image IO is off. docs/windows-rocm.md § PyTorch on the rocm lane.
.PARAMETER OutputDir
    Holds the torch wheel on entry; afterwards exactly it and torchvision-<v>+rocm<r>-cp314-cp314-win_amd64.whl.
.PARAMETER WorkDir
    The torch RUN's work dir with its build venv. Removed at the end.
#>
param(
    [string]$OutputDir = 'C:\torch-rocm-wheels',
    [string]$WorkDir = 'C:\b'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The torch builder's helpers and module imports; dot-sourced, it returns before its own build.
. (Join-Path $PSScriptRoot 'Build-TorchRocmFromSource.ps1') -OutputDir $OutputDir -WorkDir $WorkDir

if ($MyInvocation.InvocationName -eq '.') { return }

$build = Initialize-MigraphxBuild -InstallDir $OutputDir -ScriptRoot $PSScriptRoot -Component 'torchvision'
$OutputDir = $build.InstallDir
$release = "$env:ROCM_WINDOWS_RELEASE".Trim()
$torchVersion = Get-TorchRocmBuildVersion -Version "$env:PYTORCH_VERSION".Trim() -Release $release
$visionVersion = Get-TorchRocmBuildVersion -Version "$env:TORCHVISION_VERSION".Trim() -Release $release
$venvPy = Join-Path $WorkDir 'venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $venvPy -PathType Leaf)) { throw "no build venv at ${venvPy}: the torch RUN (Build-TorchRocmFromSource.ps1) leaves it" }
Write-Host "=== torchvision $visionVersion from source, against torch $torchVersion ==="

# Not Start-MigraphxBuildSession: it resets -WorkDir, which holds the torch RUN's venv.
Enter-VsDevCmdEnvironment
Start-SccacheServerSession
$jobs = Get-BuildJobCount -MemGBPerJob 5
try {
    Switch-BuildPhase '1. sources'
    & git config --global core.longpaths true
    $visionSrc = Save-GitCommitSource -Name 'vision' -Repository 'https://github.com/pytorch/vision.git' `
        -Commit "$env:TORCH_ROCM_WINDOWS_TORCHVISION_COMMIT".Trim() -WorkDir $WorkDir
    Assert-TorchRocmTreeVersion -Name 'TORCH_ROCM_WINDOWS_TORCHVISION_COMMIT' -Version "$env:TORCHVISION_VERSION".Trim() `
        -VersionText ([System.IO.File]::ReadAllText((Join-Path $visionSrc 'version.txt')))

    Switch-BuildPhase '2. torchvision'
    $env:UV_NO_CACHE = '1'; $env:UV_LINK_MODE = 'copy'
    # `import torchvision` imports PIL; torch's build requirements do not bring it.
    Invoke-TorchRocmLogged -CommandLine "uv pip install --python ""$venvPy"" pillow" -WorkingDir $WorkDir -LogName 'torchvision-rocm-deps.log'
    $env:ROCM_SDK_TARGET_FAMILY = ($build.GpuTargets -split ';')[-1]; $env:ROCM_BOOTSTRAP_DISABLE_DETECTION = '1'
    $pyTag = "$(& $venvPy -c "import sys; print('cp' + str(sys.version_info[0]) + str(sys.version_info[1]))")".Trim()
    if ($pyTag -notmatch '^cp3\d+$') { throw "build venv python reports tag '$pyTag'" }
    $common = Get-TorchRocmCommonEnv -RocmRoot $build.RocmRoot -GpuTargets $build.GpuTargets
    Set-TorchRocmProcessEnv -Env (Get-TorchRocmVisionEnv -Common $common -BuildVersion $visionVersion -Jobs $jobs)
    $env:PATH = "$(Join-Path $build.RocmRoot 'bin');$env:PATH"
    Invoke-TorchRocmLogged -CommandLine """$venvPy"" setup.py bdist_wheel" -WorkingDir $visionSrc -LogName 'torchvision-rocm-wheel.log'
    $visionWheel = Join-Path $visionSrc "dist\$(Get-TorchRocmWheelName -Distribution 'torchvision' -BuildVersion $visionVersion -PythonTag $pyTag)"
    if (-not (Test-Path -LiteralPath $visionWheel -PathType Leaf)) { throw "torchvision build left no $visionWheel" }
    Invoke-TorchRocmLogged -CommandLine "uv pip install --python ""$venvPy"" --no-deps ""$visionWheel""" -WorkingDir $WorkDir -LogName 'torchvision-rocm-install.log'
    Invoke-TorchRocmLogged -WorkingDir $WorkDir -LogName 'torchvision-rocm-import.log' -CommandLine ("""$venvPy"" -c ""import torchvision; " +
        "from torchvision.extension import _has_ops; assert _has_ops(), 'torchvision C++ ops missing'; print(torchvision.__version__)""")

    Switch-BuildPhase '3. stage the wheels'
    Copy-Item -LiteralPath $visionWheel -Destination $OutputDir -Force
    Assert-TorchRocmStagedWheel -OutputDir $OutputDir -Name @(
        (Get-TorchRocmWheelName -Distribution 'torch' -BuildVersion $torchVersion -PythonTag $pyTag), (Split-Path $visionWheel -Leaf))
    Complete-CurrentBuildPhase
} catch {
    Complete-CurrentBuildPhase -ErrorRecord $_
    Write-BuildPhaseSummary -Label 'torchvision ROCm'
    throw
}

Complete-MigraphxBuildSession -Label 'torchvision ROCm' -WorkDir $WorkDir -Banner "=== torch $torchVersion + torchvision $visionVersion built ($OutputDir) ==="
