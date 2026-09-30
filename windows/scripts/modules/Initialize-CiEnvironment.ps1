# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# Dot-sourced, not a .psm1: the imports must land in the calling CI script's session state.

function Initialize-CiEnvironment {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptRoot,
        [string[]]$Modules = @('WindowsBuild.Common'),
        # Enter and return the ANTfrastructure checkout root (three levels up); a vendored consumer passes -RepoRoot.
        [switch]$EnterRepoRoot,
        # Explicit repo-root override for vendored-checkout consumers.
        [string]$RepoRoot = ''
    )

    $modulesPath = Join-Path $ScriptRoot '..\modules'
    foreach ($name in $Modules) {
        $modulePath = Join-Path $modulesPath "$name.psm1"
        if (-not (Test-Path -Path $modulePath)) {
            throw "Required reusable module not found: $modulePath"
        }
        Import-Module $modulePath -Force
    }

    if ($EnterRepoRoot) {
        # [string]: callers expect a path string, not Resolve-Path's PathInfo.
        $resolvedRoot = if ($RepoRoot) { [string](Resolve-Path $RepoRoot) }
        else { [string](Resolve-Path (Join-Path $ScriptRoot '..\..\..')) }
        Set-Location $resolvedRoot
        return $resolvedRoot
    }
}

# Shared CI-session preamble; dot-sourced, so $script:CiContext is the calling script's variable.

function New-CiSession {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$LogDir = 'logs',
        [switch]$StopOnError,
        # Also set the $script:Uv* delegates the packaging, docs and static drivers hand to WindowsUv.Common.
        [switch]$WithUvDelegates
    )
    $script:CiContext = New-BuildContext -Workspace $RepoRoot -LogDir $LogDir -StopOnError:$StopOnError
    $script:CiContext.SuppressConsoleOutput = $false
    if ($WithUvDelegates) {
        $uvDelegates = New-UvBuildDelegates -Context $script:CiContext
        $script:UvCommandRunner = $uvDelegates.CommandRunner
        $script:UvLogInfo = $uvDelegates.LogInfo
        $script:UvLogWarning = $uvDelegates.LogWarning
    }
    Open-BuildLog -Context $script:CiContext
    return $script:CiContext
}

function Write-CiLog { param([string]$Message) Write-BuildLog -Context $script:CiContext -Message $Message }
function Write-CiLogWarning { param([string]$Message) Write-BuildLogWarning -Context $script:CiContext -Message $Message }
function Write-CiLogError { param([string]$Message) Write-BuildLogError -Context $script:CiContext -Message $Message }
function Write-CiLogSuccess { param([string]$Message) Write-BuildLogSuccess -Context $script:CiContext -Message $Message }
function Close-CiLog { Close-BuildLog -Context $script:CiContext }

