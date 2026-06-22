param(
    [string]$TensorRtVersion = '',
    [string]$TensorRtRoot = '',
    [string]$LocalZipPath = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$sharedModulePath = Join-Path $PSScriptRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) { throw "Required module not found: $sharedModulePath" }
Import-Module $sharedModulePath -Force

$TensorRtVersion = Resolve-ContainerImageValue -Value $TensorRtVersion -EnvironmentVariable 'TENSORRT_VERSION' -DefaultValue ''
$TensorRtRoot = Resolve-ContainerImageValue -Value $TensorRtRoot -EnvironmentVariable 'TENSORRT_ROOT' -DefaultValue 'C:\Program Files\NVIDIA GPU Computing Toolkit\TensorRT'

# Find a TensorRT zip: local path arg > repo downloads dir > download from NVIDIA
$trtZip = $null

# 1. Check explicit local path
if ($LocalZipPath -and (Test-Path $LocalZipPath)) {
    $trtZip = $LocalZipPath
    Write-Host "Using TensorRT zip from: $LocalZipPath"
}

# 2. Check repo downloads dir (mounted in container at C:\temp\downloads)
if (-not $trtZip) {
    $repoDlDir = 'C:\temp\downloads'
    if (Test-Path $repoDlDir) {
        $found = Get-ChildItem "$repoDlDir\*TensorRT*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $trtZip = $found.FullName; Write-Host "Found TensorRT zip at: $trtZip" }
    }
}

# 3. Try C:\Users\Public\Downloads (mapped from host)
if (-not $trtZip) {
    $pubDl = 'C:\Users\Public\Downloads'
    if (Test-Path $pubDl) {
        $found = Get-ChildItem "$pubDl\*TensorRT*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $trtZip = $found.FullName; Write-Host "Found TensorRT zip at: $trtZip" }
    }
}

# 4. Download from NVIDIA (fallback, may fail without auth)
if (-not $trtZip -and $TensorRtVersion) {
    $parts = $TensorRtVersion.Split('.')
    $dirVersion = if ($parts.Length -ge 3) { "$($parts[0]).$($parts[1]).$($parts[2])" } else { $TensorRtVersion }
    $trtZip = Join-Path $env:TEMP 'tensorrt.zip'
    $urls = @(
        "https://developer.download.nvidia.com/compute/tensorrt/$dirVersion/tensorrt-$TensorRtVersion.Windows10.x86_64.cuda-13.0.zip",
        "https://developer.download.nvidia.com/compute/tensorrt/$dirVersion/tensorrt-$TensorRtVersion.Windows10.x86_64.cuda-12.8.zip"
    )
    $downloaded = $false
    foreach ($url in $urls) {
        Write-Host "Trying download: $url"
        try { Invoke-WebRequest -Uri $url -OutFile $trtZip -UseBasicParsing -ErrorAction Stop; $downloaded = $true; break }
        catch { Write-Host "  Failed: $($_.Exception.Message)" }
    }
    if (-not $downloaded) {
        Write-Host 'WARNING: Could not download TensorRT. TensorRT EP will be disabled.'
        return
    }
}

if (-not $trtZip -or -not (Test-Path $trtZip)) {
    Write-Host 'WARNING: No TensorRT zip found. TensorRT EP will be disabled.'
    Write-Host 'Place tensorrt-*.zip in: windows/downloads/ or set TENSORRT_ZIP_PATH env var.'
    return
}

Write-Host "Extracting TensorRT to $TensorRtRoot..."
New-Item -Path $TensorRtRoot -ItemType Directory -Force | Out-Null
Expand-Archive -Path $trtZip -DestinationPath $TensorRtRoot -Force
if ($trtZip -ne $LocalZipPath -and $trtZip -notlike 'C:\temp\downloads\*') { Remove-Item $trtZip -Force -ErrorAction SilentlyContinue }

# Find the actual versioned subdirectory
$trtDir = Get-ChildItem "$TensorRtRoot\TensorRT-*" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
if ($trtDir) {
    Write-Host "TensorRT installed at: $($trtDir.FullName)"
    [Environment]::SetEnvironmentVariable('TENSORRT_ROOT', $trtDir.FullName, 'Process')
    # Also expose via MSBuild/CMake convention
    [Environment]::SetEnvironmentVariable('TENSORRT_ROOT_DIR', $trtDir.FullName, 'Process')
} else {
    Write-Host "TensorRT installed at: $TensorRtRoot"
    [Environment]::SetEnvironmentVariable('TENSORRT_ROOT', $TensorRtRoot, 'Process')
}

Write-Host 'TensorRT installation complete.'
