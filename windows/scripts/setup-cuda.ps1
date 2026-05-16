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

Write-Host ('Downloading CUDA Toolkit {0}...' -f $CudaVersion)
$cudaUrl = 'https://developer.download.nvidia.com/compute/cuda/{0}/network_installers/cuda_{0}_windows_network.exe' -f $CudaVersion
Write-Host ('Download URL: {0}' -f $cudaUrl)
$cudaInstaller = Join-Path $TempDir 'cuda_installer.exe'
Invoke-WebRequest -Uri $cudaUrl -OutFile $cudaInstaller
Write-Host 'Installing CUDA Toolkit silently (this may take several minutes)...'
$ver = $CudaVersionMajorMinor
$components = @(
    '-s',
    ('nvcc_' + $ver),
    ('cudart_' + $ver),
    ('cuobjdump_' + $ver),
    ('nvprune_' + $ver),
    ('cupti_' + $ver),
    ('cublas_' + $ver),
    ('cufft_' + $ver),
    ('curand_' + $ver),
    ('cusolver_' + $ver),
    ('cusparse_' + $ver),
    ('npp_' + $ver),
    ('nvjpeg_' + $ver),
    ('nvrtc_' + $ver),
    ('thrust_' + $ver),
    ('nvml_dev_' + $ver),
    ('visual_studio_integration_' + $ver)
)
$proc = Start-Process -FilePath $cudaInstaller -ArgumentList $components -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    throw ('CUDA installation failed with exit code: {0}' -f $proc.ExitCode)
}
Remove-Item $cudaInstaller -Force
Write-Host 'CUDA Toolkit installation complete.'

Write-Host ('Downloading cuDNN {0}...' -f $CudnnVersion)
$cudnnUrl = 'https://developer.download.nvidia.com/compute/cudnn/redist/cudnn/windows-x86_64/cudnn-windows-x86_64-{0}_cuda{1}-archive.zip' -f $CudnnVersion, ($CudaVersionMajorMinor -replace '\..*','')
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
Write-Host 'cuDNN installation complete.'
