# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
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
        # Resolve the consumer repo root (three levels above the calling script, i.e.
        # the parent of the ContainerHub checkout) and Set-Location into it; the
        # resolved path is returned.
        [switch]$EnterRepoRoot
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
        $repoRoot = Resolve-Path (Join-Path $ScriptRoot '..\..\..')
        Set-Location $repoRoot
        return $repoRoot
    }
}
