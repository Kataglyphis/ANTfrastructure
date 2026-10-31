#requires -Version 7.0
# NVIDIA_OPENCV_RUNTIME_PROVENANCE_API=1
<#
.SYNOPSIS
    Proves packaged NVIDIA OpenCV dependencies and their license texts match the installed image SDKs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Bundle,
    [Parameter(Mandatory)][string]$CudaVersion,
    [Parameter(Mandatory)][string]$CudnnVersion,
    [string]$RuntimeRoot = 'C:\runtime\cuda-runtime'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-NvidiaRuntimeGroup {
    param([string]$Label, [string]$Root, [string]$Version, [string]$License, [object[]]$Files)
    if ($Files.Count -eq 0) { return }
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { throw "$Label SDK root is missing." }
    $resolved = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\', '/')
    if ((Split-Path -Leaf $resolved) -cne "v$Version") { throw "$Label SDK version does not match $Version`: $resolved" }
    $imageLicense = Join-Path $resolved 'LICENSE'
    if (-not (Test-Path -LiteralPath $License -PathType Leaf) -or -not (Test-Path -LiteralPath $imageLicense -PathType Leaf)) {
        throw "$Label license is missing from the bundle or image."
    }
    if ((Get-Item -LiteralPath $License).Length -eq 0 -or
        (Get-FileHash -LiteralPath $License -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $imageLicense -Algorithm SHA256).Hash) {
        throw "$Label license differs from the image's original text."
    }
    foreach ($file in $Files) {
        $original = Join-Path $resolved "bin\x64\$($file.Name)"
        $runtime = Join-Path $RuntimeRoot "bin\$($file.Name)"
        if (-not (Test-Path -LiteralPath $original -PathType Leaf) -or -not (Test-Path -LiteralPath $runtime -PathType Leaf)) {
            throw "$Label source or runtime DLL is missing: $($file.Name)"
        }
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        if ($file.Length -eq 0 -or $hash -ne (Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash -or
            $hash -ne (Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash) {
            throw "$Label bundle DLL differs from the SDK or runtime: $($file.Name)"
        }
    }
}

$bin = Join-Path $Bundle 'runtime\Lib\site-packages\cv2\bin'
if (-not (Test-Path -LiteralPath $bin -PathType Container)) { throw "The bundled OpenCV DLL directory is missing: $bin" }
$cuda = [Collections.Generic.List[IO.FileInfo]]::new()
$cudnn = [Collections.Generic.List[IO.FileInfo]]::new()
foreach ($file in Get-ChildItem -LiteralPath $bin -Filter '*.dll' -File) {
    if ($file.Name -match '^(cublas|cufft|npp).*\.dll$') { $cuda.Add($file) }
    if ($file.Name -match '^cudnn.*\.dll$') { $cudnn.Add($file) }
}
Assert-NvidiaRuntimeGroup -Label CUDA -Root $env:CUDA_PATH -Version $CudaVersion `
    -License (Join-Path $Bundle "licenses\nvidia-cuda-$CudaVersion-LICENSE.txt") -Files $cuda
Assert-NvidiaRuntimeGroup -Label cuDNN -Root $env:CUDNN_ROOT -Version $CudnnVersion `
    -License (Join-Path $Bundle "licenses\nvidia-cudnn-$CudnnVersion-LICENSE.txt") -Files $cudnn
Write-Host "OpenCV NVIDIA runtime provenance verified: CUDA=$($cuda.Count), cuDNN=$($cudnn.Count)."
