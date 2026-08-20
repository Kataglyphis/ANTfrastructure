#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Installs a locally built containerd-shim binary over the one Stevedore ships,
# keeping a timestamped backup, and optionally sets environment variables on the
# containerd service (the shim inherits containerd's environment).
#
# WHY THIS EXISTS: this host class needs a patched runhcs shim - the stock one
# hardcodes a 30s container teardown timeout, which on filesystem-heavy WCOW
# builds terminates the container mid-hive-flush and leaves the scratch
# permanently unexportable (hcsshim::ExportLayer 0x3). Full story:
# docs/windows-builds.md, upstream submission: windows/upstream/.
# EVERY Stevedore/containerd update silently overwrites the patched binary and
# brings the defect back, so this script is run repeatedly, not once.
#
# IT ALSO ARMS THE BUILD GATE: on a successful swap it records the installed
# binary's SHA256 to C:\ProgramData\kataglyphis\shim-patch.json, which is what
# Assert-ShimPatch (build-buildkit.ps1 preflight) and verify-host-setup.ps1
# compare the live binary against. Until this script has run at least once on a
# host, both fall back to a file-size heuristic and say so. `-Restore .orig`
# CLEARS the record instead of writing one - restoring stock must never teach
# the gate that stock is acceptable.
#
# RUN FROM AN ADMIN SHELL, and NEVER while a build is running - the service
# stop kills every in-flight solve, and the binary cannot be replaced while a
# shim process holds it. The script refuses on both unless -Force is passed.
#
# Examples:
#
#   # what is installed right now, which backups exist - changes nothing
#   pwsh -File windows\scripts\host\deploy-shim-patch.ps1 -ReportOnly
#
#   # the patched shim is ALREADY installed and only the gate's bookkeeping is
#   # missing: record its hash in place, no services touched, no elevation
#   pwsh -File windows\scripts\host\deploy-shim-patch.ps1 -RecordCurrent
#
#   # deploy a build that hardcodes the longer timeouts
#   pwsh -File windows\scripts\host\deploy-shim-patch.ps1 -ShimPath C:\src\hcsshim\containerd-shim-runhcs-v1.exe
#
#   # deploy the upstream-shaped build, which needs the env var to do anything
#   pwsh -File windows\scripts\host\deploy-shim-patch.ps1 -ShimPath C:\src\shim.exe `
#        -ServiceEnvironment CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=45m
#
#   # put the stock binary back
#   pwsh -File windows\scripts\host\deploy-shim-patch.ps1 -Restore .orig
#
# VERIFYING THE RESULT: the shim logs its effective timeout at Debug level only,
# which does NOT reach containerd's log on a default setup - so a quiet log is
# NOT proof the deployment worked. The reliable check is behavioural: run a
# filesystem-heavy container (the OpenCV canary in docs/windows-builds.md) and
# confirm it finalizes and exports without 0x3. A disposable canary snapshot is
# the right thing to risk; a chain run is not.

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # The newly built shim binary to install. Required unless -ReportOnly or
    # -Restore is used.
    [string]$ShimPath = '',

    # Where the live binary sits. Stevedore's default install location.
    [string]$InstallPath = "$env:ProgramFiles\Stevedore\bin\containerd-shim-runhcs-v1.exe",

    # Environment entries ('NAME=value') to set on -EnvironmentService. Existing
    # entries are preserved; entries with the same name are replaced.
    [string[]]$ServiceEnvironment = @(),

    # The service whose environment the shim inherits.
    [string]$EnvironmentService = 'containerd',

    # Services stopped for the swap, in order. Restarted in reverse.
    [string[]]$Service = @('buildkitd', 'containerd'),

    # Processes whose presence means a build is live.
    [string[]]$BlockingProcess = @('buildctl'),

    # Restore a previously kept binary instead of installing a new one. Give the
    # backup's suffix, e.g. '.orig' (stock) or '.45min'. Use -ReportOnly to list.
    [string]$Restore = '',

    # Report installed binary, backups and service environment, then exit.
    [switch]$ReportOnly,

    # Record the CURRENTLY installed binary's SHA256 as the expected patched
    # hash, without stopping services or replacing anything. For the common case
    # where the patched shim is already deployed (from before the gate existed)
    # and only the bookkeeping is missing - a full re-deploy just to write a hash
    # would cost a services restart and a build window for nothing. Refuses when
    # the live binary matches the .orig stock backup, because recording THAT
    # would teach the gate to accept an unpatched shim. Needs no elevation.
    [switch]$RecordCurrent,

    # Skip the live-build and live-shim guards.
    [switch]$Force,

    # Transcript destination. Default: <repo>\out\deploy-shim-patch.log
    [string]$LogPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$repoRoot = Split-Path (Split-Path $scriptAssetRoot -Parent) -Parent
if (-not $LogPath) { $LogPath = Join-Path $repoRoot 'out\deploy-shim-patch.log' }

$transcript = [System.Collections.Generic.List[string]]::new()
function Write-Step {
    param([string]$Message, [string]$Color = 'Gray')
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $transcript.Add($line)
    Write-Host $line -ForegroundColor $Color
}
function Save-Transcript {
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $LogPath -Parent) | Out-Null
        Set-Content -Path $LogPath -Value ($transcript -join [Environment]::NewLine) -Encoding UTF8
        Write-Host "log: $LogPath" -ForegroundColor DarkGray
    } catch {
        Write-Warning "could not write log to ${LogPath}: $($_.Exception.Message)"
    }
}

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

    # The hash the BK-lane gate (Assert-ShimPatch) checks against, and whether
    # the live binary still matches it — the question -ReportOnly is run to answer.
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
        $current = (Get-ItemProperty $svcKey -ErrorAction Stop).Environment
        if ($current) {
            foreach ($e in $current) { Write-Step "env       : $e" }
        } else {
            Write-Step "env       : $EnvironmentService has no Environment value"
        }
    } catch {
        Write-Step ("env       : cannot read {0} ({1})" -f $svcKey, $_.Exception.Message) 'Yellow'
    }
}

# --- guards ------------------------------------------------------------------

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

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

Write-Step '--- stopping services ---'
$stopped = [System.Collections.Generic.List[string]]::new()
foreach ($s in $Service) {
    try { Stop-Service $s -Force -ErrorAction Stop; $stopped.Add($s); Write-Step "$s stopped" }
    catch { Write-Step ('{0} STOP ERROR: {1}' -f $s, $_.Exception.Message) 'Yellow' }
}
Start-Sleep -Seconds 3

# --- swap --------------------------------------------------------------------
#
# The backup is timestamped so repeated deployments never silently discard the
# binary that was working. .orig is left alone once it exists - it is the only
# copy of the untouched stock shim.

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

# --- record what was installed ------------------------------------------------
#
# Assert-ShimPatch (WindowsBuildDriver.Common, the BK lane's preflight gate) used
# to identify the patched shim by FILE SIZE, which rots every time hcsshim moves
# and degrades to a warning exactly when something has changed. Recording the
# SHA256 here makes the gate exact and self-maintaining: the expected hash is
# whatever THIS script last installed, so a Stevedore update overwriting the
# binary is a hard, unambiguous failure instead of a shrug. Matches how every
# other downloaded input in this repo is pinned.
#
# Best-effort: a build gate losing its bookkeeping must never fail a swap that
# already succeeded — the gate falls back to the size heuristic.
if ($swapped) {
    try {
        Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsBuildDriver.Common.psm1') -Force
        $stockBackup = "$InstallPath.orig"
        # `-Restore .orig` puts the STOCK binary back. Recording that as "the
        # deployed patch" would teach the gate to wave the un-patched shim
        # through — the exact failure it exists to catch. Clear the state
        # instead, so the gate falls back to the size heuristic, which knows
        # stock is a hard failure.
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
        $existing = @((Get-ItemProperty $svcKey -ErrorAction Stop).Environment)
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

Write-Step '--- starting services ---'
[array]::Reverse($stopped)
foreach ($s in $stopped) {
    try { Start-Service $s -ErrorAction Stop; Write-Step ('{0} : {1}' -f $s, (Get-Service $s).Status) }
    catch { Write-Step ('{0} START ERROR: {1}' -f $s, $_.Exception.Message) 'Red' }
}

Write-Step '--- after ---'
Show-State
Write-Step 'NOT YET PROVEN: a quiet log does not confirm the deployment took effect.' 'Yellow'
Write-Step 'Verify behaviourally with the OpenCV canary (docs/windows-builds.md).' 'Yellow'
Save-Transcript
