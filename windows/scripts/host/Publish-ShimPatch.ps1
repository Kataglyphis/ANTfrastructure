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

    # Transcript destination. Default: <repo>\out\deploy-shim-patch.log
    [string]$LogPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$repoRoot = Split-Path (Split-Path $scriptAssetRoot -Parent) -Parent
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsHostMaintenance.Common.psm1') -Force
# Two lines, not Optimize-HostVhdx's one: a verbatim copy would grow the reviewed code-dupes block.
$sharedModulePath = Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1'
Import-Module $sharedModulePath -Force
$hostLog = New-HostMaintenanceLog -Name 'deploy-shim-patch' -RepoRoot $repoRoot -LogPath $LogPath
$LogPath = $hostLog.LogPath
# Script-scope wrappers: they close over $hostLog, which a module function could not see.
function Write-Step { param([string]$Message, [string]$Color = 'Gray') Write-HostStep $hostLog $Message $Color }
function Save-Transcript { Save-HostMaintenanceLog $hostLog }

$svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$EnvironmentService"

# --- report ------------------------------------------------------------------

function Show-State {
    if (Test-Path $InstallPath) {
        $item = Get-Item $InstallPath
        Write-Step ('installed : {0:N0} bytes, {1}' -f $item.Length, $item.LastWriteTime)
    } else {
        Write-Step "installed : MISSING at $InstallPath" 'Red'
    }

    $backups = @(Get-ChildItem "$InstallPath.*" -ErrorAction SilentlyContinue)
    if ($backups.Count -gt 0) {
        foreach ($b in $backups) {
            Write-Step ('backup    : {0,-12} {1,14:N0} bytes, {2}' -f $b.Extension, $b.Length, $b.LastWriteTime)
        }
    } else {
        Write-Step 'backup    : none'
    }

    # Whether the live binary still matches the hash Assert-ShimPatch checks.
    try {
        Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsBuildDriver.Common.psm1') -Force
        $statePath = Get-ShimPatchStatePath
        if (Test-Path $statePath) {
            $state = Get-Content $statePath -Raw | ConvertFrom-Json
            $live = if (Test-Path $InstallPath) { (Get-FileHash -Algorithm SHA256 -Path $InstallPath).Hash } else { '' }
            $verdict = if ($live -eq $state.sha256) { 'MATCHES live binary' } else { 'DOES NOT MATCH live binary' }
            $color = if ($live -eq $state.sha256) { 'Green' } else { 'Red' }
            Write-Step ('gate hash : {0} ({1}, recorded {2}, variant {3})' -f
                $state.sha256.Substring(0, 12), $verdict, $state.deployedAt, $state.variant) $color
        } else {
            Write-Step "gate hash : none recorded ($statePath) - Assert-ShimPatch falls back to the size heuristic" 'Yellow'
        }
    } catch {
        Write-Step ("gate hash : cannot read ({0})" -f $_.Exception.Message) 'Yellow'
    }

    try {
        # Stock containerd has no Environment value, and a bare .Environment read throws under StrictMode.
        $current = (Get-ItemProperty -Path $svcKey -Name Environment -ErrorAction SilentlyContinue)
        if ($current -and $current.Environment) {
            foreach ($e in $current.Environment) { Write-Step "env       : $e" }
        } else {
            Write-Step "env       : $EnvironmentService has no Environment value"
        }
    } catch {
        Write-Step ("env       : cannot read {0} ({1})" -f $svcKey, $_.Exception.Message) 'Yellow'
    }
}

# --- guards ------------------------------------------------------------------

$isAdmin = Test-Elevated

if ($ReportOnly) {
    Write-Step 'ReportOnly - nothing will be changed'
    if (-not $isAdmin) { Write-Step 'not elevated: the service environment may read as unavailable' 'Yellow' }
    Show-State
    Save-Transcript
    return
}

if ($RecordCurrent) {
    if ($ShimPath -or $Restore) { throw 'Pass -RecordCurrent alone: it records what is already installed and changes nothing else.' }
    if (-not (Test-Path $InstallPath)) { throw "no shim installed at $InstallPath - nothing to record." }
    Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsBuildDriver.Common.psm1') -Force
    $stockBackup = "$InstallPath.orig"
    if ((Test-Path $stockBackup) -and -not $Force) {
        $liveHash = (Get-FileHash -Algorithm SHA256 -Path $InstallPath).Hash
        if ($liveHash -eq (Get-FileHash -Algorithm SHA256 -Path $stockBackup).Hash) {
            Save-Transcript
            throw ("the installed binary is IDENTICAL to the stock backup $stockBackup - recording it would teach the " +
                'build gate that an unpatched shim is acceptable. Deploy the patched build first (-ShimPath), or pass ' +
                '-Force if you are certain the .orig backup is not actually stock.')
        }
    }
    $statePath = Write-ShimPatchState -ShimPath $InstallPath -Variant 'recorded-in-place' -StockBackupPath $stockBackup
    Write-Step "recorded the installed shim's hash for the build gate: $statePath" 'Green'
    Show-State
    Write-Step 'NOT a verification that the binary is actually patched - it records what is there.' 'Yellow'
    Write-Step 'Only use this when you know the installed shim IS the patched build.' 'Yellow'
    Save-Transcript
    return
}

if (-not $isAdmin) { throw 'Run from an elevated (admin) shell: replacing the binary and controlling services needs it.' }

if ($Restore -and $ShimPath) { throw 'Pass either -ShimPath or -Restore, not both.' }

$source = $ShimPath
if ($Restore) {
    $source = "$InstallPath$Restore"
    if (-not (Test-Path $source)) { throw "no such backup: $source (use -ReportOnly to list)" }
} elseif (-not $source) {
    throw 'Nothing to do: pass -ShimPath, -Restore or -ReportOnly.'
} elseif (-not (Test-Path $source)) {
    throw "shim binary not found: $source"
}

Write-Step '--- before ---'
Show-State
Write-Step ('source    : {0:N0} bytes  {1}' -f (Get-Item $source).Length, $source)

if (-not $Force) {
    $live = @(Get-Process -Name $BlockingProcess -ErrorAction SilentlyContinue)
    if ($live.Count -gt 0) {
        Save-Transcript
        throw ("{0} live process(es) ({1}) - stopping the build services kills their solves. Wait, or pass -Force." -f
            $live.Count, (($live | ForEach-Object ProcessName | Sort-Object -Unique) -join ', '))
    }
    $shims = @(Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($InstallPath)) -ErrorAction SilentlyContinue)
    if ($shims.Count -gt 0) {
        Save-Transcript
        throw ("{0} shim process(es) alive (pids: {1}) - containers are still running and the binary is locked." -f
            $shims.Count, (($shims | ForEach-Object Id) -join ', '))
    }
}

if (-not $PSCmdlet.ShouldProcess($InstallPath, "stop [$($Service -join ', ')], replace binary, restart")) { return }

# --- stop --------------------------------------------------------------------

$stopped = Stop-HostServices -Log $hostLog -Service $Service

# --- swap (timestamped backups; .orig, the only stock copy, is never overwritten) ---

$swapped = $false
try {
    if (-not $Restore) {
        $stockBackup = "$InstallPath.orig"
        if (-not (Test-Path $stockBackup)) {
            Copy-Item $InstallPath $stockBackup -Force -ErrorAction Stop
            Write-Step "stock binary preserved as $stockBackup"
        }
        $stamp = "$InstallPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $InstallPath $stamp -Force -ErrorAction Stop
        Write-Step "previous binary preserved as $stamp"
    }
    Copy-Item $source $InstallPath -Force -ErrorAction Stop
    $swapped = $true
    Write-Step ('installed {0:N0} bytes' -f (Get-Item $InstallPath).Length) 'Green'
} catch {
    Write-Step ('SWAP ERROR: {0}' -f $_.Exception.Message) 'Red'
}

# --- record the hash Assert-ShimPatch checks (best-effort: it must never fail a swap that succeeded) ---
if ($swapped) {
    try {
        Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsBuildDriver.Common.psm1') -Force
        $stockBackup = "$InstallPath.orig"
        # Recording a restored stock binary would teach the gate to pass it; clearing falls back to the size check.
        $isStock = (Test-Path $stockBackup) -and
            ((Get-FileHash -Algorithm SHA256 -Path $InstallPath).Hash -eq (Get-FileHash -Algorithm SHA256 -Path $stockBackup).Hash)
        if ($isStock) {
            $statePath = Get-ShimPatchStatePath
            if (Test-Path $statePath) { Remove-Item $statePath -Force }
            Write-Step "installed binary IS the stock shim - cleared the gate's recorded hash ($statePath)" 'Yellow'
        } else {
            $variant = if ($Restore) { "restored$Restore" }
                elseif ($ServiceEnvironment.Count -gt 0) { 'upstream-env' }
                else { 'local-constant' }
            $statePath = Write-ShimPatchState -ShimPath $InstallPath -Variant $variant -StockBackupPath $stockBackup
            Write-Step "recorded deployed hash for the build gate: $statePath" 'Green'
        }
    } catch {
        Write-Step ('STATE ERROR (gate falls back to the size check): {0}' -f $_.Exception.Message) 'Yellow'
    }
}

# --- service environment -----------------------------------------------------

if ($swapped -and $ServiceEnvironment.Count -gt 0) {
    Write-Step "--- setting environment on $EnvironmentService ---"
    try {
        # Absent Environment reads as an empty list; not an if-expression, whose @() branch assigns $null.
        $prop = Get-ItemProperty -Path $svcKey -Name Environment -ErrorAction SilentlyContinue
        $existing = @()
        if ($prop) { $existing = @($prop.Environment) }
        $names = $ServiceEnvironment | ForEach-Object { ($_ -split '=', 2)[0] }
        $kept = @($existing | Where-Object { $_ -and (($_ -split '=', 2)[0]) -notin $names })
        if ($kept.Count -gt 0) { Write-Step ('preserved: ' + ($kept -join ' | ')) }
        $merged = $kept + $ServiceEnvironment
        Set-ItemProperty -Path $svcKey -Name Environment -Type MultiString -Value $merged -ErrorAction Stop
        Write-Step ('environment now: ' + ((Get-ItemProperty $svcKey).Environment -join ' | ')) 'Green'
    } catch {
        Write-Step ('ENV ERROR: {0}' -f $_.Exception.Message) 'Red'
    }
}

# --- start -------------------------------------------------------------------

Start-HostServices -Log $hostLog -Service $stopped

Write-Step '--- after ---'
Show-State
Write-Step 'NOT YET PROVEN: a quiet log does not confirm the deployment took effect.' 'Yellow'
Write-Step 'Verify behaviourally with the OpenCV canary (docs/windows-builds.md).' 'Yellow'
Save-Transcript
