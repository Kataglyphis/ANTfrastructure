# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'WindowsUvLock.Common.psm1') -ErrorAction Stop

$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
# No -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level.
Import-Module $sharedPath -ErrorAction Stop
# Get-PinnedPythonVersion, for the pinned defaults of Initialize-UvVenv and Test-ExperimentalPython.
$pythonWheelPath = Join-Path $PSScriptRoot 'WindowsPythonWheel.Common.psm1'
Import-Module $pythonWheelPath -ErrorAction Stop

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

function Get-UvPythonRequest {
    <#
    .SYNOPSIS
        uv's discovery request for a version: X.Y[.Z] becomes X.Y[.Z]+gil; X.Yt, paths and variants pass unchanged.
    .DESCRIPTION
        uv 0.12 lets a plain X.Y take a free-threaded build an X.Yt leg downloaded; the twin of python_uv.sh's uv_python_request.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Version)
    if ($Version -match '^\d+(\.\d+)*$') { return "$Version+gil" }
    return $Version
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
        [scriptblock]$LogWarning,
        # Test seam: whether uv already finds an interpreter for a request.
        [scriptblock]$PythonFinder = { param($request) & uv python find $request *> $null; return $LASTEXITCODE -eq 0 }
    )

    $envPath = Resolve-PathFromRoot -Root $Workspace -Path $EnvName

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

    $request = Get-UvPythonRequest -Version $PythonVersion
    # uv downloads nothing for a +gil request (OmniAccelerANT's 3.12, 2026-10-01); a bare install fetches the GIL build.
    if ($request -ne $PythonVersion -and -not (& $PythonFinder $request)) {
        Invoke-UvCommand -Arguments @('python', 'install', $PythonVersion) -CommandRunner $CommandRunner -LogInfo $LogInfo
    }
    Invoke-UvCommand -Arguments @('venv', '--python', $request, '--clear', $envPath) -CommandRunner $CommandRunner -LogInfo $null

    $env:UV_PROJECT_ENVIRONMENT = $envPath
    return $envPath
}

function Test-UvVenvHealthy {
    param(
        [Parameter(Mandatory)]
        [string]$VenvPath,
        # X.Y[.Z] or X.Yt: a venv on another interpreter is stale, so a pin bump recreates it; a path checks only that it runs.
        [string]$PythonVersion = '',
        [scriptblock]$LogWarning,
        # Test seam: the venv interpreter's X.Y or X.Yt, nothing when it does not run.
        [scriptblock]$VersionReader = {
            param($python)
            $v = & $python -c "import sys, sysconfig; print('%d.%d%s' % (*sys.version_info[:2], 't' if sysconfig.get_config_var('Py_GIL_DISABLED') else ''))" 2>$null
            if ($LASTEXITCODE -eq 0) { "$v".Trim() }
        }
    )

    $venvPython = Join-Path $VenvPath 'Scripts\python.exe'
    if (-not (Test-Path $venvPython)) {
        return $false
    }

    $actual = try { & $VersionReader $venvPython } catch { $null }
    if (-not $actual) {
        if ($LogWarning) { & $LogWarning "Existing venv at $VenvPath is not functional; recreating." }
        return $false
    }
    if ($PythonVersion -match '^(\d+)\.(\d+)(?:\.\d+)?(t?)$' -and $actual -cne "$($Matches[1]).$($Matches[2])$($Matches[3])") {
        if ($LogWarning) { & $LogWarning "Existing venv at $VenvPath runs Python $actual, not $PythonVersion; recreating." }
        return $false
    }

    return $true
}

# Returns the venv's python.exe, reusing a healthy venv and recreating a broken or stale one.
function Initialize-UvVenv {
    param(
        [Parameter(Mandatory)]
        [string]$Workspace,
        # Empty is the pin's X.Y, which the images carry, so uv downloads nothing there.
        [string]$PythonVersion = '',
        [string]$EnvName = '.venv',
        [scriptblock]$CommandRunner,
        [scriptblock]$LogInfo,
        [scriptblock]$LogWarning
    )

    if (-not $PythonVersion) { $PythonVersion = (Get-PinnedPythonVersion).MajorMinor }
    $venvPath = Resolve-PathFromRoot -Root $Workspace -Path $EnvName
    $venvPython = Join-Path $venvPath 'Scripts\python.exe'

    if (Test-UvVenvHealthy -VenvPath $venvPath -PythonVersion $PythonVersion -LogWarning $LogWarning) {
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

    # cmake-format 0.6.13 dies on 3.15's re.Scanner; the helper patches its lexer and is a no-op without it.
    $compat = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\linux\scripts\lib\cmakelang-py315.py'))
    if (-not (Test-Path -LiteralPath $compat -PathType Leaf)) { throw "the hub's $compat is missing: a broken checkout" }
    if ($CommandRunner) {
        & $CommandRunner $VenvPython @('-I', $compat)
        return
    }
    & $VenvPython -I $compat
    if ($LASTEXITCODE -ne 0) { throw "cmakelang-py315.py failed in ${VenvPython} with exit code $LASTEXITCODE" }
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

<#
.SYNOPSIS
    The ONNX Runtime distributions -LockPath pins (onnxruntime, onnxruntime-*), PEP 503 normalised; @() without a lock.
#>
function Get-UvLockOrtName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$LockPath)
    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) { return @() }
    return Get-OrtLockPackageName -LockPath $LockPath -DiagnosticPrefix 'chain ORT: '
}

function Get-UvSyncExtraArgs {
    param([string]$PyprojectPath, [scriptblock]$LogInfo)
    # UV_SYNC_EXTRAS wins over the Linux twin's keep-first conflict choice.
    $wanted = [Environment]::GetEnvironmentVariable('UV_SYNC_EXTRAS')
    if (-not [string]::IsNullOrWhiteSpace($wanted)) {
        $extraArgs = @()
        foreach ($extra in ($wanted -split '[,\s]+')) {
            if ($extra) { $extraArgs += @('--extra', $extra) }
        }
        if ($LogInfo) { & $LogInfo "UV_SYNC_EXTRAS set - syncing extras: $wanted" }
        return $extraArgs
    }
    $extraArgs = @('--all-extras')
    $excluded = @(Get-UvExtrasToExclude -PyprojectPath $PyprojectPath)
    if ($excluded.Count -gt 0) {
        if ($LogInfo) {
            & $LogInfo ('Project declares conflicting extras; --all-extras alone would fail. Excluding (keeping the first-declared of each family): {0}. Set UV_SYNC_EXTRAS to choose a different combination.' -f ($excluded -join ' '))
        }
        foreach ($extra in $excluded) { $extraArgs += @('--no-extra', $extra) }
    }
    return $extraArgs
}

function Sync-UvProjectDependencies {
    <#
    .SYNOPSIS
        `uv sync --dev --all-extras` minus conflicting extras, optionally --locked, then Sync-UvChainOnnxRuntime.
    .DESCRIPTION
        Inside our images the sync leaves the lock's ONNX Runtime to the chain wheels, as Linux's uv_sync_project does.
    .PARAMETER RetryWithoutLocked
        With -UseLocked, retry once unlocked on a stale lockfile; never on the lane that guards the lockfile.
    #>
    param(
        [switch]$UseLocked,
        [switch]$RetryWithoutLocked,
        # Defaults to the current directory's, the one `uv sync` reads too.
        [string]$PyprojectPath = (Join-Path (Get-Location).Path 'pyproject.toml'),
        [scriptblock]$CommandRunner,
        # Test seam for Sync-UvChainOnnxRuntime's interpreter calls.
        [scriptblock]$PythonRunner,
        [scriptblock]$LogInfo,
        [scriptblock]$LogWarning
    )

    $extraArgs = @(Get-UvSyncExtraArgs -PyprojectPath $PyprojectPath -LogInfo $LogInfo)

    # PyPI's ORT lags a new Python by months; the reconcile below installs the chain's for what the sync leaves out.
    $wheelStore = Get-ChainOrtWheelStore
    $skippedOrt = @(if ($wheelStore) { Get-UvLockOrtName -LockPath (Join-Path (Split-Path -Parent $PyprojectPath) 'uv.lock') })
    $skipArgs = @($skippedOrt | ForEach-Object { '--no-install-package', $_ })
    if ($skippedOrt.Count -gt 0 -and $LogInfo) { & $LogInfo "chain ORT: the sync leaves $($skippedOrt -join ' ') to the chain wheels" }

    $buildArgs = {
        param([bool]$Locked)
        $a = @('-v', 'sync', '--dev') + $extraArgs
        if ($Locked) { $a += '--locked' }
        $a += $skipArgs
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
    Sync-UvChainOnnxRuntime -VenvPath $projectEnv -WheelStore $wheelStore -Skipped $skippedOrt -CommandRunner $CommandRunner -PythonRunner $PythonRunner -LogInfo $LogInfo -LogWarning $LogWarning
    Sync-UvChainOpenCv -VenvPath $projectEnv -CommandRunner $CommandRunner -LogInfo $LogInfo
}

function Sync-UvChainOpenCv {
    <#
    .SYNOPSIS
        Swaps a PyPI OpenCV in the venv for the image's own cv2; a no-op outside our images or without OpenCV.
    .DESCRIPTION
        PyPI's cv2.pyd imports Media Foundation, which the Server Core image lacks, so `import cv2` fails there.
        The copy's config names the image dirs its DLL closure lives in (Copy-ChainOpenCvPackage -ReferenceImage).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VenvPath,
        [string]$Source = 'C:\temp\cpython\Lib\site-packages\cv2',
        [string]$RuntimeRoot = 'C:\runtime',
        [scriptblock]$CommandRunner,
        [scriptblock]$LogInfo
    )

    $sitePackages = Join-Path $VenvPath 'Lib\site-packages'
    if (-not (Test-Path -LiteralPath (Join-Path $Source '__init__.py') -PathType Leaf) -or -not (Test-Path -LiteralPath $sitePackages)) { return }
    $installed = @(Get-ChildItem -LiteralPath $sitePackages -Directory -Filter 'opencv*.dist-info' |
        ForEach-Object { $_.Name -replace '-[^-]+\.dist-info$', '' })
    if ($installed.Count -eq 0) { return }
    $message = "chain OpenCV: replacing $($installed -join ', ') in $VenvPath with the image's cv2 (PyPI's imports Media Foundation)"
    if ($LogInfo) { & $LogInfo $message } else { Write-Host $message }
    $python = Join-Path $VenvPath 'Scripts\python.exe'
    Invoke-UvCommand -Arguments (@('pip', 'uninstall', '--python', $python) + $installed) -CommandRunner $CommandRunner -LogInfo $null
    # Only here, inside the image: the host-side lanes never load the PE walker.
    if (-not (Get-Module -Name 'WindowsPythonApp.Common')) { Import-Module (Join-Path $PSScriptRoot 'WindowsPythonApp.Common.psm1') -DisableNameChecking }
    $dirs = @(Copy-ChainOpenCvPackage -SitePackages $sitePackages -Source $Source -RuntimeRoot $RuntimeRoot -ReferenceImage)
    # `uv run` would reinstall PyPI's opencv just as it would PyPI ORT, also in a venv the ORT reconcile left alone.
    Set-UvChainOrtSyncHold -Hold $true
    $message = "chain OpenCV: cv2 loads its DLLs from $($dirs -join '; ')"
    if ($LogInfo) { & $LogInfo $message } else { Write-Host $message }
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

    return Resolve-SharedLinuxScriptFile -RepoPath 'linux\scripts\03-media\runtime\ort-venv-census.py' -ModuleDir $ModuleDir
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

# Which ORT import packages the interpreter can find.
$script:ChainOrtFindCode = 'import importlib.util as u, sys; hits = [p for p in (''onnxruntime'', ''onnxruntime_genai'', ''onnxruntime_extensions'') if u.find_spec(p)]; print(*hits); sys.exit(1 if hits else 0)'

function Get-UvChainOrtPythonAbi {
    param([string]$Python, [scriptblock]$Runner)
    $probe = Invoke-PythonAbiProbe -Python $Python -Runner $Runner -Isolated
    return [pscustomobject]@{
        ExitCode = $probe.ExitCode
        Result = $probe
        Abi = $probe.Abi
    }
}

# Before uv: every store ORT wheel must fit the venv's ABI tag, or this leg cannot carry ORT inside our images.
function Assert-UvChainOrtAbiFit {
    param([string]$VenvPath, [string]$Python, [string[]]$Wheels, [scriptblock]$Runner)
    $probe = Get-UvChainOrtPythonAbi -Python $Python -Runner $Runner
    if ($probe.ExitCode -ne 0) { throw "chain ORT: cannot read the ABI tag of ${Python}: $(@($probe.Result.Output) -join ' | ')" }
    $abi = $probe.Abi
    $misfit = @($Wheels | ForEach-Object { Split-Path $_ -Leaf } | Where-Object { ($_ -replace '\.whl$', '').Split('-')[-2] -notin @($abi, 'abi3', 'none') })
    if ($misfit.Count -gt 0) {
        throw "chain ORT: $VenvPath is a $abi venv, and the chain wheels are built for the image interpreter: $($misfit -join ' '). An ORT project runs its in-image legs on that interpreter: drop this leg or list it in EXPERIMENTAL_PYTHON_VERSIONS."
    }
}

# A free-threaded venv takes the image's cp3XYt twins (PYTHON_WHEELS_FREE_THREADED, else images before CON91's PYTHON_WHEELS_CP314T); docs/windows-builds.md#the-free-threaded-wheels
function Select-UvChainOrtWheelStore {
    param([string]$WheelStore, [string]$Python, [scriptblock]$Runner)
    $twins = [Environment]::GetEnvironmentVariable('PYTHON_WHEELS_FREE_THREADED')
    if (-not $twins) { $twins = [Environment]::GetEnvironmentVariable('PYTHON_WHEELS_CP314T') }
    if (-not $twins -or -not (Test-Path -LiteralPath $twins -PathType Container)) { return $WheelStore }
    $probe = Get-UvChainOrtPythonAbi -Python $Python -Runner $Runner
    if ($probe.ExitCode -eq 0 -and $probe.Abi -match '^cp\d+t$') { return $twins }
    return $WheelStore
}

# With no ORT distribution to purge, nothing may import as ORT either (an unowned copy, a dist without a Name).
function Assert-UvChainOrtNoUnownedImport {
    param([string]$VenvPath, [string]$Python, [string]$WheelStore, [string]$CensusPath, [scriptblock]$Runner)
    $found = & $Runner $Python @('-I', '-c', $script:ChainOrtFindCode)
    if ($found.ExitCode -eq 0) { return }
    $census = & $Runner $Python @('-I', $CensusPath, '--check', '--store', $WheelStore)
    throw "chain ORT: $VenvPath imports ONNX Runtime with no distribution to purge ($(@($found.Output) -join ' ')):`n$(@($census.Output) -join "`n")"
}

function Get-UvChainOrtRunner {
    param([scriptblock]$PythonRunner)
    if ($PythonRunner) { return $PythonRunner }
    return {
        param($exe, $arguments)
        $PSNativeCommandUseErrorActionPreference = $false
        try { $out = @(& $exe @arguments 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
        catch { $out = @("$($_.Exception.Message)"); $code = 127 }
        [pscustomobject]@{ ExitCode = $code; Output = $out }
    }
}

function Test-UvChainOrtInputs {
    param([string]$VenvPath, [string]$WheelStore, [string]$Python, [string]$CensusPath,
        [bool]$InImage, [scriptblock]$LogInfo)
    $missing = @(@($WheelStore, $Python, $CensusPath) | Where-Object { $_ -and -not (Test-Path -LiteralPath $_) })
    if ($InImage -and ($missing.Count -gt 0 -or -not (Test-Path -LiteralPath $WheelStore -PathType Container))) {
        throw "chain ORT: need the store $WheelStore, the interpreter $Python and the census $CensusPath (missing: $($missing -join ', '))"
    }
    if ($missing.Count -eq 0) { return $true }
    $why = "chain ORT: $VenvPath not inspected (missing: $($missing -join ', ')); ONNX Runtime provenance unchecked"
    if ($LogInfo) { & $LogInfo $why } else { Write-Verbose $why }
    return $false
}

function Get-UvChainOrtSelection {
    param([string]$VenvPath, [string]$Python, [string]$CensusPath, [string[]]$Skipped,
        [bool]$InImage, [scriptblock]$Runner, [scriptblock]$Warn)
    $listed = & $Runner $Python @('-I', $CensusPath, '--purge-list')
    if ($listed.ExitCode -ne 0) {
        $why = "chain ORT: cannot list ${VenvPath}: $(@($listed.Output) -join ' | ')"
        if ($InImage) { throw $why }
        & $Warn $why
        return [pscustomobject]@{ Aborted = $true; Installed = @(); Names = @() }
    }
    $installed = @(@($listed.Output) | ForEach-Object { if ("$_" -match '^ORT-CENSUS PURGE ([a-z0-9][a-z0-9-]*)$') { $Matches[1] } })
    $names = @($installed) + @($Skipped | Where-Object { $_ -and $_ -notin $installed })
    return [pscustomobject]@{ Aborted = $false; Installed = $installed; Names = $names }
}

function Invoke-UvChainOrtReplacement {
    param([string]$VenvPath, [string]$Python, [string]$WheelStore, [string]$CensusPath,
        [string[]]$Names, [string[]]$Installed, [scriptblock]$Runner,
        [scriptblock]$CommandRunner, [scriptblock]$LogInfo, [scriptblock]$Say)
    $wheels = @(Get-ChildItem -LiteralPath $WheelStore -File | Where-Object { $_.Name -match '^onnxruntime[-_].*\.whl$' } | ForEach-Object { $_.FullName })
    if ($wheels.Count -eq 0) { throw "chain ORT: the store $WheelStore holds no onnxruntime wheel for $($Names -join ' ')" }
    Assert-UvChainOrtAbiFit -VenvPath $VenvPath -Python $Python -Wheels $wheels -Runner $Runner
    & $Say "chain ORT: replacing $($Names -join ' ') in $VenvPath with $(($wheels | ForEach-Object { Split-Path $_ -Leaf }) -join ' ')"
    # A skipped distribution never reached the venv, so only the installed ones are uninstalled.
    if ($Installed.Count -gt 0) { Invoke-UvCommand -Arguments (@('pip', 'uninstall', '--python', $Python) + $Installed) -CommandRunner $CommandRunner -LogInfo $LogInfo }
    try {
        Invoke-UvCommand -Arguments (@('pip', 'install', '--python', $Python, '--no-index', '--no-deps', '--force-reinstall') + $wheels) `
            -CommandRunner $CommandRunner -LogInfo $LogInfo
    } catch {
        throw "chain ORT: $VenvPath does not take the chain wheels: $($_.Exception.Message)"
    }
    $check = & $Runner $Python @('-I', $CensusPath, '--check', '--store', $WheelStore)
    if ($check.ExitCode -ne 0) { throw "chain ORT: $VenvPath still carries a non-chain ONNX Runtime:`n$(@($check.Output) -join "`n")" }
    & $Say (@($check.Output) -join "`n")
    $import = & $Runner $Python @('-I', '-c', 'import sys; print(sys.version); import onnxruntime')
    if ($import.ExitCode -ne 0) {
        throw "chain ORT: the chain onnxruntime does not import in $VenvPath (the store is built for the image interpreter):`n$(@($import.Output) -join "`n")"
    }
    Set-UvChainOrtSyncHold -Hold $true
}

<#
.SYNOPSIS
    Moves a synced venv's ONNX Runtime onto the image's chain wheels, proven by the census; outside our images warns.
.DESCRIPTION
    See docs/python-ci.md#trap-3--onnx-runtime-comes-from-the-chain-not-pypi
.PARAMETER Skipped
    ORT distributions the sync left out on purpose; they need the chain wheels as much as what PyPI installed.
.PARAMETER PythonRunner
    Test seam: { param($python, $arguments) } returning @{ ExitCode; Output }. Default runs the interpreter.
#>
function Sync-UvChainOnnxRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VenvPath,
        [AllowEmptyString()][string]$WheelStore = (Get-ChainOrtWheelStore),
        [string]$CensusPath = '',
        [AllowEmptyCollection()][string[]]$Skipped = @(),
        [scriptblock]$CommandRunner,
        [scriptblock]$PythonRunner,
        [scriptblock]$LogInfo,
        [scriptblock]$LogWarning
    )

    if (-not $CensusPath) { $CensusPath = Get-UvOrtCensusPath }
    $say = if ($LogInfo) { $LogInfo } else { { param($m) Write-Host $m } }
    $warn = if ($LogWarning) { $LogWarning } else { { param($m) Write-Warning $m } }
    $run = Get-UvChainOrtRunner -PythonRunner $PythonRunner
    $python = Join-Path $VenvPath 'Scripts\python.exe'
    $inImage = -not [string]::IsNullOrWhiteSpace($WheelStore)
    if (-not (Test-UvChainOrtInputs -VenvPath $VenvPath -WheelStore $WheelStore -Python $python `
                -CensusPath $CensusPath -InImage $inImage -LogInfo $LogInfo)) { return }
    if ($inImage) { $WheelStore = Select-UvChainOrtWheelStore -WheelStore $WheelStore -Python $python -Runner $run }

    $selection = Get-UvChainOrtSelection -VenvPath $VenvPath -Python $python -CensusPath $CensusPath `
        -Skipped $Skipped -InImage $inImage -Runner $run -Warn $warn
    if ($selection.Aborted) { return }
    $installed = @($selection.Installed)
    $names = @($selection.Names)
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
    Invoke-UvChainOrtReplacement -VenvPath $VenvPath -Python $python -WheelStore $WheelStore `
        -CensusPath $CensusPath -Names $names -Installed $installed -Runner $run `
        -CommandRunner $CommandRunner -LogInfo $LogInfo -Say $say

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
    Reads EXPERIMENTAL_PYTHON_VERSIONS with the same default as python_uv.sh (the pin's X.Yt), so one export sets both halves.
.PARAMETER Version
    Interpreter version as the matrix spells it, X.Y or X.Yt.
#>
function Test-ExperimentalPython {
    param(
        [Parameter(Mandatory)]
        [string]$Version
    )

    $configured = $env:EXPERIMENTAL_PYTHON_VERSIONS
    if ([string]::IsNullOrWhiteSpace($configured)) { $configured = try { "$((Get-PinnedPythonVersion).MajorMinor)t" } catch { '' } }
    $permitted = $configured -split "[,\s]+" | Where-Object { $_ }
    return ($permitted -contains $Version)
}

Export-ModuleMember -Function @(    'Get-UvPythonRequest',
    'New-UvProjectEnvironment',
    'Remove-UvProjectEnvironment',
    'New-TrackedUvEnvironment',
    'Remove-TrackedUvEnvironment',
    'Test-ExperimentalPython',
    'Sync-UvProjectDependencies',
    'Sync-UvChainOnnxRuntime',
    'Sync-UvChainOpenCv',
    'Get-ChainOrtWheelStore',
    'Get-UvLockOrtName',
    'Get-UvOrtCensusPath',
    'Get-UvConflictGroups',
    'Get-UvExtrasToExclude',
    'Test-UvVenvHealthy',
    'Initialize-UvVenv',
    'Install-UvRequirements',
    # Exported runner seam, so consumers drive uv through the module's own code path.
    'Invoke-UvCommand'
)

