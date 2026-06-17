Set-StrictMode -Version Latest

$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -Force

function Get-SourceBuildVersion {
    param(
        [string]$Value = '',
        [string[]]$EnvironmentVariables = @(),
        [string]$DefaultValue = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }

    foreach ($envVar in $EnvironmentVariables) {
        if (-not [string]::IsNullOrWhiteSpace($envVar)) {
            $envValue = [Environment]::GetEnvironmentVariable($envVar)
            if (-not [string]::IsNullOrWhiteSpace($envValue)) { return $envValue }
        }
    }

    return $DefaultValue
}

function Invoke-GitClone {
    param(
        [Parameter(Mandatory)]
        [string]$RepoUrl,
        [Parameter(Mandatory)]
        [string]$SourceDir,
        [string]$Branch = '',
        [string]$Tag = '',
        [switch]$Recursive,
        [switch]$SkipOnFailure,
        [int]$Depth = 1
    )

    if (Test-Path $SourceDir) { Remove-Item $SourceDir -Recurse -Force }

    $ref = if ($Tag) { $Tag } else { $Branch }
    if ([string]::IsNullOrWhiteSpace($ref)) { throw 'Either -Branch or -Tag is required' }

    $gitArgs = @('clone')
    if ($Recursive) { $gitArgs += '--recursive' }
    $gitArgs += '--branch', $ref
    $gitArgs += '--depth', $Depth
    $gitArgs += $RepoUrl, $SourceDir

    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $env:GIT_SSL_NO_VERIFY = '1'
    $env:GIT_TERMINAL_PROMPT = '0'

    $null = & git @gitArgs 2>&1
    $cloneExit = $LASTEXITCODE

    $ErrorActionPreference = $oldEAP

    if ($cloneExit -ne 0) {
        if ($SkipOnFailure) {
            Write-Host "WARNING: git clone failed (exit $cloneExit) - skipped"
            return $false
        }
        throw "git clone failed (exit $cloneExit): $RepoUrl $ref"
    }
    return $true
}

function Invoke-CmakeConfigure {
    param(
        [Parameter(Mandatory)]
        [string]$SourceDir,
        [Parameter(Mandatory)]
        [string]$BuildDir,
        [Parameter(Mandatory)]
        [string]$InstallPrefix,
        [string]$Generator = 'Ninja',
        [string]$Platform = '',
        [string]$Toolset = '',
        [string]$BuildType = 'Release',
        [string]$CCompiler = 'clang-cl',
        [string]$CxxCompiler = 'clang-cl',
        [string]$Linker = 'lld-link',
        [string]$Archiver = 'llvm-lib',
        [string[]]$ExtraArgs = @(),
        [switch]$SkipOnFailure
    )

    New-Item -Path $BuildDir -ItemType Directory -Force | Out-Null
    New-Item -Path $InstallPrefix -ItemType Directory -Force | Out-Null

    $cmakeArgs = @('-S', $SourceDir, '-B', $BuildDir, "-DCMAKE_INSTALL_PREFIX=$InstallPrefix")

    if ($Generator) {
        $cmakeArgs += '-G', $Generator
        if ($Platform) { $cmakeArgs += '-A', $Platform }
        if ($Toolset) { $cmakeArgs += '-T', $Toolset }
    }

    if ($BuildType) { $cmakeArgs += "-DCMAKE_BUILD_TYPE=$BuildType" }
    if ($CCompiler) { $cmakeArgs += "-DCMAKE_C_COMPILER=$CCompiler" }
    if ($CxxCompiler) { $cmakeArgs += "-DCMAKE_CXX_COMPILER=$CxxCompiler" }
    if ($Linker) { $cmakeArgs += "-DCMAKE_LINKER=$Linker" }
    if ($Archiver) { $cmakeArgs += "-DCMAKE_AR=$Archiver" }

    if ($ExtraArgs.Count -gt 0) { $cmakeArgs += $ExtraArgs }

    Write-Host "CMake configure: $($cmakeArgs -join ' ')"
    & cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) {
        if ($SkipOnFailure) {
            Write-Host "WARNING: CMake configuration failed - skipped"
            return $false
        }
        throw "CMake configuration failed"
    }
    return $true
}

function Invoke-CmakeBuild {
    param(
        [Parameter(Mandatory)]
        [string]$BuildDir,
        [string]$Config = 'Release',
        [switch]$Install,
        [switch]$SkipOnFailure,
        [string]$LogFile = ''
    )

    Write-Host "Building (this may take 15-120 minutes)..."
    if ($LogFile) {
        & cmake --build $BuildDir --config $Config --parallel 2>&1 | Tee-Object -FilePath $LogFile | Out-Null
    } else {
        & cmake --build $BuildDir --config $Config --parallel
    }
    if ($LASTEXITCODE -ne 0) {
        if ($LogFile -and (Test-Path $LogFile)) {
            Write-Host "`n=== BUILD LOG ERRORS ==="
            Select-String -Path $LogFile -Pattern 'FAILED:|error:' -SimpleMatch | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
            Write-Host "--- last 20 lines ---"
            Get-Content $LogFile -Tail 20 | ForEach-Object { Write-Host $_ }
        }
        if ($SkipOnFailure) {
            Write-Host "WARNING: Build failed - skipped"
            return $false
        }
        throw "Build failed"
    }

    if ($Install) {
        Write-Host "Installing..."
        & cmake --install $BuildDir --config $Config
        if ($LASTEXITCODE -ne 0) { throw "Install failed" }
    }
    return $true
}

function Assert-CudaAvailable {
    $cudaRoot = if ($env:CUDA_ROOT) { $env:CUDA_ROOT } elseif ($env:CUDA_PATH) { $env:CUDA_PATH } else { $null }
    return (-not [string]::IsNullOrWhiteSpace($cudaRoot)) -and (Test-Path $cudaRoot)
}

function Assert-CudnnInstalled {
    param(
        [string]$CudnnRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($CudnnRoot)) { $CudnnRoot = $env:CUDNN_ROOT }
    if ([string]::IsNullOrWhiteSpace($CudnnRoot)) { return $false }
    if (-not (Test-Path $CudnnRoot)) { return $false }

    $headers = Get-ChildItem -Path $CudnnRoot -Filter 'cudnn.h' -Recurse -ErrorAction SilentlyContinue
    $libs = Get-ChildItem -Path $CudnnRoot -Filter 'cudnn*.lib' -Recurse -ErrorAction SilentlyContinue
    $dlls = Get-ChildItem -Path $CudnnRoot -Filter 'cudnn*.dll' -Recurse -ErrorAction SilentlyContinue

    return ($headers.Count -gt 0) -and ($libs.Count -gt 0) -and ($dlls.Count -gt 0)
}

Export-ModuleMember -Function @(
    'Get-SourceBuildVersion',
    'Invoke-GitClone',
    'Invoke-CmakeConfigure',
    'Invoke-CmakeBuild',
    'Assert-CudaAvailable',
    'Assert-CudnnInstalled'
)
