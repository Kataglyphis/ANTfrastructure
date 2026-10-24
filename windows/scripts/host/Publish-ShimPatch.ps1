#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Re-run after every Stevedore/containerd update, which overwrites the patched shim: see docs/windows-host-setup.md § Phase R
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # The newly built shim binary; required unless -ReportOnly or -Restore.
    [string]$ShimPath = '',

    # Where the live binary sits. Stevedore's default install location.
    [string]$InstallPath = "$env:ProgramFiles\Stevedore\bin\containerd-shim-runhcs-v1.exe",

    # 'NAME=value' entries for -EnvironmentService; same-name entries are replaced, others kept.
    [string[]]$ServiceEnvironment = @(),

    # The service whose environment the shim inherits.
    [string]$EnvironmentService = 'containerd',

    # Services stopped for the swap, in order. Restarted in reverse.
    [string[]]$Service = @('buildkitd', 'containerd'),

    # Processes whose presence means a build is live.
    [string[]]$BlockingProcess = @('buildctl'),

    # Suffix of a kept backup to restore instead, e.g. '.orig' (stock); -ReportOnly lists them.
    [string]$Restore = '',

    # Report installed binary, backups and service environment, then exit.
    [switch]$ReportOnly,

    # Record the installed binary's SHA256 as the patched hash without a swap; refuses the stock binary.
    [switch]$RecordCurrent,

    # Skip the live-build and live-shim guards.
    [switch]$Force,

    # Transcript destination. Default: <repo>\logs\host\deploy-shim-patch.log
    [string]$LogPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsHostMaintenance.Common.psm1') -Force
$hostLog = New-HostMaintenanceLog -Name 'deploy-shim-patch' -LogPath $LogPath

$svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$EnvironmentService"

# --- report ------------------------------------------------------------------

function Show-State {
    if (Test-Path $InstallPath) {
        $item = Get-Item $InstallPath
        Write-HostStep -Log $hostLog ('installed : {0:N0} bytes, {1}' -f $item.Length, $item.LastWriteTime)
    } else {
        Write-HostStep -Log $hostLog "installed : MISSING at $InstallPath" 'Red'
    }

    $backups = @(Get-ChildItem "$InstallPath.*" -ErrorAction SilentlyContinue)
    if ($backups.Count -gt 0) {
        foreach ($b in $backups) {
            Write-HostStep -Log $hostLog ('backup    : {0,-12} {1,14:N0} bytes, {2}' -f $b.Extension, $b.Length, $b.LastWriteTime)
        }
    } else {
        Write-HostStep -Log $hostLog 'backup    : none'
    }

    # Whether the live binary still matches the hash Assert-ShimPatch checks.
    Invoke-HostMaintenanceTask -Log $hostLog -FailureTemplate "gate hash : cannot read ({0})" -Operation {
        Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsBuildDriver.Common.psm1')
        $statePath = Get-ShimPatchStatePath
        if (Test-Path $statePath) {
            $state = Get-Content $statePath -Raw | ConvertFrom-Json
            $live = if (Test-Path $InstallPath) { (Get-FileHash -Algorithm SHA256 -Path $InstallPath).Hash } else { '' }
            $verdict = if ($live -eq $state.sha256) { 'MATCHES live binary' } else { 'DOES NOT MATCH live binary' }
            $color = if ($live -eq $state.sha256) { 'Green' } else { 'Red' }
            Write-HostStep -Log $hostLog ('gate hash : {0} ({1}, recorded {2}, variant {3})' -f
                $state.sha256.Substring(0, 12), $verdict, $state.deployedAt, $state.variant) $color
        } else {
            Write-HostStep -Log $hostLog "gate hash : none recorded ($statePath) - Assert-ShimPatch falls back to the size heuristic" 'Yellow'
        }
    }.GetNewClosure()

    try {
        # Stock containerd has no Environment value, and a bare .Environment read throws under StrictMode.
        $current = (Get-ItemProperty -Path $svcKey -Name Environment -ErrorAction SilentlyContinue)
        if ($current -and $current.Environment) {
            foreach ($e in $current.Environment) { Write-HostStep -Log $hostLog "env       : $e" }
        } else {
            Write-HostStep -Log $hostLog "env       : $EnvironmentService has no Environment value"
        }
    } catch {
        Write-HostStep -Log $hostLog ("env       : cannot read {0} ({1})" -f $svcKey, $_.Exception.Message) 'Yellow'
    }
}

# --- guards ------------------------------------------------------------------

$isAdmin = Test-Elevated

if ($ReportOnly) {
    Write-HostStep -Log $hostLog 'ReportOnly - nothing will be changed'
    if (-not $isAdmin) { Write-HostStep -Log $hostLog 'not elevated: the service environment may read as unavailable' 'Yellow' }
    Show-State
    Save-HostMaintenanceLog -Log $hostLog
    return
}

function Write-InstalledShimPatchState {
    if ($ShimPath -or $Restore) { throw 'Pass -RecordCurrent alone: it records what is already installed and changes nothing else.' }
    if (-not (Test-Path $InstallPath)) { throw "no shim installed at $InstallPath - nothing to record." }
    Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsBuildDriver.Common.psm1') -Force
    $stockBackup = "$InstallPath.orig"
    if ((Test-Path $stockBackup) -and -not $Force) {
        $liveHash = (Get-FileHash -Algorithm SHA256 -Path $InstallPath).Hash
        if ($liveHash -eq (Get-FileHash -Algorithm SHA256 -Path $stockBackup).Hash) {
            Save-HostMaintenanceLog -Log $hostLog
            throw ("the installed binary is IDENTICAL to the stock backup $stockBackup - recording it would teach the " +
                'build gate that an unpatched shim is acceptable. Deploy the patched build first (-ShimPath), or pass ' +
                '-Force if you are certain the .orig backup is not actually stock.')
        }
    }
    $statePath = Write-ShimPatchState -ShimPath $InstallPath -Variant 'recorded-in-place' -StockBackupPath $stockBackup
    Write-HostStep -Log $hostLog "recorded the installed shim's hash for the build gate: $statePath" 'Green'
    Show-State
    Write-HostStep -Log $hostLog 'NOT a verification that the binary is actually patched - it records what is there.' 'Yellow'
    Write-HostStep -Log $hostLog 'Only use this when you know the installed shim IS the patched build.' 'Yellow'
    Save-HostMaintenanceLog -Log $hostLog
}

if ($RecordCurrent) {
    Write-InstalledShimPatchState
    return
}

if (-not $isAdmin) { throw 'Run from an elevated (admin) shell: replacing the binary and controlling services needs it.' }

if ($Restore -and $ShimPath) { throw 'Pass either -ShimPath or -Restore, not both.' }

function Resolve-ShimDeploymentSource {
    param([string]$ShimPath, [string]$Restore, [string]$InstallPath)
    $source = $ShimPath
    if ($Restore) {
        $source = "$InstallPath$Restore"
        if (-not (Test-Path $source)) { throw "no such backup: $source (use -ReportOnly to list)" }
    } elseif (-not $source) {
        throw 'Nothing to do: pass -ShimPath, -Restore or -ReportOnly.'
    } elseif (-not (Test-Path $source)) {
        throw "shim binary not found: $source"
    }
    return $source
}

$source = Resolve-ShimDeploymentSource -ShimPath $ShimPath -Restore $Restore -InstallPath $InstallPath

Write-HostStep -Log $hostLog '--- before ---'
Show-State
Write-HostStep -Log $hostLog ('source    : {0:N0} bytes  {1}' -f (Get-Item $source).Length, $source)

if (-not $Force) {
    $null = Get-HostMaintenanceProcess -Name $BlockingProcess -Log $hostLog `
        -FailureTemplate '{0} live process(es) ({1}) - stopping the build services kills their solves. Wait, or pass -Force.'
    $null = Get-HostMaintenanceProcess -Name ([IO.Path]::GetFileNameWithoutExtension($InstallPath)) -Log $hostLog `
        -FailureTemplate '{0} shim process(es) alive (pids: {2}) - containers are still running and the binary is locked.'
}

if (-not $PSCmdlet.ShouldProcess($InstallPath, "stop [$($Service -join ', ')], replace binary, restart")) { return }

# --- stop --------------------------------------------------------------------

$stopped = Stop-HostServices -Log $hostLog -Service $Service

# --- swap (timestamped backups; .orig, the only stock copy, is never overwritten) ---

function Install-ShimDeploymentBinary {
param([string]$Source, [string]$InstallPath, [string]$Restore, $Log)
$swapped = $false
try {
    if (-not $Restore) {
        $stockBackup = "$InstallPath.orig"
        if (-not (Test-Path $stockBackup)) {
            Copy-Item $InstallPath $stockBackup -Force -ErrorAction Stop
            Write-HostStep -Log $Log "stock binary preserved as $stockBackup"
        }
        $stamp = "$InstallPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $InstallPath $stamp -Force -ErrorAction Stop
        Write-HostStep -Log $Log "previous binary preserved as $stamp"
    }
    Copy-Item $source $InstallPath -Force -ErrorAction Stop
    $swapped = $true
    Write-HostStep -Log $Log ('installed {0:N0} bytes' -f (Get-Item $InstallPath).Length) 'Green'
} catch {
    Write-HostMaintenanceError -Log $Log -ErrorRecord $_ -Template 'SWAP ERROR: {0}' -Color 'Red'
}
return $swapped
}

$swapped = Install-ShimDeploymentBinary -Source $source -InstallPath $InstallPath -Restore $Restore -Log $hostLog

# --- record the hash Assert-ShimPatch checks (best-effort: it must never fail a swap that succeeded) ---
function Write-ShimDeploymentState {
if ($swapped) {
    Invoke-HostMaintenanceTask -Log $hostLog -FailureTemplate 'STATE ERROR (gate falls back to the size check): {0}' -Operation {
        Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsBuildDriver.Common.psm1')
        $stockBackup = "$InstallPath.orig"
        # Recording a restored stock binary would teach the gate to pass it; clearing falls back to the size check.
        $isStock = (Test-Path $stockBackup) -and
            ((Get-FileHash -Algorithm SHA256 -Path $InstallPath).Hash -eq (Get-FileHash -Algorithm SHA256 -Path $stockBackup).Hash)
        if ($isStock) {
            $statePath = Get-ShimPatchStatePath
            if (Test-Path $statePath) { Remove-Item $statePath -Force }
            Write-HostStep -Log $hostLog "installed binary IS the stock shim - cleared the gate's recorded hash ($statePath)" 'Yellow'
        } else {
            $variant = if ($Restore) { "restored$Restore" }
                elseif ($ServiceEnvironment.Count -gt 0) { 'upstream-env' }
                else { 'local-constant' }
            $statePath = Write-ShimPatchState -ShimPath $InstallPath -Variant $variant -StockBackupPath $stockBackup
            Write-HostStep -Log $hostLog "recorded deployed hash for the build gate: $statePath" 'Green'
        }
    }.GetNewClosure()
}
}

Write-ShimDeploymentState

# --- service environment -----------------------------------------------------

function Set-ShimDeploymentEnvironment {
if ($swapped -and $ServiceEnvironment.Count -gt 0) {
    Write-HostStep -Log $hostLog "--- setting environment on $EnvironmentService ---"
    Invoke-HostMaintenanceTask -Log $hostLog -FailureTemplate 'ENV ERROR: {0}' -FailureColor 'Red' -Operation {
        # Absent Environment reads as an empty list; not an if-expression, whose @() branch assigns $null.
        $prop = Get-ItemProperty -Path $svcKey -Name Environment -ErrorAction SilentlyContinue
        $existing = @()
        if ($prop) { $existing = @($prop.Environment) }
        $names = $ServiceEnvironment | ForEach-Object { ($_ -split '=', 2)[0] }
        $kept = @($existing | Where-Object { $_ -and (($_ -split '=', 2)[0]) -notin $names })
        if ($kept.Count -gt 0) { Write-HostStep -Log $hostLog ('preserved: ' + ($kept -join ' | ')) }
        $merged = $kept + $ServiceEnvironment
        Set-ItemProperty -Path $svcKey -Name Environment -Type MultiString -Value $merged -ErrorAction Stop
        Write-HostStep -Log $hostLog ('environment now: ' + ((Get-ItemProperty $svcKey).Environment -join ' | ')) 'Green'
    }.GetNewClosure()
}
}

Set-ShimDeploymentEnvironment

# --- start -------------------------------------------------------------------

Start-HostServices -Log $hostLog -Service $stopped

Write-HostStep -Log $hostLog '--- after ---'
Show-State
Write-HostStep -Log $hostLog 'NOT YET PROVEN: a quiet log does not confirm the deployment took effect.' 'Yellow'
Write-HostStep -Log $hostLog 'Verify behaviourally with the OpenCV canary (docs/windows-builds.md).' 'Yellow'
Save-HostMaintenanceLog -Log $hostLog
