#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    Installs the pinned NSIS release zip into InstallDir and records its provenance there (BACKLOG CON302).
#>
param(
    [string]$TempDir = 'C:\temp',
    [string]$NsisVersion = $env:NSIS_VERSION,
    [string]$ZipSha256 = $env:NSIS_WINDOWS_ZIP_SHA256,
    [string]$InstallDir = 'C:\nsis'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
foreach ($moduleName in 'WindowsContainerImage.Common.psm1', 'WindowsScripts.Shared.psm1') {
    $modulePath = Join-Path $scriptAssetRoot "modules\$moduleName"
    if (-not (Test-Path $modulePath)) { throw "Required module not found: $modulePath" }
    Import-Module $modulePath -Force
}

<#
.SYNOPSIS
    SourceForge's release zip URL, refusing anything that is not a major.minor NSIS version.
#>
function Get-NsisZipUrl {
    param([string]$Version, [string]$BaseUrl = 'https://downloads.sourceforge.net/project/nsis')
    $release = [regex]::Match($Version, '^(?<major>\d+)\.\d{2}$')
    if (-not $release.Success) { throw "Install-Nsis: NSIS_VERSION must be a major.minor NSIS release like 3.13; got '$Version'" }
    return "$($BaseUrl.TrimEnd('/'))/NSIS%20$($release.Groups['major'].Value)/$Version/nsis-$Version.zip"
}

<#
.SYNOPSIS
    The zip's single nsis-<version> root, refusing any other layout before it reaches InstallDir.
#>
function Get-NsisExtractedRoot {
    param([Parameter(Mandatory)][string]$StagingDir, [Parameter(Mandatory)][string]$Version)
    $roots = @(Get-ChildItem -LiteralPath $StagingDir -Force)
    $expected = "nsis-$Version"
    if ($roots.Count -ne 1 -or $roots[0].Name -cne $expected -or -not $roots[0].PSIsContainer) {
        throw "Install-Nsis: the zip must hold exactly one '$expected' directory; found '$(@($roots.Name) -join "', '")'"
    }
    foreach ($required in 'Bin\makensis.exe', 'COPYING', 'Stubs\zlib-x86-unicode') {
        if (-not (Test-Path -LiteralPath (Join-Path $roots[0].FullName $required) -PathType Leaf)) {
            throw "Install-Nsis: $expected lacks $required"
        }
    }
    return $roots[0].FullName
}

<#
.SYNOPSIS
    Downloads, verifies and unpacks the pinned NSIS; makensis must then report that exact release.
#>
function Install-Nsis {
    param(
        [Parameter(Mandatory)][string]$NsisVersion,
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{64}$', ErrorMessage = "Install-Nsis: NSIS_WINDOWS_ZIP_SHA256 must be a 64-hex SHA256 (see versions.env); got '{0}'")]
        [string]$ZipSha256,
        [Parameter(Mandatory)][string]$InstallDir,
        [string]$TempDir = 'C:\temp'
    )
    $url = Get-NsisZipUrl -Version $NsisVersion
    if (Test-Path -LiteralPath $InstallDir) { throw "Install-Nsis: $InstallDir already exists; refusing to mix two NSIS trees" }

    $TempDir = Initialize-ContainerImageTempDirectory -TempDir $TempDir
    $zipPath = Join-Path $TempDir "nsis-$NsisVersion.zip"
    $staging = Join-Path $TempDir "nsis-$NsisVersion-staging"
    Write-Host "Downloading NSIS ${NsisVersion}: $url"
    # SourceForge answers the shared helper's browser user agent with an HTML page; a non-browser one gets the zip.
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UserAgent 'kataglyphis-build' -MaximumRetryCount 4 -RetryIntervalSec 5
    Assert-FileSha256 -Path $zipPath -Expected $ZipSha256 -Label "NSIS $NsisVersion" -PinName 'NSIS_WINDOWS_ZIP_SHA256'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $staging
    Move-Item -LiteralPath (Get-NsisExtractedRoot -StagingDir $staging -Version $NsisVersion) -Destination $InstallDir
    Remove-Item -LiteralPath $zipPath, $staging -Recurse -Force -ErrorAction SilentlyContinue

    $reported = "$(& (Join-Path $InstallDir 'Bin\makensis.exe') /VERSION)".Trim()
    if ($LASTEXITCODE -ne 0 -or $reported -cne "v$NsisVersion") {
        throw "Install-Nsis: makensis reports '$reported' (exit $LASTEXITCODE), expected NSIS_VERSION 'v$NsisVersion'"
    }
    [ordered]@{ name = 'NSIS'; version = $NsisVersion; url = $url; sha256 = $ZipSha256.ToLowerInvariant() } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallDir 'kataglyphis-provenance.json') -Encoding utf8
    Write-Host "NSIS $NsisVersion installed in $InstallDir with its COPYING"
    Clear-PendingFileHandle
}

if ($MyInvocation.InvocationName -ne '.') {
    Install-Nsis -TempDir $TempDir -NsisVersion $NsisVersion -ZipSha256 $ZipSha256 -InstallDir $InstallDir
}
