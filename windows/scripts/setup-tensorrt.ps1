param(
    [string]$TensorRtVersion = '',
    [string]$TensorRtRoot = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$sharedModulePath = Join-Path $PSScriptRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) { throw "Required module not found: $sharedModulePath" }
Import-Module $sharedModulePath -Force

$TensorRtVersion = Resolve-ContainerImageValue -Value $TensorRtVersion -EnvironmentVariable 'TENSORRT_VERSION' -DefaultValue '10.10.0.39'
$TensorRtRoot = Resolve-ContainerImageValue -Value $TensorRtRoot -EnvironmentVariable 'TENSORRT_ROOT' -DefaultValue 'C:\Program Files\NVIDIA GPU Computing Toolkit\TensorRT'

# Derive directory version from full version (e.g., 10.10.0.39 → 10.10.0)
$parts = $TensorRtVersion.Split('.')
$dirVersion = "$($parts[0]).$($parts[1]).$($parts[2])"

Write-Host "Downloading TensorRT $TensorRtVersion..."
$trtZip = Join-Path $env:TEMP 'tensorrt.zip'

# Try CUDA 13 variant first, fall back to CUDA 12
$urls = @(
    "https://developer.download.nvidia.com/compute/tensorrt/$dirVersion/tensorrt-$TensorRtVersion.Windows10.x86_64.cuda-13.0.zip",
    "https://developer.download.nvidia.com/compute/tensorrt/$dirVersion/tensorrt-$TensorRtVersion.Windows10.x86_64.cuda-12.8.zip"
)

$downloaded = $false
foreach ($url in $urls) {
    Write-Host "Trying: $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $trtZip -UseBasicParsing -ErrorAction Stop
        $downloaded = $true
        break
    } catch {
        Write-Host "Failed: $($_.Exception.Message)"
    }
}

if (-not $downloaded) { throw "Failed to download TensorRT $TensorRtVersion from any URL" }

Write-Host "Extracting TensorRT to $TensorRtRoot..."
New-Item -Path $TensorRtRoot -ItemType Directory -Force | Out-Null
Expand-Archive -Path $trtZip -DestinationPath $TensorRtRoot -Force
Remove-Item $trtZip -Force

# Find the actual versioned subdirectory
$trtDir = Get-ChildItem "$TensorRtRoot\TensorRT-*" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
if ($trtDir) {
    Write-Host "TensorRT installed at: $($trtDir.FullName)"
    [Environment]::SetEnvironmentVariable('TENSORRT_ROOT', $trtDir.FullName, 'Process')
}

Write-Host 'TensorRT installation complete.'
