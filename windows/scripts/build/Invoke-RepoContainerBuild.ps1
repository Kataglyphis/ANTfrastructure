# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Runs a consumer's build script in the family Windows CI image: the shared half of every Build-Windows-Container.ps1.
.DESCRIPTION
    The caller keeps what is its own - the container name, the build command, the keep/incremental/output dir
    lists - and this script keeps the plumbing: the module imports, the image ref from versions.env, the docker
    resolution, the sccache environment and the Invoke-ContainerBuild call. Every consumer's driver shrank to
    its spec, and the plumbing cannot drift between them.
    -WhatIf prints the assembled in-container command without starting a container.
    See docs/windows-container-build-performance.md.
.PARAMETER RepoRoot
    The consumer's repository root, which the container bind-mounts or streams.
.PARAMETER BuildCommand
    A scriptblock taking the workspace path and returning the argv, or a string array passed through as is.
.PARAMETER CacheEnv
    Extra container environment on top of the sccache set (e.g. KATAGLYPHIS_KEEP_BUILD_ROOT=1).
.PARAMETER InboundItems
    The top-level entries the transfer streams; keep a root directory out of this list rather than excluding
    it by pattern, because --exclude matches at every depth.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$ContainerName,
    [Parameter(Mandatory)][object]$BuildCommand,
    [string]$Image = '',
    [string]$DockerExe = '',
    [ValidateSet('process', 'hyperv')][string]$Isolation = 'process',
    [int]$CpuCount = 0,
    [int]$MemoryGb = 16,
    [string[]]$KeepDirs = @(),
    [string[]]$InboundItems = @('.'),
    [string[]]$InboundExclude = @('.git'),
    [string[]]$IncrementalDirs = @(),
    [string[]]$IncrementalExclude = @(),
    [string[]]$OutputDirs = @(),
    [string[]]$VerifyDirs = @(),
    [string[]]$OutboundExclude = @(),
    [hashtable]$CacheEnv = @{},
    [switch]$UseBindMount,
    [switch]$FreshContainer
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$moduleDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'
$reuseModule = Join-Path $moduleDir 'WindowsContainerBuild.Reuse.psm1'
if (-not (Test-Path -LiteralPath $reuseModule)) { throw "Required module not found: $reuseModule" }
Import-Module $reuseModule -Force -Global

$imageModule = Join-Path $moduleDir 'WindowsContainerImage.Common.psm1'
if (-not (Test-Path -LiteralPath $imageModule)) { throw "Required module not found: $imageModule" }
Import-Module $imageModule -Force -Global

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not $Image) { $Image = Get-CiImageReference -Windows }
$docker = Resolve-DockerExe -Override $DockerExe
Write-Host "Using docker: $docker"
Write-Host "Image: $Image"

# C:\ws, not the image-baked C:\workspace: mounting over an image directory fails at CreateComputeSystem on host/image OS-build skew.
$workspacePath = 'C:\ws'

$envMap = Get-SccacheContainerEnv
foreach ($key in $CacheEnv.Keys) { $envMap[$key] = $CacheEnv[$key] }

$build = @{
    DockerExe          = $docker
    Image              = $Image
    ContainerName      = $ContainerName
    RepoRoot           = $RepoRoot
    BuildCommand       = $BuildCommand
    WorkspacePath      = $workspacePath
    IsolationArgs      = (Get-ContainerIsolationArgs -Isolation $Isolation -CpuCount $CpuCount -MemoryGb $MemoryGb)
    CacheEnv           = $envMap
    KeepDirs           = $KeepDirs
    InboundItems       = $InboundItems
    InboundExclude     = $InboundExclude
    IncrementalDirs    = $IncrementalDirs
    IncrementalExclude = $IncrementalExclude
    OutputDirs         = $OutputDirs
    VerifyDirs         = $VerifyDirs
    OutboundExclude    = $OutboundExclude
    UseBindMount       = $UseBindMount.IsPresent
    FreshContainer     = $FreshContainer.IsPresent
}
if ($PSCmdlet.ShouldProcess("$Image (container '$ContainerName')", 'Invoke-ContainerBuild')) {
    $null = Invoke-ContainerBuild @build
} else {
    # -WhatIf: show the exact in-container command the spec assembles to.
    $argv = Resolve-ContainerBuildCommand -BuildCommand $BuildCommand -WorkspacePath $workspacePath
    Write-Host ("Would run in {0}: {1}" -f $workspacePath, ($argv -join ' '))
}
