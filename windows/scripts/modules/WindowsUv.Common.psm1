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

<#
.SYNOPSIS
    The `[tool.uv] conflicts` groups of a pyproject.toml, as arrays of extra names.
.DESCRIPTION
    Reads the table the way the bash twin (01-core/python_uv.sh
    _uv_conflict_groups) does: a character walk from the `conflicts =` line,
    depth-2 brackets delimit one group, `extra = "name"` occurrences inside it
    are the members - so the inline, multi-line and mixed layouts uv accepts
    all give the same answer. No TOML parser ships with PowerShell, and one
    key is not worth a dependency.
.OUTPUTS
    One string[] per group, in declaration order, written to the pipeline one
    group at a time (collect with @(...)); nothing when the file has no
    conflicts table.
#>
function Get-UvConflictGroups {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$PyprojectPath)

    $groups = @()
    $inBlock = $false
    $depth = 0
    $group = ''
    foreach ($line in (Get-Content -LiteralPath $PyprojectPath)) {
        if (-not $inBlock) {
            if ($line -match '^\s*conflicts\s*=') { $inBlock = $true; $depth = 0; $group = '' } else { continue }
        }
        foreach ($c in $line.ToCharArray()) {
            if ($c -eq '[') {
                $depth++
                if ($depth -eq 2) { $group = '' }
            } elseif ($c -eq ']') {
                if ($depth -eq 2) {
                    $extras = @([regex]::Matches($group, 'extra\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
                    if ($extras.Count -gt 0) { $groups += , [string[]]$extras }
                    $group = ''
                }
                $depth--
                if ($depth -le 0) { $inBlock = $false; break }
            } elseif ($depth -ge 2) {
                $group += $c
            }
        }
        if ($inBlock -and $depth -ge 2) { $group += ' ' }
    }
    # Plain return: the pipeline unrolls ONE level, so each string[] group
    # arrives as one object and @(...) at the call site rebuilds the list. A
    # comma-wrapped return here plus @() at the caller nested it twice (the
    # first cut of this function, caught by Uv.ConflictExtras.Tests.ps1).
    return $groups
}

<#
.SYNOPSIS
    The extras `uv sync --all-extras` must leave out for a project that
    declares `[tool.uv] conflicts`.
.DESCRIPTION
    uv refuses --all-extras outright on such a project ("Extras `a` and `b` are
    incompatible with the declared conflicts") and has no "install as much as
    possible" flag. Greedy over the groups in DECLARATION ORDER, exactly as
    01-core/python_uv.sh _uv_extras_to_exclude does: keep an extra unless it
    conflicts with one already kept, otherwise exclude it. That keeps the
    first-declared member of each family - for OrchestrANT `ml-ai` and
    `pytorch-cpu`, the pair its CI wants.
.OUTPUTS
    The extras to pass as --no-extra, one string per pipeline object (collect
    with @(...)); nothing when nothing conflicts or the file does not exist.
#>
function Get-UvExtrasToExclude {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$PyprojectPath)

    if (-not (Test-Path -LiteralPath $PyprojectPath)) { return }
    $groups = @(Get-UvConflictGroups -PyprojectPath $PyprojectPath)
    $keep = [System.Collections.Generic.List[string]]::new()
    $drop = [System.Collections.Generic.List[string]]::new()
    foreach ($group in $groups) {
        foreach ($extra in $group) {
            if ($keep.Contains($extra) -or $drop.Contains($extra)) { continue }
            $conflicted = $false
            foreach ($other in $groups) {
                if ($other -notcontains $extra) { continue }
                foreach ($member in $other) {
                    if ($member -ne $extra -and $keep.Contains($member)) { $conflicted = $true }
                }
            }
            if ($conflicted) { $drop.Add($extra) } else { $keep.Add($extra) }
        }
    }
    return $drop.ToArray()
}

function Sync-UvProjectDependencies {
    <#
    .SYNOPSIS
        `uv sync --dev --all-extras`, optionally pinned to the lockfile, with the
        extras that declared conflicts forbid excluded (see Get-UvExtrasToExclude).
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
        # The pyproject whose `[tool.uv] conflicts` decide which extras
        # --all-extras must leave out. Defaults to the one in the current
        # directory, which is where `uv sync` reads it too.
        [string]$PyprojectPath = (Join-Path (Get-Location).Path 'pyproject.toml'),
        [scriptblock]$CommandRunner,
        [scriptblock]$LogInfo,
        [scriptblock]$LogWarning
    )

    # Which extras. UV_SYNC_EXTRAS wins (the project knows best); otherwise
    # --all-extras minus whatever the declared conflicts make unsatisfiable -
    # the same choice the Linux twin (01-core/python_uv.sh uv_sync_project)
    # makes, so the two lanes sync the same set. OrchestrANT's Windows lane was
    # red from 2026-09-12 to 2026-09-14 because only the Linux half did this.
    $extraArgs = @()
    $wanted = [Environment]::GetEnvironmentVariable('UV_SYNC_EXTRAS')
    if (-not [string]::IsNullOrWhiteSpace($wanted)) {
        foreach ($extra in ($wanted -split '[,\s]+')) {
            if ($extra) { $extraArgs += @('--extra', $extra) }
        }
        if ($LogInfo) { & $LogInfo "UV_SYNC_EXTRAS set - syncing extras: $wanted" }
    } else {
        $extraArgs = @('--all-extras')
        $excluded = @(Get-UvExtrasToExclude -PyprojectPath $PyprojectPath)
        if ($excluded.Count -gt 0) {
            if ($LogInfo) {
                & $LogInfo ('Project declares conflicting extras; --all-extras alone would fail. Excluding (keeping the first-declared of each family): {0}. Set UV_SYNC_EXTRAS to choose a different combination.' -f ($excluded -join ' '))
            }
            foreach ($extra in $excluded) { $extraArgs += @('--no-extra', $extra) }
        }
    }

    $buildArgs = {
        param([bool]$Locked)
        $a = @('-v', 'sync', '--dev') + $extraArgs
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
    'Get-UvConflictGroups',
    'Get-UvExtrasToExclude',
    'Test-UvVenvHealthy',
    'Initialize-UvVenv',
    'Install-UvRequirements',
    # Documented runner seam (CommandRunner/LogInfo injection) - exported so
    # consumers can drive uv through the same code path the module uses.
    'Invoke-UvCommand'
)

