# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

Set-StrictMode -Version Latest

# Import shared helpers (Resolve-DirectoryPath, New-Timestamp, etc.)
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -Force

function Invoke-UvCommand {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [scriptblock]$CommandRunner,
        [scriptblock]$LogInfo
    )

    if ($LogInfo) {
        & $LogInfo "Running uv command: uv $($Arguments -join ' ')"
    }

    if ($CommandRunner) {
        & $CommandRunner 'uv' $Arguments
        return
    }

    & uv @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw ('Command failed with exit code {0}: uv {1}' -f $LASTEXITCODE, ($Arguments -join ' '))
    }
}

function Remove-UvProjectEnvironment {
    param(
        [Parameter(Mandatory)]
        [string]$EnvPath,
        [scriptblock]$LogInfo,
        [scriptblock]$LogWarning,
        [int]$MaxAttempts = 8
    )

    if (-not $EnvPath) {
        return
    }

    if ($env:UV_PROJECT_ENVIRONMENT -eq $EnvPath) {
        $env:UV_PROJECT_ENVIRONMENT = $null
    }

    if (-not (Test-Path -Path $EnvPath)) {
        return
    }

    if ($LogInfo) {
        & $LogInfo "Removing uv environment: $EnvPath"
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $removeErrors = @()
        Remove-Item -Path $EnvPath -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +removeErrors
        if (-not (Test-Path -Path $EnvPath)) {
            return
        }

        try {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
        } catch {
        }

        $lastError = $null
        $removeErrors = @($removeErrors)
        if ($removeErrors -and $removeErrors.Count -gt 0) {
            $lastError = $removeErrors[-1].Exception.Message
        }

        if ($LogWarning) {
            & $LogWarning "Failed to remove environment '$EnvPath' (attempt $attempt/$MaxAttempts). $lastError"
        }

        Start-Sleep -Seconds 2
    }
}

function New-UvProjectEnvironment {
    param(
        [Parameter(Mandatory)]
        [string]$Workspace,
        [Parameter(Mandatory)]
        [string]$PythonVersion,
        [Parameter(Mandatory)]
        [string]$EnvName,
        [scriptblock]$CommandRunner,
        [scriptblock]$LogInfo,
        [scriptblock]$LogWarning
    )

    if ([System.IO.Path]::IsPathRooted($EnvName)) {
        $envPath = $EnvName
    } else {
        $envPath = Join-Path $Workspace $EnvName
    }

    $envParent = Split-Path -Path $envPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($envParent)) {
        Resolve-DirectoryPath -Path $envParent | Out-Null
    }

    if ($LogInfo) {
        & $LogInfo "Creating uv environment: $envPath (Python $PythonVersion)"
    }

    if (Test-Path -Path $envPath) {
        Remove-UvProjectEnvironment -EnvPath $envPath -LogInfo $LogInfo -LogWarning $LogWarning
    }

    Invoke-UvCommand -Arguments @('venv', '--python', $PythonVersion, '--clear', $envPath) -CommandRunner $CommandRunner -LogInfo $null

    $env:UV_PROJECT_ENVIRONMENT = $envPath
    return $envPath
}

function Test-UvVenvHealthy {
    param(
        [Parameter(Mandatory)]
        [string]$VenvPath,
        [scriptblock]$LogWarning
    )

    $venvPython = Join-Path $VenvPath 'Scripts\python.exe'
    if (-not (Test-Path $venvPython)) {
        return $false
    }

    try {
        & $venvPython '-c' 'import sys; sys.exit(0)' 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            if ($LogWarning) { & $LogWarning "Existing venv at $VenvPath is not functional; recreating." }
            return $false
        }
    } catch {
        if ($LogWarning) { & $LogWarning "Existing venv at $VenvPath is not functional; recreating." }
        return $false
    }

    return $true
}

# Ensure a usable uv venv exists at Workspace\EnvName: reuse it when healthy
# (interpreter present and runnable), recreate it via New-UvProjectEnvironment
# otherwise. Returns the path to the venv's python.exe. Consolidates the
# health-check/recreate logic previously duplicated across downstream
# formatting and WebDAV modules.
function Initialize-UvVenv {
    param(
        [Parameter(Mandatory)]
        [string]$Workspace,
        [string]$PythonVersion = '3.12',
        [string]$EnvName = '.venv',
        [scriptblock]$CommandRunner,
        [scriptblock]$LogInfo,
        [scriptblock]$LogWarning
    )

    if ([System.IO.Path]::IsPathRooted($EnvName)) {
        $venvPath = $EnvName
    } else {
        $venvPath = Join-Path $Workspace $EnvName
    }
    $venvPython = Join-Path $venvPath 'Scripts\python.exe'

    if (Test-UvVenvHealthy -VenvPath $venvPath -LogWarning $LogWarning) {
        if ($LogInfo) { & $LogInfo "Reusing existing uv venv at: $venvPath" }
    } else {
        New-UvProjectEnvironment -Workspace $Workspace -PythonVersion $PythonVersion -EnvName $EnvName `
            -CommandRunner $CommandRunner -LogInfo $LogInfo -LogWarning $LogWarning | Out-Null
    }

    # Point uv's project-environment resolution at this venv either way so
    # subsequent plain `uv pip install` / `uv run` calls target it.
    $env:UV_PROJECT_ENVIRONMENT = $venvPath
    return $venvPython
}

# Install a requirements file into a specific venv. The --python pin is
# deliberate and load-bearing: uv honours UV_PYTHON OVER the activated or
# project venv, and the CI container images export UV_PYTHON to their
# root-owned system venv - so an unpinned `uv pip install` would target that
# environment and die with "Permission denied (os error 13)" for non-root CI
# users. --python forces the writable target venv.
function Install-UvRequirements {
    param(
        [Parameter(Mandatory)]
        [string]$VenvPython,
        [Parameter(Mandatory)]
        [string]$RequirementsPath,
        [scriptblock]$CommandRunner,
        [scriptblock]$LogInfo
    )

    Invoke-UvCommand -Arguments @('pip', 'install', '--python', $VenvPython, '-r', $RequirementsPath) `
        -CommandRunner $CommandRunner -LogInfo $LogInfo
}

function Sync-UvProjectDependencies {
    param(
        [switch]$NoBuildIsolationPackageWxPython,
        [switch]$UseLocked,
        [scriptblock]$CommandRunner,
        [scriptblock]$LogInfo
    )

    $syncArgs = @('-v', 'sync', '--dev', '--all-extras')
    if ($UseLocked) {
        $syncArgs += '--locked'
    }
    if ($NoBuildIsolationPackageWxPython) {
        $syncArgs += @('--no-build-isolation-package', 'wxpython')
    }

    Invoke-UvCommand -Arguments $syncArgs -CommandRunner $CommandRunner -LogInfo $LogInfo
}

Export-ModuleMember -Function @(
    'New-UvProjectEnvironment',
    'Remove-UvProjectEnvironment',
    'Sync-UvProjectDependencies',
    'Test-UvVenvHealthy',
    'Initialize-UvVenv',
    'Install-UvRequirements'
)

