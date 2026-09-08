# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest

# Import shared helpers (Resolve-DirectoryPath, New-Timestamp, etc.)
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
# Guarded, WITHOUT -Force (repo-wide nested-import rule, 2026-08-04): a forced
# nested re-import rebinds the dependency into THIS module's private scope and
# unloads the caller's top-level import — the PS module-scoping trap that broke
# the BuildDriver test suite and forced build-gstreamer's import-Shared-twice
# workaround. Trade-off (accepted): a long-lived dev session that edits Shared
# must Remove-Module/reimport manually; containers always start fresh.
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

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
            # Best-effort handle release before the retry; a GC failure is not actionable.
            Write-Verbose "GC nudge failed: $($_.Exception.Message)"
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
    <#
    .SYNOPSIS
        `uv sync --dev --all-extras`, optionally pinned to the lockfile.
    .PARAMETER RetryWithoutLocked
        With -UseLocked, retry once WITHOUT --locked when uv reports the
        lockfile is out of date. Upstreamed from OrchestrANT
        (2026-08-11), which had re-implemented this whole function locally just
        to get the fallback.

        Why it is opt-in and not the default: --locked exists precisely so CI
        FAILS on an un-regenerated lockfile. Silently syncing unlocked would
        turn a reproducibility gate into a no-op. Pass it only where an
        out-of-date lockfile should degrade to a warning (local dev loops,
        best-effort matrix legs), never on the lane that guards the lockfile.
    #>
    param(
        [switch]$NoBuildIsolationPackageWxPython,
        [switch]$UseLocked,
        [switch]$RetryWithoutLocked,
        [scriptblock]$CommandRunner,
        [scriptblock]$LogInfo,
        [scriptblock]$LogWarning
    )

    $buildArgs = {
        param([bool]$Locked)
        $a = @('-v', 'sync', '--dev', '--all-extras')
        if ($Locked) { $a += '--locked' }
        if ($NoBuildIsolationPackageWxPython) { $a += @('--no-build-isolation-package', 'wxpython') }
        return $a
    }

    try {
        Invoke-UvCommand -Arguments (& $buildArgs $UseLocked.IsPresent) -CommandRunner $CommandRunner -LogInfo $LogInfo
    } catch {
        $message = $_.Exception.Message
        # uv words this two ways depending on version; match both.
        $lockOutdated = $message -match 'lockfile.*needs to be updated' -or $message -match '--locked was provided'
        if (-not ($UseLocked -and $RetryWithoutLocked -and $lockOutdated)) {
            throw
        }
        if ($LogWarning) { & $LogWarning 'uv.lock is out of date; retrying dependency sync without --locked.' }
        Invoke-UvCommand -Arguments (& $buildArgs $false) -CommandRunner $CommandRunner -LogInfo $LogInfo
    }
}

<#
.SYNOPSIS
    Creates a uv environment AND remembers it, so a finally block can tear down
    every environment the run made.
.DESCRIPTION
    New-UvProjectEnvironment creates one; nothing recorded WHICH ones a run created,
    so three drivers (this repo's Invoke-CiTests.ps1, Invoke-CiStaticAnalysis.ps1 and
    OrchestrANT's Build-Windows.ps1) each carried the same script-local
    New-UvEnvironment/Remove-UvEnvironment pair bound to their own $CreatedUvEnvs
    list. Script-local means no other driver could call them.

    Tracker is an ordinary List[string] the caller owns and can inspect; passing it
    explicitly, rather than hiding it in module state, is what lets two independent
    batches run in one session without tearing down each other's environments.
.PARAMETER Tracker
    List the created path is appended to. Create it with
    [System.Collections.Generic.List[string]]::new().
.OUTPUTS
    [string] The environment path, exactly as New-UvProjectEnvironment returned it.
#>
function New-TrackedUvEnvironment {
    param(
        [Parameter(Mandatory)]
        [string]$Workspace,
        [Parameter(Mandatory)]
        [string]$PythonVersion,
        [Parameter(Mandatory)]
        [string]$EnvName,
        # AllowEmptyCollection: a tracker is EMPTY on the first create and on every
        # teardown that runs after an early failure - the exact case the finally
        # block exists for. Mandatory alone rejects an empty collection.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Tracker,
        [scriptblock]$CommandRunner,
        [scriptblock]$LogInfo,
        [scriptblock]$LogWarning
    )

    $envPath = New-UvProjectEnvironment -Workspace $Workspace -PythonVersion $PythonVersion `
        -EnvName $EnvName -CommandRunner $CommandRunner -LogInfo $LogInfo -LogWarning $LogWarning
    $Tracker.Add($envPath) | Out-Null
    return $envPath
}

<#
.SYNOPSIS
    Removes every environment in Tracker and empties it. Safe to call twice.
.DESCRIPTION
    The finally-block half of New-TrackedUvEnvironment. Removal is attempted for
    every entry even when one fails, because leaving the rest behind on a Windows
    runner is how a later run inherits a half-deleted venv.
#>
function Remove-TrackedUvEnvironment {
    param(
        # AllowEmptyCollection: a tracker is EMPTY on the first create and on every
        # teardown that runs after an early failure - the exact case the finally
        # block exists for. Mandatory alone rejects an empty collection.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Tracker,
        [scriptblock]$LogInfo,
        [scriptblock]$LogWarning
    )

    foreach ($envPath in @($Tracker)) {
        try {
            Remove-UvProjectEnvironment -EnvPath $envPath -LogInfo $LogInfo -LogWarning $LogWarning
        } catch {
            if ($LogWarning) { & $LogWarning "Could not remove uv environment ${envPath}: $($_.Exception.Message)" }
        }
    }
    $Tracker.Clear()
}

<#
.SYNOPSIS
    Is this interpreter version one the fleet permits to fail without gating CI?
.DESCRIPTION
    One fleet answer to "which Python may fail". The bash half has been shared since
    linux/scripts/01-core/python_uv.sh:31 (EXPERIMENTAL_PYTHON_VERSIONS, default
    "3.14t"); the PowerShell half was a script-local list inside Invoke-CiTests.ps1,
    so the two could drift silently and a consumer could not consult either.

    Reads the SAME environment knob as the bash half and falls back to the same
    default, so one export sets the policy for both halves of a matrix.
.PARAMETER Version
    Interpreter version as the matrix spells it, e.g. "3.14" or "3.14t".
.OUTPUTS
    [bool]
#>
function Test-ExperimentalPython {
    param(
        [Parameter(Mandatory)]
        [string]$Version
    )

    $configured = $env:EXPERIMENTAL_PYTHON_VERSIONS
    if ([string]::IsNullOrWhiteSpace($configured)) { $configured = "3.14t" }
    $permitted = $configured -split "[,\s]+" | Where-Object { $_ }
    return ($permitted -contains $Version)
}

Export-ModuleMember -Function @(    'New-UvProjectEnvironment',
    'Remove-UvProjectEnvironment',
    'New-TrackedUvEnvironment',
    'Remove-TrackedUvEnvironment',
    'Test-ExperimentalPython',
    'Sync-UvProjectDependencies',
    'Test-UvVenvHealthy',
    'Initialize-UvVenv',
    'Install-UvRequirements',
    # Documented runner seam (CommandRunner/LogInfo injection) - exported so
    # consumers can drive uv through the same code path the module uses.
    'Invoke-UvCommand'
)

