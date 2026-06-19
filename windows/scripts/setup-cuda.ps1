param(
    [string]$TempDir = 'C:\temp',
    [string]$CudaVersion = '',
    [string]$CudaVersionMajorMinor = '',
    [string]$CudnnVersion = '',
    [string]$CudnnRoot = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$sharedModulePath = Join-Path $PSScriptRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) {
    throw "Required module not found: $sharedModulePath"
}

Import-Module $sharedModulePath -Force

$CudaVersion = Resolve-ContainerImageValue -Value $CudaVersion -EnvironmentVariable 'CUDA_VERSION'
$CudaVersionMajorMinor = Resolve-ContainerImageValue -Value $CudaVersionMajorMinor -EnvironmentVariable 'CUDA_VERSION_MAJOR_MINOR'
$CudnnVersion = Resolve-ContainerImageValue -Value $CudnnVersion -EnvironmentVariable 'CUDNN_VERSION'
$CudnnRoot = Resolve-ContainerImageValue -Value $CudnnRoot -EnvironmentVariable 'CUDNN_ROOT' -DefaultValue ('C:\Program Files\NVIDIA\CUDNN\v{0}' -f $CudnnVersion)

$TempDir = Initialize-ContainerImageTempDirectory -TempDir $TempDir

Write-Host ('Installing CUDA Toolkit {0} via Scoop (portable install within container)...' -f $CudaVersion)
scoop install cuda 2>&1
$scoopExit = $LASTEXITCODE
if ($scoopExit -ne 0) {
    Write-Host "Scoop CUDA install failed (exit $scoopExit) - falling back to direct full installer"
    $cudaUrl = "https://developer.download.nvidia.com/compute/cuda/$CudaVersion/local_installers/cuda_$CudaVersion`_windows.exe"
    Write-Host "Download URL: $cudaUrl"
    $cudaInstaller = Join-Path $TempDir 'cuda_installer.exe'
    Invoke-WebRequest -Uri $cudaUrl -OutFile $cudaInstaller
    Write-Host 'Installing CUDA Toolkit with all components (lowercase -s = full silent install)...'
    $proc = Start-Process -FilePath $cudaInstaller -ArgumentList '-s', '--no-download-driver' -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw ('CUDA installation failed with exit code: {0}' -f $proc.ExitCode)
    }
    Remove-Item $cudaInstaller -Force
}
Write-Host 'CUDA Toolkit installation complete.'

# Detect CUDA installation path: prefer Scoop path (portable, within container layer),
# fall back to standard Program Files location for direct installer
$scoopCudaHome = "$env:USERPROFILE\scoop\apps\cuda\current"
$expectedProgramFilesRoot = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v$($CudaVersionMajorMinor -replace '-', '.')"

$effectiveCudaRoot = $null
if (Test-Path $scoopCudaHome) {
    $effectiveCudaRoot = $scoopCudaHome
    Write-Host "CUDA Scoop home found at: $effectiveCudaRoot"
} elseif (Test-Path $expectedProgramFilesRoot) {
    $effectiveCudaRoot = $expectedProgramFilesRoot
    Write-Host "CUDA Program Files home found at: $effectiveCudaRoot"
} else {
    # Search broadly
    $cudaSearchPaths = @(
        "$env:USERPROFILE\scoop\apps\cuda\current",
        $expectedProgramFilesRoot,
        "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v$((Get-ChildItem 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1).Name)"
    )
    foreach ($searchPath in $cudaSearchPaths) {
        $testNvcc = Join-Path $searchPath 'bin\nvcc.exe'
        if (Test-Path $testNvcc) {
            $effectiveCudaRoot = $searchPath
            Write-Host "nvcc found at: $testNvcc"
            break
        }
    }
    if (-not $effectiveCudaRoot) { throw "nvcc.exe not found after CUDA installation" }
}

[Environment]::SetEnvironmentVariable('CUDA_ROOT', $effectiveCudaRoot, 'Process')
[Environment]::SetEnvironmentVariable('CUDA_PATH', $effectiveCudaRoot, 'Process')
$cudaBinDir = Join-Path $effectiveCudaRoot 'bin'
$env:PATH = "$cudaBinDir;$env:PATH"
Write-Host "Set CUDA_ROOT to: $effectiveCudaRoot"
Get-ChildItem -Path "$effectiveCudaRoot\bin" -ErrorAction SilentlyContinue | Select-Object -First 10 | ForEach-Object { Write-Host "  CUDA bin: $_" }

# Verify CCCL/CRT headers are present; create stubs if missing (Scoop portable install
# includes all components, but CUDA 13.x places some CCCL headers under include/cccl/
# instead of include/nv/ or include/crt/)
$cudaIncludeDir = "$effectiveCudaRoot\include"

# CUDA 13.x CMake config references include/cccl/ for CCCL headers — Scoop doesn't ship it
$ccclDir = Join-Path $cudaIncludeDir 'cccl'
if (-not (Test-Path $ccclDir)) {
    New-Item -Path $ccclDir -ItemType Directory -Force | Out-Null
    Write-Host "Created empty include/cccl/ directory (required by CUDA CMake config)"
}
# CUDA CMake's CUDA::cublasLt etc. have INTERFACE_INCLUDE_DIRECTORIES pointing at cccl/
# Even empty, the directory existence satisfies CMake's path validation.

$missingHeaders = @()
$nvDir = Join-Path $cudaIncludeDir 'nv'
if (-not (Test-Path $nvDir)) { New-Item -Path $nvDir -ItemType Directory -Force | Out-Null }
# CUDA 13.3 cuda_fp16.h uses `#include <nv/target>` (no .h extension, CCCL header-unit style)
# We need BOTH nv/target.h (for <nv/target.h> includes) AND nv/target (for <nv/target> includes).
# The stub must define NV_IS_DEVICE/NV_IS_HOST/NV_IF_ELSE_TARGET for host-only compilation
# (clang-cl compiling CUDA provider code without nvcc's device builtins).
$nvTargetContent = @'
#pragma once
// CCCL nv/target stub for host-only compilation (clang-cl, no nvcc builtins)
#define NV_IS_DEVICE 0
#define NV_IS_HOST 1
#define NV_IF_ELSE_TARGET(cond, t, f) f
'@
$nvTargetH = Join-Path $nvDir 'target.h'
$nvTargetNoExt = Join-Path $nvDir 'target'
if (-not (Test-Path $nvTargetH)) {
    Set-Content -Path $nvTargetH -Value $nvTargetContent -Encoding ASCII
    Write-Host "Created stub: nv/target.h"
}
if (-not (Test-Path $nvTargetNoExt)) {
    Set-Content -Path $nvTargetNoExt -Value $nvTargetContent -Encoding ASCII
    Write-Host "Created stub: nv/target (no ext, for <nv/target>)"
}
if (-not (Test-Path (Join-Path $cudaIncludeDir 'crt\host_config.h'))) {
    $missingHeaders += 'crt/host_config.h'
}
if ($missingHeaders.Count -gt 0) {
    Write-Host "WARNING: CRT headers missing: $($missingHeaders -join ', ')"
    foreach ($header in $missingHeaders) {
        $dir = Split-Path (Join-Path $cudaIncludeDir $header) -Parent
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        Set-Content -Path (Join-Path $cudaIncludeDir $header) -Value '#pragma once' -Encoding ASCII
        Write-Host "Created stub: $header"
    }
} else {
    Write-Host "CCCL and CRT headers verified present."
}

Write-Host ('Downloading cuDNN {0}...' -f $CudnnVersion)
$cudaMajorVersion = $CudaVersionMajorMinor -replace '[^0-9].*', ''
$cudnnUrl = 'https://developer.download.nvidia.com/compute/cudnn/redist/cudnn/windows-x86_64/cudnn-windows-x86_64-{0}_cuda{1}-archive.zip' -f $CudnnVersion, $cudaMajorVersion
Write-Host ('Download URL: {0}' -f $cudnnUrl)
$cudnnArchive = Join-Path $TempDir 'cudnn.zip'
$cudnnExtracted = Join-Path $TempDir 'cudnn_extracted'
Invoke-WebRequest -Uri $cudnnUrl -OutFile $cudnnArchive
Write-Host 'Extracting cuDNN...'
Expand-Archive -Path $cudnnArchive -DestinationPath $cudnnExtracted -Force
$cudnnDir = Get-ChildItem -Path $cudnnExtracted -Directory | Select-Object -First 1
if (-not $cudnnDir) {
    throw ('Extracted cuDNN directory not found under {0}' -f $cudnnExtracted)
}
New-Item -Path $CudnnRoot -ItemType Directory -Force | Out-Null
Copy-Item -Path (Join-Path $cudnnDir.FullName '*') -Destination $CudnnRoot -Recurse -Force
Remove-Item $cudnnArchive -Force
Remove-Item $cudnnExtracted -Recurse -Force

# Verify cuDNN installation
Write-Host 'Verifying cuDNN installation...'
$cudnnHeaders = Get-ChildItem -Path $CudnnRoot -Filter 'cudnn.h' -Recurse -ErrorAction SilentlyContinue
$cudnnLibs = Get-ChildItem -Path $CudnnRoot -Filter 'cudnn*.lib' -Recurse -ErrorAction SilentlyContinue
$cudnnDlls = Get-ChildItem -Path $CudnnRoot -Filter 'cudnn*.dll' -Recurse -ErrorAction SilentlyContinue
if (-not $cudnnHeaders) { throw "cuDNN headers (cudnn.h) not found under $CudnnRoot" }
if (-not $cudnnLibs) { throw "cuDNN import libs (cudnn*.lib) not found under $CudnnRoot" }
if (-not $cudnnDlls) { throw "cuDNN DLLs (cudnn*.dll) not found under $CudnnRoot" }
Write-Host ('cuDNN verified: {0} headers, {1} libs, {2} DLLs' -f $cudnnHeaders.Count, $cudnnLibs.Count, $cudnnDlls.Count)
Write-Host 'cuDNN installation complete.'
