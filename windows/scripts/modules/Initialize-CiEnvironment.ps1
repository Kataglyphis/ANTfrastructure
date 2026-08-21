# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# Shared bootstrap for the CI entry scripts (windows/scripts/python/Invoke-Ci*.ps1,
# windows/scripts/rust/*.ps1): resolves and imports the requested ContainerHub
# modules and optionally enters the consumer repo root.
#
# Deliberately a dot-sourced SCRIPT, not a .psm1: the Import-Module calls must run
# in the CALLING script's session state. Routing them through a module would need
# -Global, and nested Import-Module -Force from module scope has clobbered commands
# on this lane before. Usage:
#
#   . (Join-Path $PSScriptRoot '..\modules\Initialize-CiEnvironment.ps1')
#   $repoRoot = Initialize-CiEnvironment -ScriptRoot $PSScriptRoot `
#       -Modules @('WindowsBuild.Common', 'WindowsUv.Common') -EnterRepoRoot

function Initialize-CiEnvironment {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptRoot,
        [string[]]$Modules = @('WindowsBuild.Common'),
        # Resolve the repo root and Set-Location into it; the resolved path is
        # returned as a [string]. WITHOUT this switch the function returns
        # nothing at all -- that contract is kept as-is.
        # WHAT ROOT? Three levels above the calling script = the CONTAINERHUB
        # CHECKOUT ROOT (python -> scripts -> windows -> root). #140
        # (2026-08-21): an earlier comment claimed "the parent of the
        # ContainerHub checkout" — that was never what the code did, and no
        # caller exists anywhere (all local consumer repos verified) that
        # depends on either reading. A vendored consumer
        # (<consumer>/ExternalLib/Kataglyphis-ContainerHub/...) wanting ITS
        # OWN root passes -RepoRoot explicitly.
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
        # [string]: Resolve-Path yields a PathInfo object; callers treat the return
        # value as a plain path string, so hand them exactly that (same textual
        # value -- only the wrapper type changes).
        $resolvedRoot = if ($RepoRoot) { [string](Resolve-Path $RepoRoot) }
        else { [string](Resolve-Path (Join-Path $ScriptRoot '..\..\..')) }
        Set-Location $resolvedRoot
        return $resolvedRoot
    }
}

# ── shared CI-session preamble (#141, 2026-08-21) ────────────────────────────
# One owner for the context/log/wrapper/uv block the four Invoke-Ci* drivers
# carried as ~30-line drifting copies (CiTests had grown two extra wrappers
# the others lacked). Dot-sourcing puts these functions into the CALLER's
# script scope, so $script:CiContext below IS the calling script's variable.

function New-CiSession {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$LogDir = 'logs',
        [switch]$StopOnError,
        # Also wire the uv delegate triple ($script:UvCommandRunner/-LogInfo/
        # -LogWarning) that the packaging/docs/static drivers hand to
        # WindowsUv.Common.
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

