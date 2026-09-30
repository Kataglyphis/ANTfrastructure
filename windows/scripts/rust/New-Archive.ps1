# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
  Zips a Rust release binary for a Windows build.
.DESCRIPTION
  Consumers call it by hub path, so it is live without a caller in this repo.
.PARAMETER Workspace
  The workspace directory; defaults to $env:WORKSPACE, then the current directory.
.PARAMETER Binary
  The binary name without .exe. Required.
.PARAMETER BinaryFile
  The binary file name; defaults to $Binary.exe.
.PARAMETER Version
  The version string for the archive name.
.PARAMETER ArchiveName
  Custom archive name; generated from Binary and Version when empty.
.PARAMETER ArchiveDir
  Staging directory; defaults to 'dist'.
.PARAMETER Platform
  Platform identifier, e.g. 'windows-2025'.
.PARAMETER Arch
  Architecture identifier, e.g. 'x64'.
#>

param(
    [string]$Workspace = $env:WORKSPACE,
    [string]$Binary = $env:BINARY,
    [string]$BinaryFile,
    [string]$Version = $env:VERSION,
    [string]$ArchiveName,
    [string]$ArchiveDir = "dist",
    [string]$Platform = $env:PLATFORM,
    [string]$Arch = $env:ARCH
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Workspace)) {
    $Workspace = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($Binary)) {
    Write-Error "Binary parameter is required"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($BinaryFile)) {
    $BinaryFile = "$Binary.exe"
}

. (Join-Path $PSScriptRoot '..\modules\Initialize-CiEnvironment.ps1')
Initialize-CiEnvironment -ScriptRoot $PSScriptRoot

$logDir = Join-Path $Workspace "logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

$Context = New-BuildContext -Workspace $Workspace -LogDir $logDir -StopOnError
Open-BuildLog -Context $Context

try {
    Write-BuildLog -Context $Context -Message "=== Archive Creation ==="
    Write-BuildLog -Context $Context -Message "Workspace: $Workspace"
    Write-BuildLog -Context $Context -Message "Binary: $Binary"
    Write-BuildLog -Context $Context -Message "BinaryFile: $BinaryFile"
    Write-BuildLog -Context $Context -Message "Version: $Version"

    Set-Location -Path $Workspace

    if ([string]::IsNullOrWhiteSpace($ArchiveName)) {
        $VersionSafe = $Version -replace '^v','' -replace '/','-'
        if (-not ([string]::IsNullOrWhiteSpace($Platform)) -and -not ([string]::IsNullOrWhiteSpace($Arch))) {
            $ArchiveName = "dist/$Binary-$VersionSafe-$Platform-$Arch.zip"
        } else {
            $ArchiveName = "dist/$Binary-$VersionSafe.zip"
        }
    }

    # The step's scriptblock reads these through script scope.
    Write-BuildLog -Context $Context -Message "Archive name: $ArchiveName"

    Invoke-BuildStep -Context $Context -StepName "Prepare Archive" -Critical -Script {
        $archivePath = Join-Path $Workspace $script:ArchiveName
        $archiveDir = Split-Path $archivePath -Parent
        $stagingDir = Join-Path $Workspace $script:ArchiveDir

        if (-not (Test-Path $archiveDir)) {
            New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
        }

        if (-not (Test-Path $stagingDir)) {
            New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
        }

        $binaryPath = Join-Path $Workspace "target\release\$script:BinaryFile"
        if (-not (Test-Path $binaryPath)) {
            throw "Release binary not found: $binaryPath"
        }

        Write-BuildLog -Context $Context -Message "Copying binary to staging..."
        Copy-Item $binaryPath -Destination $stagingDir -Force

        Write-BuildLog -Context $Context -Message "Creating ZIP archive..."
        Compress-Archive -Path "$stagingDir\$script:BinaryFile" -DestinationPath $archivePath -Force

        Write-BuildLog -Context $Context -Message "Archive created: $archivePath"
    }

    Write-BuildSummary -Context $Context
    exit 0
} catch {
    Write-BuildLogError -Context $Context -Message "Archive creation failed: $($_.Exception.Message)"
    Write-BuildSummary -Context $Context
    exit 1
} finally {
    Close-BuildLog -Context $Context
}
