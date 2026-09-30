# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest

$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
# No -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level.
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

# Returns the venv's python.exe, reusing a healthy venv and recreating a broken one.
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

    # Set either way so later plain `uv pip install` / `uv run` calls target this venv.
    $env:UV_PROJECT_ENVIRONMENT = $venvPath
    return $venvPython
}

# --python is load-bearing: see docs/python-ci.md § Trap 2 — `UV_PYTHON` beats the activated venv
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
    The `[tool.uv] conflicts` groups of a pyproject.toml, one string[] per group (collect with @(...)).
.DESCRIPTION
    A character walk like the bash twin's (python_uv.sh _uv_conflict_groups), so every layout uv accepts gives
    the same answer; PowerShell ships no TOML parser.
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
    # Plain return: the pipeline unrolls one level, and @(...) at the call site rebuilds the list of groups.
    return $groups
}

<#
.SYNOPSIS
    The extras `uv sync --all-extras` must leave out for a project that declares `[tool.uv] conflicts`.
.DESCRIPTION
    uv refuses --all-extras on such a project. Greedy in declaration order like python_uv.sh
    _uv_extras_to_exclude, so the first-declared member of each family is kept.
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
        `uv sync --dev --all-extras` minus conflicting extras, optionally --locked, then Sync-UvChainOnnxRuntime.
    .PARAMETER RetryWithoutLocked
        With -UseLocked, retry once unlocked on a stale lockfile; never on the lane that guards the lockfile.
    #>
    param(
        [switch]$NoBuildIsolationPackageWxPython,
        [switch]$UseLocked,
        [switch]$RetryWithoutLocked,
        # Defaults to the current directory's, the one `uv sync` reads too.
        [string]$PyprojectPath = (Join-Path (Get-Location).Path 'pyproject.toml'),
        [scriptblock]$CommandRunner,
        [scriptblock]$LogInfo,
        [scriptblock]$LogWarning
    )

    # UV_SYNC_EXTRAS wins; otherwise the same set the Linux twin (python_uv.sh uv_sync_project) syncs.
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

    $projectEnv = if ($env:UV_PROJECT_ENVIRONMENT) { $env:UV_PROJECT_ENVIRONMENT } else { Join-Path (Split-Path -Parent $PyprojectPath) '.venv' }
    Sync-UvChainOnnxRuntime -VenvPath $projectEnv -CommandRunner $CommandRunner -LogInfo $LogInfo -LogWarning $LogWarning
}

<#
.SYNOPSIS
    The chain ORT wheel store: ORT_CHAIN_WHEEL_DIR, PYTHON_WHEELS, then -DefaultStore; $null outside our images.
#>
function Get-ChainOrtWheelStore {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$DefaultStore = 'C:\runtime\wheels')

    foreach ($name in 'ORT_CHAIN_WHEEL_DIR', 'PYTHON_WHEELS') {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    if ($DefaultStore -and (Test-Path -LiteralPath $DefaultStore -PathType Container)) { return $DefaultStore }
    return $null
}

<#
.SYNOPSIS
    The ORT census: the hub checkout's copy, else the image's; with neither, the checkout path so the error names it.
#>
function Get-UvOrtCensusPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$ModuleDir = $PSScriptRoot)

    $candidates = @(
        [IO.Path]::GetFullPath((Join-Path $ModuleDir '..\..\..\linux\scripts\03-media\runtime\ort-venv-census.py')),
        [IO.Path]::GetFullPath((Join-Path $ModuleDir '..\ort-venv-census.py')))
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate } }
    return $candidates[0]
}

# `uv run` re-syncs to the lock and would restore PyPI ORT; release only a hold this module took.
$script:ChainOrtHoldsNoSync = $false
function Set-UvChainOrtSyncHold {
    param([Parameter(Mandatory)][bool]$Hold)
    if ($Hold -and -not $env:UV_NO_SYNC) {
        $env:UV_NO_SYNC = '1'
        $script:ChainOrtHoldsNoSync = $true
    } elseif (-not $Hold -and $script:ChainOrtHoldsNoSync) {
        $env:UV_NO_SYNC = $null
        $script:ChainOrtHoldsNoSync = $false
    }
}

# The interpreter's wheel ABI tag (cp313, cp314t), and which ORT import packages it can find.
$script:ChainOrtAbiCode = 'import sys, sysconfig; print(''cp%d%d%s'' % (*sys.version_info[:2], ''t'' if sysconfig.get_config_var(''Py_GIL_DISABLED'') else ''''))'
$script:ChainOrtFindCode = 'import importlib.util as u, sys; hits = [p for p in (''onnxruntime'', ''onnxruntime_genai'', ''onnxruntime_extensions'') if u.find_spec(p)]; print(*hits); sys.exit(1 if hits else 0)'

# Before uv: every store ORT wheel must fit the venv's ABI tag, or this leg cannot carry ORT inside our images.
function Assert-UvChainOrtAbiFit {
    param([string]$VenvPath, [string]$Python, [string[]]$Wheels, [scriptblock]$Runner)
    $probe = & $Runner $Python @('-I', '-c', $script:ChainOrtAbiCode)
    if ($probe.ExitCode -ne 0) { throw "chain ORT: cannot read the ABI tag of ${Python}: $(@($probe.Output) -join ' | ')" }
    $abi = "$(@($probe.Output) | Select-Object -Last 1)".Trim()
    $misfit = @($Wheels | ForEach-Object { Split-Path $_ -Leaf } | Where-Object { ($_ -replace '\.whl$', '').Split('-')[-2] -notin @($abi, 'abi3', 'none') })
    if ($misfit.Count -gt 0) {
        throw "chain ORT: $VenvPath is a $abi venv, and the chain wheels are built for the image interpreter: $($misfit -join ' '). An ORT project runs its in-image legs on that interpreter: drop this leg or list it in EXPERIMENTAL_PYTHON_VERSIONS."
    }
}

# With no ORT distribution to purge, nothing may import as ORT either (an unowned copy, a dist without a Name).
function Assert-UvChainOrtNoUnownedImport {
    param([string]$VenvPath, [string]$Python, [string]$WheelStore, [string]$CensusPath, [scriptblock]$Runner)
    $found = & $Runner $Python @('-I', '-c', $script:ChainOrtFindCode)
    if ($found.ExitCode -eq 0) { return }
    $census = & $Runner $Python @('-I', $CensusPath, '--check', '--store', $WheelStore)
    throw "chain ORT: $VenvPath imports ONNX Runtime with no distribution to purge ($(@($found.Output) -join ' ')):`n$(@($census.Output) -join "`n")"
}

<#
.SYNOPSIS
    Moves a synced venv's ONNX Runtime onto the image's chain wheels, proven by the census; outside our images warns.
.DESCRIPTION
    See docs/python-ci.md#trap-3--onnx-runtime-comes-from-the-chain-not-pypi
.PARAMETER PythonRunner
    Test seam: { param($python, $arguments) } returning @{ ExitCode; Output }. Default runs the interpreter.
#>
function Sync-UvChainOnnxRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VenvPath,
        [AllowEmptyString()][string]$WheelStore = (Get-ChainOrtWheelStore),
        [string]$CensusPath = '',
        [scriptblock]$CommandRunner,
        [scriptblock]$PythonRunner,
        [scriptblock]$LogInfo,
        [scriptblock]$LogWarning
    )

    if (-not $CensusPath) { $CensusPath = Get-UvOrtCensusPath }
    $say = if ($LogInfo) { $LogInfo } else { { param($m) Write-Host $m } }
    $warn = if ($LogWarning) { $LogWarning } else { { param($m) Write-Warning $m } }
    $run = if ($PythonRunner) { $PythonRunner } else {
        {
            param($exe, $arguments)
            $PSNativeCommandUseErrorActionPreference = $false
            try { $out = @(& $exe @arguments 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
            catch { $out = @("$($_.Exception.Message)"); $code = 127 }
            [pscustomobject]@{ ExitCode = $code; Output = $out }
        }
    }
    $python = Join-Path $VenvPath 'Scripts\python.exe'
    $inImage = -not [string]::IsNullOrWhiteSpace($WheelStore)
    $missing = @(@($WheelStore, $python, $CensusPath) | Where-Object { $_ -and -not (Test-Path -LiteralPath $_) })
    if ($inImage -and ($missing.Count -gt 0 -or -not (Test-Path -LiteralPath $WheelStore -PathType Container))) {
        throw "chain ORT: need the store $WheelStore, the interpreter $python and the census $CensusPath (missing: $($missing -join ', '))"
    }
    if ($missing.Count -gt 0) {
        $why = "chain ORT: $VenvPath not inspected (missing: $($missing -join ', ')); ONNX Runtime provenance unchecked"
        if ($LogInfo) { & $LogInfo $why } else { Write-Verbose $why }
        return
    }

    $listed = & $run $python @('-I', $CensusPath, '--purge-list')
    if ($listed.ExitCode -ne 0) {
        $why = "chain ORT: cannot list ${VenvPath}: $(@($listed.Output) -join ' | ')"
        if ($inImage) { throw $why }
        & $warn $why
        return
    }
    $names = @(@($listed.Output) | ForEach-Object { if ("$_" -match '^ORT-CENSUS PURGE ([a-z0-9][a-z0-9-]*)$') { $Matches[1] } })
    if ($names.Count -eq 0) {
        if ($inImage) { Assert-UvChainOrtNoUnownedImport -VenvPath $VenvPath -Python $python -WheelStore $WheelStore -CensusPath $CensusPath -Runner $run }
        Set-UvChainOrtSyncHold -Hold $false
        return
    }
    if (-not $inImage) {
        & $warn "==== NOTICE: $VenvPath runs ONNX Runtime from outside the chain: $($names -join ' ') ===="
        & $warn '  No chain wheel store here (ORT_CHAIN_WHEEL_DIR/PYTHON_WHEELS unset, no C:\runtime\wheels), so it stays as uv resolved it;'
        & $warn '  inside our images it is reconciled onto the chain wheels or the sync fails.'
        return
    }

    $wheels = @(Get-ChildItem -LiteralPath $WheelStore -File | Where-Object { $_.Name -match '^onnxruntime[-_].*\.whl$' } | ForEach-Object { $_.FullName })
    if ($wheels.Count -eq 0) { throw "chain ORT: the store $WheelStore holds no onnxruntime wheel for $($names -join ' ')" }
    Assert-UvChainOrtAbiFit -VenvPath $VenvPath -Python $python -Wheels $wheels -Runner $run
    & $say "chain ORT: replacing $($names -join ' ') in $VenvPath with $(($wheels | ForEach-Object { Split-Path $_ -Leaf }) -join ' ')"
    Invoke-UvCommand -Arguments (@('pip', 'uninstall', '--python', $python) + $names) -CommandRunner $CommandRunner -LogInfo $LogInfo
    try {
        Invoke-UvCommand -Arguments (@('pip', 'install', '--python', $python, '--no-index', '--no-deps', '--force-reinstall') + $wheels) `
            -CommandRunner $CommandRunner -LogInfo $LogInfo
    } catch {
        throw "chain ORT: $VenvPath does not take the chain wheels: $($_.Exception.Message)"
    }
    $check = & $run $python @('-I', $CensusPath, '--check', '--store', $WheelStore)
    if ($check.ExitCode -ne 0) { throw "chain ORT: $VenvPath still carries a non-chain ONNX Runtime:`n$(@($check.Output) -join "`n")" }
    & $say (@($check.Output) -join "`n")
    $import = & $run $python @('-I', '-c', 'import sys; print(sys.version); import onnxruntime')
    if ($import.ExitCode -ne 0) {
        throw "chain ORT: the chain onnxruntime does not import in $VenvPath (the store is built for the image interpreter):`n$(@($import.Output) -join "`n")"
    }
    Set-UvChainOrtSyncHold -Hold $true
}

<#
.SYNOPSIS
    Creates a uv environment and records it in -Tracker, so a finally block can tear down every one the run made.
.DESCRIPTION
    The caller owns the tracker, so two batches in one session never tear down each other's environments.
.PARAMETER Tracker
    A [System.Collections.Generic.List[string]] the created path is appended to.
#>
function New-TrackedUvEnvironment {
    param(
        [Parameter(Mandatory)]
        [string]$Workspace,
        [Parameter(Mandatory)]
        [string]$PythonVersion,
        [Parameter(Mandatory)]
        [string]$EnvName,
        # Mandatory alone rejects the empty tracker of a first create or an early failure.
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
    Removes every environment in -Tracker and empties it; safe to call twice.
.DESCRIPTION
    Every entry is attempted even when one fails, so a later run does not inherit leftover venvs.
#>
function Remove-TrackedUvEnvironment {
    param(
        # Mandatory alone rejects the empty tracker of a first create or an early failure.
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
    True when the fleet permits this interpreter version to fail without gating CI.
.DESCRIPTION
    Reads EXPERIMENTAL_PYTHON_VERSIONS with the same default as python_uv.sh, so one export sets both halves.
.PARAMETER Version
    Interpreter version as the matrix spells it, e.g. "3.14" or "3.14t".
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
    'Sync-UvChainOnnxRuntime',
    'Get-ChainOrtWheelStore',
    'Get-UvOrtCensusPath',
    'Get-UvConflictGroups',
    'Get-UvExtrasToExclude',
    'Test-UvVenvHealthy',
    'Initialize-UvVenv',
    'Install-UvRequirements',
    # Exported runner seam, so consumers drive uv through the module's own code path.
    'Invoke-UvCommand'
)

